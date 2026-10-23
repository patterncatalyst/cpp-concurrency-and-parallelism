---
title: "Concurrent REST Endpoints"
order: 24
layout: tutorial
sectionid: docs
part: communications-and-concurrency
description: "Thread-per-request versus async handlers, a minimal Boost.Asio/Beast server, and the back-pressure and overload-shedding strategies that keep it alive under load."
duration: "16 min"
---

<!-- PROVENANCE: NEW | anchor books: Son -->

## Learning objectives

By the end of this chapter you can:

- Compare thread-per-request and async-handler models by what each ties resource cost to: connection count versus thread-pool size.
- Build a minimal Boost.Asio/Beast HTTP server with a self-owning session and per-operation timeouts.
- Implement back-pressure with a bounded in-flight-request counter and choose a policy for the boundary.
- Implement overload shedding with a cheap, fast-failing 503 path that never touches a handler.
- Size a server's thread pool and connection limits against a container's CPU quota rather than `hardware_concurrency()`.

## Why this matters

A REST service that works fine in a load test at ten connections can fall over at ten thousand, not because the handler logic changed, but because thread-per-request ties thread count to connection count instead of to CPU work. The async-handler model breaks that coupling, at the cost of harder-to-read handler code and object-lifetime bugs that don't show up until a connection outlives what it captured.

Back-pressure and overload shedding are what keep a loaded server inside its deadlines instead of degrading invisibly. Getting both right, and sizing the thread pool against the container's actual CPU quota, is the difference between a service that fails fast and visibly under load and one that quietly falls behind until every client's deadline has already passed.

## What we'll cover

- Compare thread-per-request and async-handler models for serving REST traffic.
- Build a minimal Boost.Asio/Beast HTTP server as this chapter's concrete example.
- Cover back-pressure: how the server signals it can't accept more work without collapsing.
- Cover overload shedding as the last line of defense when back-pressure isn't enough.

A REST endpoint under real load is a concurrency problem wearing an HTTP costume. The protocol framing is incidental; the decisions that determine whether the service stays responsive at a thousand connections or falls over at a hundred are the same ones earlier chapters have already covered: how many threads actually run application code, how work gets handed to them, and what happens when more requests arrive than the service can finish in time. This chapter applies those decisions to a concrete server, built on Boost.Asio and its HTTP layer, Beast.

## Thread-per-Request vs Async Handlers

The oldest server design (and still a correct choice for some workloads) accepts a connection, blocks a dedicated thread on reading, parsing, and handling that one request, and repeats until the connection closes. Thread-per-request's appeal is that the handler code reads like ordinary sequential C++: read the request, call the database, write the response, no callbacks, no completion queue, no state machine split across suspension points. [Threads in Modern C++]({{ '/docs/04-threads-in-modern-cpp/' | relative_url }}) covers what a thread actually costs to create and keep alive, and that cost is exactly what this model pays per connection: a stack (commonly 1–8 MiB of virtual address space, though the resident cost is much lower until touched), kernel scheduling overhead, and a context switch every time the thread blocks on I/O and another thread takes the core.

That cost scales with concurrent connections, not with request rate, which is the detail that breaks thread-per-request under the traffic pattern REST services actually see: many clients holding a connection open (keep-alive, slow mobile links, a downstream call the handler is waiting on) while doing comparatively little CPU work per request. A service handling ten thousand concurrent idle-ish connections under thread-per-request needs on the order of ten thousand threads just to hold those connections open, almost all of them parked in a blocking read with nothing to do. [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }})'s I/O-bound sizing formula, `threads ≈ cores × (1 + wait_time / compute_time)`, still describes the right thread count for the actual CPU work involved, but thread-per-request ties thread count to connection count instead, because every connection, however idle, has already claimed its own thread.

The async-handler model breaks that coupling by separating "waiting on I/O" from "holding a thread." A small, fixed pool of threads runs an event loop (in Boost.Asio, `io_context::run()`) that polls the kernel for readiness (`epoll` underneath, on Linux) across every open socket at once, and dispatches a handler only when data is actually ready to read or write. [Async Runtimes and Event Loops]({{ '/docs/12-async-runtimes-and-event-loops/' | relative_url }}) covers this loop in depth; the point that matters here is that a connection sitting idle between requests costs a file descriptor and a small amount of bookkeeping state, not a thread, so the same handful of threads that would hold a few dozen blocking connections open can service tens of thousands of async ones. The price is that handler code is written as a sequence of asynchronous initiations and completion callbacks (or, since C++20, coroutines built on the same machinery), which is harder to read linearly and easier to get wrong around lifetime: a callback that fires after the object it captured has been destroyed is the model's signature bug class, and it is exactly why Beast's own APIs lean hard on `shared_from_this()` idioms to keep a connection object alive for as long as any of its operations are still outstanding.

For a service whose handlers do real, sustained CPU work per request, thread-per-request's simplicity can win outright: a pool sized to the core count, one request per thread at a time, no event-loop indirection to debug. For a service whose bottleneck is connection count and I/O wait rather than CPU, the async model's lower per-connection cost makes it the only way to reach the connection counts a modern REST tier is expected to sustain.

## A Minimal Boost.Beast Server

Beast builds HTTP and WebSocket parsing on top of Asio's asynchronous sockets without imposing a framework around it: no routing layer, no middleware chain, just a parser, a serializer, and the same `async_read`/`async_write` primitives any other Asio I/O uses. That minimalism is useful here specifically because it keeps the concurrency structure visible instead of hidden behind a framework's thread pool.

A minimal async server has three moving parts: an acceptor that hands off newly connected sockets, a per-connection session object that owns the socket and drives its own read-handle-write cycle, and an `io_context` run by a small pool of threads that services every session's readiness events. The session's lifetime is the detail easiest to get wrong: it has to outlive every asynchronous operation it has in flight, including ones Beast itself issues internally, which is why each session hands Asio a `shared_ptr` to itself inside every completion handler rather than a bare pointer or a reference:

```cpp
// A per-connection session: reads one request, writes one response, then
// either reads the next (keep-alive) or closes. Each async_* call captures
// a shared_ptr to `this` so the session survives until its handler fires.
class Session : public std::enable_shared_from_this<Session> {
public:
    explicit Session(boost::asio::ip::tcp::socket socket)
        : stream_(std::move(socket)) {}

    void run() { do_read(); }

private:
    void do_read() {
        req_ = {};
        stream_.expires_after(std::chrono::seconds(10));  // per-op timeout
        boost::beast::http::async_read(
            stream_, buffer_, req_,
            [self = shared_from_this()](boost::beast::error_code ec, std::size_t) {
                if (!ec) self->handle_request();
            });
    }

    void handle_request() {
        boost::beast::http::response<boost::beast::http::string_body> res{
            boost::beast::http::status::ok, req_.version()};
        res.set(boost::beast::http::field::content_type, "application/json");
        res.body() = R"({"status":"ok"})";
        res.prepare_payload();
        res.keep_alive(req_.keep_alive());

        auto res_ptr = std::make_shared<decltype(res)>(std::move(res));
        boost::beast::http::async_write(
            stream_, *res_ptr,
            [self = shared_from_this(), res_ptr](boost::beast::error_code ec, std::size_t) {
                if (ec) return;
                if (res_ptr->keep_alive()) self->do_read();
                else self->stream_.socket().shutdown(
                         boost::asio::ip::tcp::socket::shutdown_send);
            });
    }

    boost::beast::tcp_stream stream_;
    boost::beast::flat_buffer buffer_;
    boost::beast::http::request<boost::beast::http::string_body> req_;
};
```

The acceptor loop is the other half: it calls `async_accept` in a loop, handing each accepted socket to a new `Session` and immediately re-arming itself for the next connection, so accepting a connection never blocks waiting for the previous one to finish anything. `stream_.expires_after()` sets a rolling per-operation deadline on the Beast stream itself, which is the mechanism the next section's timeout handling builds on: every read and write gets a fresh countdown, and the stream aborts itself with an error if neither completes before it elapses. None of this code names a thread explicitly; where a request actually runs is decided by which worker thread's call into `io_context::run()` happens to be free when the socket becomes readable, which is the async model's whole point and also why `handle_request` must not assume it's always invoked from the same thread as `do_read`.

## Back-Pressure

An async server with a correctly sized thread pool and a connection count the event loop can hold doesn't automatically mean every connection's request gets served promptly: it means the server can *accept* work faster than thread-per-request could, which just moves the capacity question downstream to "how much work is actually in flight versus how much the handler pool can process." Back-pressure is the server's mechanism for keeping those two numbers from diverging without bound.

The shape is the same bounded-queue discipline [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}) laid out for any producer-consumer pair: give the set of requests allowed to be "accepted but not yet handled" an explicit cap, enforced with a counting semaphore or an atomic counter incremented on accept and decremented on completion. Below the cap, the server behaves as if the queue weren't there. At the cap, the server has to choose what happens to request `N+1`, and for a REST endpoint, the three generic options from that chapter map onto three concrete behaviors with very different client experiences. Blocking the new connection's read until a slot frees applies back-pressure without an explicit signal: the client sees the request succeed, just slower, and under sustained overload that latency grows unbounded exactly like an unbounded queue would, which makes blocking the wrong default for a service with a request-level deadline. Rejecting immediately, below, is what most production REST tiers actually choose. Dropping work is rarely correct here, since a dropped HTTP request has no retry signal of its own unless the server sends one.

[Time, Timers, and Deadlines]({{ '/docs/03-time-timers-and-deadlines/' | relative_url }})'s single-deadline-per-call-chain discipline matters just as much on the server's inbound side as it did for outbound calls: a request that's been sitting in the accepted-but-unhandled queue for 400 ms of a 500 ms client-side deadline has 100 ms left to actually run, and a handler that doesn't know this spends the full nominal budget anyway, finishing work the client has already stopped waiting for. Threading the time already spent queued into the deadline the handler computes for its own downstream calls (rather than starting a fresh clock when the handler begins) is what keeps a loaded server's wasted work proportional to the overload rather than to the overload's duration.

## Overload Shedding

Back-pressure assumes the server can tell, cheaply, how much work is already accepted: a counter, a queue depth, a semaphore's remaining count. Overload shedding is what happens when that number says the server is already at capacity: reject the new request outright, cheaply enough that rejecting it doesn't itself consume the resource that's scarce.

For a REST endpoint the natural rejection is HTTP 503 Service Unavailable, ideally paired with a `Retry-After` header so a well-behaved client backs off instead of retrying immediately into the same overload. The rejection path has to be cheap: checking an atomic counter and writing a fixed, pre-serialized 503 response, with no database call, no logging call that itself blocks on I/O, nothing that could itself queue behind the condition that triggered the shed in the first place. A shedding path that does meaningful work defeats its own purpose: a service shedding load because it's out of handler capacity, using handler capacity to shed it, degrades exactly like the overload it was meant to prevent.

<!-- DIAGRAM SPEC: Left side, a stack of inbound request arrows (orange #a06030) converging on a single "accept" box (blue #4a73b8). From accept, a gate shape leads to an "in-flight counter" box showing a fraction, e.g. "847 / 1000". Two paths exit the gate: a green #5a8870 path labeled "below capacity" leading to a row of handler boxes (also blue) that process and emit "200 OK" responses; a red #c0392b path labeled "at capacity" leading directly to a small box labeled "503 + Retry-After" that bypasses the handler row entirely, drawn with a dashed border to indicate it does no further work. A cream #fdfbf7 background throughout. Caption note beneath: "the shed path never touches a handler: it answers from the gate itself." -->
{% include excalidraw.html name="24-rest-overload-shedding" caption="Figure 24.1: accepted requests split at the capacity gate: handled below the in-flight cap, shed with 503 above it, with the shed path doing no handler-side work" %}

Shedding and back-pressure are complementary, not alternatives: back-pressure (the bounded in-flight count) defines where capacity ends, and shedding is the specific policy of what to do at that boundary for a protocol (HTTP) where "reject now" has a well-defined, client-visible meaning a raw TCP back-pressure signal doesn't. A server that only blocks degrades into unbounded latency under sustained overload; a server that sheds early keeps the requests it does accept inside their deadline, at the cost of visibly failing the excess rather than quietly delaying it. For most REST tiers behind a load balancer or a retrying client, visible, fast failure beats invisible, slow degradation, because the load balancer or the client's own retry-with-backoff logic can route around a 503 in a way it cannot route around a connection that's merely slow.

A runnable companion at `examples/concurrency/24-concurrent-rest/` builds the session and gate pattern above into a complete server and load-tests it under overload.

<!-- EXAMPLE SPEC: a Boost.Asio/Beast async HTTP server with a fixed in-flight request cap enforced via an atomic counter, serving a trivial JSON handler, built and run via Docker (lgtm-docker-stack) with the handler-pool thread count derived from the container's cpu.max quota rather than hardware_concurrency(); a concurrent HTTP load client (wrk- or hey-style, or a small Asio-based client) drives request rate past the configured cap; verified by a Lua verify.lua asserting every request received a response (either 200 or 503, none dropped or connection-reset), that 503 responses appear only once concurrent in-flight requests exceed the configured cap, and that median latency for 200 responses stays within a bound under overload rather than growing with queue depth -->

## Running in a container

A Beast server's thread pool is the `io_context`'s worker count, and that count has the same container trap [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}) already covered for any pool: `std::thread::hardware_concurrency()` reports the host's logical core count; it is reliable under cgroup v2 cpuset restriction on glibc 2.36 and newer, since affinity narrows what the call reports, but blind to a CFS bandwidth quota imposed through `cpu.max`, since a quota throttles CPU-time without changing which cores the process is allowed to run on. A server built with `io_context::run()` called from `N` threads, where `N` comes from `hardware_concurrency()` on a host with sixty-four cores but a container limited to `cpu.max = 200000 100000` (two CPU-equivalents), spins up sixty-four runner threads competing for a two-core budget, paying for every extra context switch out of a quota that's already fully spoken for, the same throttling signature covered there, here showing up as request-handling latency spikes instead of a benchmark's throughput plateau.

Connection limits need the same container-aware treatment as the thread count. A hard cap on the acceptor (refusing new `accept()` calls past a configured socket count) protects file-descriptor exhaustion (`ulimit -n`, or the container's own fd limit) the same way the in-flight-request cap protects handler capacity; the two caps are independent because a connection can be open and idle (keep-alive, waiting for the client's next request) without counting against in-flight work at all. Graceful shutdown ties directly to the deadline propagation from [Time, Timers, and Deadlines]({{ '/docs/03-time-timers-and-deadlines/' | relative_url }}): on `SIGTERM`, stop accepting new connections immediately, then give in-flight requests the remainder of their own deadlines to finish (not a fixed extra grace period layered on top) before the container's orchestrator sends `SIGKILL`. A server that drains blindly for a fixed thirty seconds either kills requests that needed thirty-one or holds the process open for twenty-nine seconds after every in-flight request with a five-second deadline has already finished or timed out on its own.

## Standards: C++20 / C++23 / C++26

Beast's completion-handler style predates C++20 and still works unchanged on every standard this chapter discusses: the callback shape in the session code above compiles as C++14 Asio always has. What each newer standard changes is how much of that handler-chaining boilerplate the language absorbs, without changing the underlying event-loop or completion-queue model at all.

C++20 coroutines let Asio's `async_*` operations be awaited directly, via `boost::asio::use_awaitable`, instead of chained through explicit lambdas: the control flow reads top-to-bottom like the thread-per-request code it's replacing, while still running on the shared `io_context` thread pool underneath; nothing about the concurrency model changes, only the handler's surface syntax. C++23 contributes `std::generator`, which is relevant to a REST server specifically for chunked or streaming response bodies: a handler that produces a response incrementally can express that production as a coroutine yielding chunks rather than hand-rolling a state machine across repeated `async_write` calls, though wiring a `std::generator` into Beast's chunked-encoding writer is integration work this book doesn't take further. C++26's senders/receivers model (`std::execution`, from the accepted P2300 proposal) is the one with no shipping standard-library implementation as of this writing; Asio's own long-term direction is to expose its executors as senders, and the sketch below shows that target shape against the `stdexec` reference implementation, not something to deploy today.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// A request handler as a coroutine: async_read and async_write are awaited
// directly, and control flow reads sequentially despite running on the
// shared io_context thread pool underneath.
boost::asio::awaitable<void> handle_connection(boost::asio::ip::tcp::socket socket) {
    boost::beast::tcp_stream stream(std::move(socket));
    for (;;) {
        boost::beast::flat_buffer buffer;
        boost::beast::http::request<boost::beast::http::string_body> req;
        auto [ec, n] = co_await boost::beast::http::async_read(
            stream, buffer, req,
            boost::asio::as_tuple(boost::asio::use_awaitable));
        if (ec) co_return;

        boost::beast::http::response<boost::beast::http::string_body> res{
            boost::beast::http::status::ok, req.version()};
        res.body() = R"({"status":"ok"})";
        res.prepare_payload();
        co_await boost::beast::http::async_write(
            stream, res, boost::asio::use_awaitable);
        if (!req.keep_alive()) co_return;
    }
}
```

```cpp
// C++23
// std::generator expresses a chunked response body as incremental yields
// rather than a hand-rolled state machine across repeated async_write calls.
// (Wiring this into Beast's chunked encoder is integration work beyond
// what's shown here — this sketches the production side only.)
#include <generator>

std::generator<std::string> stream_results(const Query& q) {
    for (auto&& row : run_query(q)) {
        co_yield serialize_chunk(row);
    }
}
```

```cpp
// C++26 (proposed; targets the accepted P2300 std::execution model, not
// yet shipping in a mainstream standard library — Asio's long-term
// direction is to expose io_context work as senders over this API shape)
#include <execution>
namespace ex = std::execution;

ex::sender auto handle_request_sender(ex::scheduler auto io_sched, Request req) {
    return ex::schedule(io_sched)
         | ex::then([req = std::move(req)] { return build_response(req); });
}
```

## What we learned

Thread-per-request ties resource cost to concurrent connections and reads simplest; the async-handler model ties resource cost to a fixed thread-pool size regardless of how many connections sit idle, at the price of handler code that's harder to read linearly and easy to get wrong around object lifetime, which is exactly why Beast sessions hold `shared_ptr`s to themselves inside every completion handler. A minimal Beast server is an acceptor, a self-owning session per connection, and a thread pool driving `io_context::run()`, with per-operation timeouts set directly on the stream. Back-pressure turns an unbounded, silently growing backlog into an explicit bounded count with a chosen policy at the boundary, and for a deadline-bound REST endpoint that policy should usually reject rather than block, since blocking just defers the same latency problem. Overload shedding is that rejection made cheap and fast: a 503 answered from the capacity gate itself, without touching a handler, so the act of shedding load never consumes the capacity it's protecting. And a container's CPU quota, not `hardware_concurrency()`, is what should size the server's thread pool, because a pool sized off the host's core count inside a throttled container doesn't get more capacity: it gets more threads taking turns on the same fixed budget.
