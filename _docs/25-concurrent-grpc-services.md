---
title: "Concurrent gRPC Services"
order: 25
layout: tutorial
sectionid: docs
part: communications-and-concurrency
description: "The async gRPC completion-queue API, streaming RPCs, and the thread-pool sizing decisions that determine how many requests a gRPC server can serve concurrently."
duration: "16 min"
---

<!-- PROVENANCE: NEW (adapted from cpp-statelessness/_docs/10-grpc-microservices.md) | anchor books: Son -->

## What we'll cover

- Cover gRPC C++'s async completion-queue API as the concurrency model underneath both the sync and callback APIs.
- Walk how a completion queue delivers events and how a server dispatches them to handler code.
- Cover streaming RPCs (client, server, and bidirectional) and how they change the concurrency shape of a handler.
- Cover sizing the server's thread pool against the completion-queue count and the expected concurrent-RPC load.

gRPC C++ ships three API surfaces — sync, callback, and async-with-completion-queues — and it's tempting to treat the choice among them as a style preference. It isn't. All three compile down to the same completion-queue event loop underneath; the sync API spends a dedicated thread blocked per call waiting on that queue so your code never sees it, and the callback API hides the queue behind a thread pool gRPC manages for you. Picking a surface is really picking how much of the concurrency machinery you want to own directly, and understanding the completion queue itself is what makes that choice legible rather than cargo-culted from whichever example compiled first.

## The Async gRPC API

The sync API — `grpc::Status Method(ServerContext*, const Request*, Response*)`, the shape most tutorials and most production services still start with — is the easiest to write and reason about: a thread calls into your handler, blocks there until it returns, and gRPC gives that thread back to its internal pool when you're done. It works well right up to the point where concurrent-RPC count exceeds comfortably-sized-thread-pool count, because sync mode genuinely does block one thread per in-flight call for that call's entire duration — a handler that calls a slow downstream service holds its thread the whole time it's waiting, exactly like the thread-per-request REST model covered in [Concurrent REST Endpoints]({{ '/docs/24-concurrent-rest-endpoints/' | relative_url }}), and for the same structural reason: thread count is coupled to concurrent-call count, not to CPU work actually being done.

The async API decouples those two numbers the same way [Async Runtimes and Event Loops]({{ '/docs/12-async-runtimes-and-event-loops/' | relative_url }})'s event loop decouples connection count from thread count. Instead of a thread blocking inside your handler, you register interest in events — "a new call has arrived," "a read finished," "a write finished" — against a `grpc::CompletionQueue`, and a small, fixed number of threads repeatedly call `cq->Next()` to pull completed events off that queue and dispatch them to whatever handler logic is waiting on each one. No thread blocks inside application code while an RPC is merely waiting on a downstream call or a slow client; it blocks only inside `cq->Next()`, waiting for *some* event across *all* in-flight calls that queue is tracking, which is the same amortization a single epoll-driven event loop gets over thousands of REST connections.

The callback API, introduced to make the async model's benefits accessible without hand-writing a tag-dispatch loop, is built on exactly this completion-queue machinery — gRPC runs its own internal completion queues and its own thread pool, and invokes your `OnReadDone` / `OnWriteDone` / request handler callbacks on threads from that pool once a corresponding completion-queue event fires. Choosing callback over raw async trades explicit control over queue count and dispatch threading for less code to maintain; choosing raw async trades that convenience for the ability to tune queue count and thread assignment directly, which matters once a service's RPC concurrency outgrows what gRPC's default pool sizing assumes.

## Completion Queues

A `grpc::CompletionQueue` is a thread-safe event queue, and the pattern that drives it is tag-based dispatch: every asynchronous operation you start — accepting a new call, reading a streamed message, finishing a response — is associated with a `void*` tag when you initiate it, and that same tag comes back out of `cq->Next()` when the operation completes. The tag is conventionally a pointer to a small state object describing what's pending and what to do next; `cq->Next()` doesn't interpret the tag at all; it's purely an opaque token the caller chose and the caller is responsible for making sense of on the way back out.

```cpp
// A minimal async-server dispatch loop. Each tag is a CallData* whose
// Proceed() method knows which phase of its own lifecycle just completed
// and what to request next — this is the state machine every raw async
// gRPC server hand-rolls, in one form or another.
void HandleRpcs(grpc::ServerCompletionQueue& cq, EchoService::AsyncService& service) {
    new CallData(&service, &cq);  // seed the first accept
    void* tag;
    bool ok;
    while (cq.Next(&tag, &ok)) {
        static_cast<CallData*>(tag)->Proceed(ok);
    }
}

class CallData {
public:
    CallData(EchoService::AsyncService* service, grpc::ServerCompletionQueue* cq)
        : service_(service), cq_(cq), responder_(&ctx_), status_(CREATE) {
        Proceed(true);
    }

    void Proceed(bool ok) {
        if (status_ == CREATE) {
            status_ = PROCESS;
            service_->RequestEcho(&ctx_, &request_, &responder_, cq_, cq_, this);
        } else if (status_ == PROCESS) {
            new CallData(service_, cq_);  // immediately accept the next call
            response_.set_message(request_.message());
            status_ = FINISH;
            responder_.Finish(response_, grpc::Status::OK, this);
        } else {
            delete this;  // FINISH: this call's lifecycle is complete
        }
    }

private:
    enum CallStatus { CREATE, PROCESS, FINISH };
    EchoService::AsyncService* service_;
    grpc::ServerCompletionQueue* cq_;
    grpc::ServerContext ctx_;
    EchoRequest request_;
    EchoResponse response_;
    grpc::ServerAsyncResponseWriter<EchoResponse> responder_;
    CallStatus status_;
};
```

Each `CallData` is its own tiny state machine, re-arming itself at each phase and immediately spawning a replacement to accept the *next* incoming call the moment the current one leaves the "waiting to be accepted" state — exactly the detail that keeps the server always listening instead of accepting one call at a time. `ok` carries success information orthogonal to the tag's identity: `cq_->Next()` sets it false when the operation associated with that tag failed or the server is shutting down, independent of what phase the call itself was in, so every `Proceed()` has to check it before trusting that the expected transition actually happened. This is unmistakably more code than the sync handler's single function body, and it's also the shape every framework-level abstraction — callback API included — is generating and managing on your behalf underneath.

<!-- DIAGRAM SPEC: cream #fdfbf7 background. Center: a horizontal "CompletionQueue" box (orange #a06030) with several small tagged event boxes queued inside it, each labeled with a short tag name (T1, T2, T3). Left side: three blue #4a73b8 "CallData" state-machine boxes, each drawn as a three-state cycle (CREATE -> PROCESS -> FINISH) with a small arrow looping from FINISH back to a freshly spawned CREATE box (labeled "spawns replacement on PROCESS"), each connected to the CompletionQueue by an arrow labeled "tag = this". Right side: a row of worker threads (green #5a8870) each with an arrow into the CompletionQueue labeled "cq->Next(&tag, &ok)" and an arrow back out labeled "tag->Proceed(ok)". Caption note beneath: "the tag is the only link between an event and the state machine that issued it." -->
{% include excalidraw.html name="25-grpc-completion-queue" caption="Figure 25.1 — tag-based dispatch: each CallData state machine issues operations tagged with itself, a pool of threads pulls completed tags off the queue, and each tag drives its own call forward" %}

## Streaming RPCs

Unary RPCs — one request, one response — are the simplest shape a completion queue drives, and the `CallData` example above is already that shape's complete state machine: CREATE, PROCESS, FINISH. Streaming RPCs extend the same tag-and-state-machine pattern across more completion events per call, and the extension looks different depending on which side is doing the streaming.

A **server-streaming** RPC — one request, a sequence of responses — replaces the single `Finish` with repeated `Write` calls, each one its own tagged operation that has to complete (the client's flow-control window has to have room) before the next `Write` can be issued; a server that calls `Write` again before the prior `Write`'s tag has come back off the queue violates the API's single-outstanding-write-per-call contract and is undefined behavior, not just inefficient. A **client-streaming** RPC inverts this: the server issues repeated `Read` operations, one tag per message, until a read completes with `ok == false`, signaling the client has finished sending, at which point the server computes its single response and finishes the call. A **bidirectional-streaming** RPC runs both directions concurrently and independently — reads and writes are each their own tag stream, and a well-formed server services them without assuming any ordering between "a read just completed" and "a write just completed," since gRPC makes no guarantee about which one its own flow control will deliver first.

The concurrency shape this creates is one call now owning *multiple* live tags simultaneously rather than one tag progressing through a linear lifecycle — a bidirectional stream's `CallData` equivalent needs separate state for its read side and its write side, since a read completing and a write completing are unrelated events that can interleave in either order, and the state machine has to be correct regardless of which order actually happens. This is also where deadline propagation matters most: a long-lived streaming call can span far more wall-clock time than a unary call's one round trip, and [Time, Timers, and Deadlines]({{ '/docs/03-time-timers-and-deadlines/' | relative_url }})'s single-deadline-per-call-chain discipline means the deadline set on `ClientContext` at stream creation — `client_ctx.set_deadline(rc.deadline())`, the *same* deadline the inbound request carried, not a freshly computed one — governs the *entire* stream, not each message within it. A client wanting per-message timeouts has to enforce them itself on top of gRPC's call-level deadline, since the protocol has no concept of a deadline that resets between messages on the same stream, which makes setting that one deadline generously enough for a legitimately long stream while still tight enough to catch a stuck one a real design decision rather than a formality.

## Server Thread-Pool Sizing

A gRPC server's completion-queue count and its thread-pool count are two separate numbers, and conflating them is the most common sizing mistake in a hand-rolled async server. The number of `CompletionQueue` instances a server runs sets the ceiling on how many threads can usefully call `cq->Next()` concurrently without idling — a single shared queue still serializes dequeue through its own internal locking regardless of how many threads call `Next()` on it, so beyond a handful of threads per queue, adding more threads adds contention without adding throughput. gRPC's own guidance, consistent with that internal design, is roughly one completion queue per thread intended to service it exclusively — multiple independent `CompletionQueue`s, each with its own dedicated servicing thread, sidesteps shared-queue contention the same way [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }})'s per-worker deques sidestep a single shared task queue's lock.

The actual queue count should follow the same CPU-bound-versus-I/O-bound distinction that chapter establishes for any pool, applied to what `Proceed()` does once a tag comes back: a handler doing real computation per RPC behaves like CPU-bound work and wants roughly one servicing thread per available core; a handler that mostly issues an outbound call and waits on *that* RPC's own completion — itself just another tag arriving on a queue, not a blocking call — behaves like I/O-bound work and can usefully oversubscribe past the core count, since a thread between `cq->Next()` calls is idle, not blocked, while its dispatched call is itself just another pending event in the queue. The callback API's internally managed pool defaults to a core-count heuristic, reasonable for a CPU-bound service and wrong for an I/O-heavy one — exactly the gap that makes the raw async API worth the extra code when a service's RPC shape diverges from that default.

Concurrent-RPC capacity itself is bounded by how many `CallData`-equivalent objects the server allows outstanding at once — in the raw async pattern above, that's implicitly unbounded, since a new one spawns the instant the prior one leaves CREATE. A production server needs the bounded-admission discipline [Concurrent REST Endpoints]({{ '/docs/24-concurrent-rest-endpoints/' | relative_url }})'s in-flight counter applies to HTTP: track calls past CREATE, and once a configured cap is hit, either delay the next accept (back-pressure, visible only as added latency before the call is accepted) or finish new calls immediately with `grpc::StatusCode::RESOURCE_EXHAUSTED` — the gRPC equivalent of REST's 503, a rejection that costs the server almost nothing to issue.

A runnable companion at `examples/concurrency/25-concurrent-grpc/` builds the raw async server and completion-queue pattern above against a server-streaming RPC under concurrent load.

<!-- EXAMPLE SPEC: an async gRPC server using the raw CompletionQueue API (not callback) serving a server-streaming RPC, with a configurable number of completion queues and servicing threads and a bounded in-flight-call cap enforced via an atomic counter, built and run via Docker (lgtm-docker-stack) with the completion-queue/thread count derived from the container's cpu.max quota; a concurrent gRPC client opens many simultaneous streaming calls to exercise the server past its configured cap; verified by a Lua verify.lua asserting every RPC attempted received either a successful streamed response or a RESOURCE_EXHAUSTED status (none hung or were silently dropped), that RESOURCE_EXHAUSTED responses appear only once the in-flight cap is exceeded, and that per-message latency within an accepted stream stays within a bound rather than growing with the number of concurrent streams -->

## Running in a container

The same cgroup trap [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}) and [Concurrent REST Endpoints]({{ '/docs/24-concurrent-rest-endpoints/' | relative_url }}) both cover applies here without modification: `std::thread::hardware_concurrency()` reports the host's core count, not the CFS bandwidth quota a container's `cpu.max` enforces, and a server sized at one completion-queue thread per host core inside a container capped at a fraction of that count oversubscribes the same way an oversized Beast thread pool does — more threads calling `cq->Next()` than the quota can run concurrently, paying for context switches out of a budget already spoken for, with the failure mode showing up as RPC tail latency rather than a clean throughput ceiling.

Running two containerized gRPC services against each other — a pricing service calling a downstream tax service, for instance — surfaces a second limit worth sizing deliberately: each outbound channel the client holds open consumes a file descriptor and, depending on keepalive settings, a trickle of periodic ping traffic, so a service that opens a fresh channel per request instead of caching one per target multiplies both costs by request rate rather than by distinct downstream count. A channel cache — one long-lived channel per target address, shared across every request to that target — keeps that count bounded by topology rather than traffic.

Graceful shutdown for a gRPC server follows the same deadline-aware draining a well-behaved sync server already needs: flip the health-check service to `NOT_SERVING` first, so a load balancer or service mesh stops routing new calls before the process stops accepting them, then call `Server::Shutdown(deadline)` with a deadline long enough to let in-flight calls finish on their own terms rather than being cut off mid-stream — for a server built on the raw async API, shutdown additionally has to drain each completion queue (calling `Shutdown()` on every `CompletionQueue` and continuing to pump `cq->Next()` until it returns false) before the process exits, or outstanding tags are simply abandoned rather than completed, which for a streaming RPC can mean a client-visible connection reset instead of a clean stream end.

## Standards: C++20 / C++23 / C++26

gRPC C++'s own APIs predate C++20 and don't require it; the standards delta here is in how idiomatically each generation of the language can express the `CallData` state machine above, not in any change to the completion-queue protocol itself.

C++20 coroutines don't attach to gRPC's own APIs natively — there's no first-party `co_await`-an-RPC support shipping in grpc's C++ library — but a thin wrapper that resumes a coroutine from inside `Proceed()` instead of running inline logic turns the three-state `CallData` into a single coroutine function suspended at each `co_await`, which collapses the explicit `CallStatus` enum into the compiler-generated coroutine state machine; the completion queue's tag-and-dispatch mechanics underneath are unchanged, only the handler authoring surface improves. C++23's `std::generator` fits the server-streaming case specifically well in that same wrapped-coroutine world: a handler that `co_yield`s each response message maps naturally onto a sequence of `Write` tags issued one at a time as the generator advances, which is a more direct match for "produce values, stream them out" than the explicit `Write`-then-wait-for-tag loop the raw API requires. C++26's senders/receivers (`std::execution`, from the accepted P2300 proposal) is again the standard with no shipping implementation as of this writing; the natural fit is representing "wait for the next completion-queue tag" as a sender a completion-queue-backed scheduler produces, letting RPC handling compose with the rest of a sender-based pipeline instead of living in its own bespoke dispatch loop — shown below against the `stdexec` reference implementation's shape, not a production target today.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// A coroutine-based wrapper around the raw tag/Proceed state machine: each
// co_await suspends until the awaiter's tag comes back off the completion
// queue, collapsing the explicit CREATE/PROCESS/FINISH enum into compiler-
// generated coroutine state. The completion queue's own dispatch is
// unchanged underneath.
boost::asio::awaitable<void> handle_echo(EchoService::AsyncService& service,
                                         grpc::ServerCompletionQueue& cq) {
    grpc::ServerContext ctx;
    EchoRequest request;
    grpc::ServerAsyncResponseWriter<EchoResponse> responder(&ctx);

    co_await async_request_rpc(service, &EchoService::AsyncService::RequestEcho,
                               ctx, request, responder, cq);

    EchoResponse response;
    response.set_message(request.message());
    co_await async_finish(responder, response, grpc::Status::OK, cq);
}
```

```cpp
// C++23
// std::generator maps naturally onto a server-streaming handler: each
// co_yield corresponds to one Write tag issued to the completion queue,
// rather than a hand-written Write-then-await-the-tag loop.
#include <generator>

std::generator<EchoResponse> stream_echoes(const EchoRequest& req) {
    for (int i = 0; i < req.repeat_count(); ++i) {
        EchoResponse resp;
        resp.set_message(req.message() + " #" + std::to_string(i));
        co_yield resp;  // driven out as a Write tag by the adapting layer
    }
}
```

```cpp
// C++26 (proposed; targets the accepted P2300 std::execution model, not
// yet shipping in a mainstream standard library — shown against the
// stdexec reference implementation's API shape)
#include <execution>
namespace ex = std::execution;

// "next tag off this completion queue" as a sender, composing RPC handling
// into the same pipeline any other sender-based work runs on.
ex::sender auto handle_unary(ex::scheduler auto cq_sched, EchoRequest req) {
    return ex::schedule(cq_sched)
         | ex::then([req = std::move(req)] { return build_echo_response(req); });
}
```

## What we learned

The completion queue is the one concurrency model underneath all three of gRPC C++'s APIs — sync spends a thread blocked per call so you never see the queue, callback hides it behind gRPC's own managed thread pool, and the raw async API hands you the tag-based dispatch loop directly. Tags are the only link between an operation you initiated and the state machine that should react when it completes, and every streaming shape — client, server, bidirectional — is the same tag-and-state-machine pattern extended across more concurrent events per call rather than a different model. Thread-pool sizing has to track completion-queue count, not just core count: roughly one dedicated servicing thread per queue avoids the shared-queue contention a single queue serving many threads produces, and whether that count should match or exceed the core count still comes down to whether a handler's work is CPU-bound or mostly waiting on a downstream call. In a container, the same `cpu.max` quota that governs any other thread pool governs this one, and the same bounded-admission discipline that gives a REST endpoint its 503 gives a gRPC server `RESOURCE_EXHAUSTED` — an explicit, cheap rejection once in-flight calls exceed a cap, rather than an unbounded queue of `CallData` objects quietly growing until the process runs out of memory or every deadline has already expired.
