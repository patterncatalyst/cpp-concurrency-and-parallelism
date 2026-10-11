---
title: "The Actor Model and Channels"
order: 23
layout: tutorial
sectionid: docs
part: communications-and-concurrency
description: "Actors and mailboxes, CSP-style channels, confinement as a design discipline, and how to write no-shared-state message passing in C++."
duration: "14 min"
---

<!-- PROVENANCE: NEW | anchor books: Grokking Concurrency, Grimm -->

## What we'll cover

- Introduce the actor model: independent actors with private state, communicating only through mailboxes.
- Introduce CSP-style channels as the alternative formalism underlying languages like Go, and the differences from actor mailboxes.
- Cover confinement as a discipline for guaranteeing no shared mutable state crosses a concurrency boundary.
- Show a concrete C++ pattern for no-shared-state message passing built on queues and move semantics.

[Chapter 22]({{ '/docs/22-communication-models/' | relative_url }}) covered message passing as a mechanism — pipes, sockets, shared memory with a notification scheme bolted on. This chapter takes message passing and makes it a design discipline for structuring an entire concurrent program, intra-process as well as inter-process, so that the question "which lock protects this data" never needs to be asked because no two threads ever touch the same mutable data at all.

## Actors and Mailboxes

An **actor** is an independent unit of concurrent execution with two properties that together define the model: it owns private state that nothing outside it can ever touch directly, and it communicates exclusively by sending and receiving discrete messages through a **mailbox** — a queue the actor alone reads from. An actor processes its mailbox one message at a time, in order, and every state change it makes happens strictly as a reaction to a message it just received. There is no shared variable, no lock, and no race to reason about *inside* an actor's own logic, because by the model's own rules nothing outside it can be running concurrently with its message handling.

What makes this different from "a thread with a queue in front of it" is the discipline around addressing and ownership. An actor's state is never exposed by reference, by pointer, or by any handle that would let another actor mutate it directly — the only way to affect an actor is to send it a message, and the only way for it to affect anything else is to send a message back, either to the original sender or to some other actor it holds an address for. This is a strictly stronger guarantee than "protected by a mutex": a mutex protects data that is still, structurally, shared — any thread that acquires the lock can touch it, and a bug is one missed lock acquisition away from a race. An actor's state isn't locked, it's **unreachable**, and there is no lock to forget to take because there is nothing to synchronize against from outside.

Erlang and Akka both build substantial supervision machinery on top of this core idea (actors that monitor other actors and restart them on failure, hierarchies of responsibility, "let it crash" as a recovery strategy), and that machinery is a legitimate and large topic on its own. It is also out of scope here: this chapter is about the messaging discipline itself, not about building a supervision framework, and a C++ program that wants the actor model's isolation guarantee doesn't need a framework to get it, as the pattern later in this chapter shows.

## CSP-Style Channels

**Communicating Sequential Processes** (CSP), the formalism Go's goroutines and channels are built on, solves a closely related problem with a different shape. Instead of an actor's address-and-mailbox ("send this message to that specific, named actor"), CSP gives you a **channel**: an anonymous conduit that any number of senders and receivers can use, where neither side needs to know who, or how many, is on the other end. A sender doesn't address a channel send to a particular receiver; it puts a value on the channel, and whichever receiver happens to be waiting (or arrives next, for a buffered channel) gets it. The channel itself, not an actor's identity, is the unit of addressing.

This distinction has real consequences for how systems built on each formalism are structured. An actor system is naturally a graph of named, addressable components, each with its own thread of control and its own queue — adding a new consumer of an actor's output usually means giving that actor the new consumer's address and having it send there too. A CSP system is naturally built around the channels themselves as the architecture: a pipeline of stages, each reading from one channel and writing to the next, with **select** (CSP's `select`/`alt`, Go's `select` statement) letting a single goroutine wait on several channels at once and proceed with whichever becomes ready first — the mechanism that lets one stage multiplex several upstream sources, or race a timeout against a result, without polling any of them.

Channels also come in two capacity flavors that matter for back-pressure, mirroring the discussion in Chapter 21 and Chapter 22. An **unbounded** channel never blocks a sender, which is convenient until a slow receiver lets it grow without limit — the same silent, unbounded-queue liability a lock-based queue has. A **bounded** channel has a fixed capacity and blocks (or returns a would-block result) once full, which is exactly the Disruptor's back-pressure property, expressed as a channel instead of a ring buffer's sequence counters. In a C++ context there is no standard channel type; the pattern later in this chapter is deliberately built as a bounded, actor-style mailbox rather than an unbounded one, for the same reason Chapter 21's ring buffer is bounded: an unbounded mailbox hides the exact failure mode (a producer that outruns its consumer) that bounding makes visible and actionable.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, split into two labeled halves. Left half, "Actor Model": three blue #4a73b8 boxes labeled Actor A, Actor B, Actor C, each containing a small lock icon crossed out and a "private state" label, each with a small green #5a8870 mailbox queue attached; solid arrows labeled "send(address, msg)" go directly from Actor A to Actor B's mailbox and from Actor B to Actor C's mailbox, each arrow annotated with the specific target actor's name. Right half, "CSP Channels": two blue #4a73b8 process boxes, Process X and Process Y, connected through a shared orange #a06030 channel box in between (no name on either process attached to the arrow); a third green #5a8870 process, Process Z, has three arrows converging on a "select" diamond that reads from three different channel boxes at once, with a note "whichever is ready first". A red #c0392b "bounded: blocks when full" label sits under one channel box in each half to mark back-pressure. -->
{% include excalidraw.html name="23-actors-vs-channels" caption="Figure 23.1 — actor mailboxes are addressed point-to-point by actor identity; CSP channels are anonymous conduits any sender or receiver can use, with select multiplexing several at once" %}

## Confinement

**Confinement** is the structural discipline that makes both models safe: at any point in time, a given piece of mutable data is owned by exactly one thread of control, and ownership transfers completely (never partially, never by reference) when the data crosses a concurrency boundary. This is stricter than "protected by synchronization." Synchronization (a mutex, an atomic, a seqlock) lets multiple threads touch the same data at different times, serialized by the primitive. Confinement removes the sharing altogether: once a message leaves a sender, the sender no longer has access to it, and once a message arrives at a receiver, no other thread does either. There is nothing to synchronize because there is never a moment where two threads could reach the same object.

The practical test for confinement in C++ is ownership, and the language already has the exact tool for enforcing it at compile time: move-only types and move semantics. A `std::unique_ptr<T>` passed by value into a queue is not merely *conventionally* handed off — after the move, the sender's own pointer is null, and the compiler will not let the sender dereference it without that being a visible bug at the call site, not a race to discover at 3 a.m. under load. This is the difference between "the team agreed not to touch this after sending it" (a convention, violated under deadline pressure) and "the compiler will not compile code that touches it" (a structural guarantee). Confinement implemented this way costs nothing at runtime, since a moved `unique_ptr` is a pointer copy and a null-out, not a lock or an atomic operation, and it's precisely because of this that message-passing designs in C++ should prefer move-only message types over copyable ones wherever the message owns a resource (memory, a file handle, a socket) that should have one owner at a time.

Thread confinement in its simplest form (never letting a given object's pointer or reference escape the thread that created it, full stop, with no cross-thread handoff at all) is the strongest and cheapest version of this discipline, and it's worth defaulting to wherever a design permits it. It is also, by construction, what every actor already does for its own state: an actor's private data is confined to the actor's own thread of execution for its entire lifetime, and the mailbox is the sole, explicit mechanism by which anything crosses that boundary, message by moved message.

## No-Shared-State Message Passing in C++

The modern C++ pattern that gets you the actor model's isolation guarantee, without a framework, is small: a `std::jthread` owning the actor's private state, pulling move-only messages off a bounded, thread-safe queue that is the only thing shared across the boundary — and even the queue itself holds no actor state, only messages in transit.

```cpp
#include <condition_variable>
#include <future>
#include <mutex>
#include <optional>
#include <queue>
#include <stop_token>
#include <thread>

// A bounded mailbox for move-only messages. The queue is the only state
// genuinely shared across the thread boundary; everything an actor
// actually operates on is moved out of it before being touched.
template <typename Msg>
class Mailbox {
public:
    explicit Mailbox(std::size_t capacity) : capacity_(capacity) {}

    void send(Msg msg) {
        std::unique_lock lock(mutex_);
        not_full_.wait(lock, [&] { return queue_.size() < capacity_; });
        queue_.push(std::move(msg));
        not_empty_.notify_one();
    }

    // Returns std::nullopt only when stopped and drained — the actor's
    // signal to exit its loop.
    std::optional<Msg> receive(std::stop_token stop) {
        std::unique_lock lock(mutex_);
        not_empty_.wait(lock, stop, [&] { return !queue_.empty(); });
        if (queue_.empty()) return std::nullopt;  // woke due to stop_requested
        Msg msg = std::move(queue_.front());
        queue_.pop();
        not_full_.notify_one();
        return msg;
    }

private:
    std::size_t capacity_;
    std::mutex mutex_;
    std::condition_variable_any not_empty_, not_full_;
    std::queue<Msg> queue_;
};

// The actor itself: private state, a jthread, and nothing else exposed.
class Accumulator {
public:
    Accumulator() : mailbox_(64), worker_([this](std::stop_token st) { run(st); }) {}

    void add(int value) { mailbox_.send(Message{Op::Add, value}); }
    void snapshot(std::promise<long> reply) {
        mailbox_.send(Message{Op::Snapshot, 0, std::move(reply)});
    }

private:
    enum class Op { Add, Snapshot };
    struct Message {
        Op op;
        int value;
        std::promise<long> reply{};  // move-only; confines the response path too
    };

    void run(std::stop_token stop) {
        long total = 0;  // private state: never touched outside this thread
        while (auto msg = mailbox_.receive(stop)) {
            if (msg->op == Op::Add) {
                total += msg->value;
            } else {
                msg->reply.set_value(total);
            }
        }
    }

    Mailbox<Message> mailbox_;
    std::jthread worker_;  // destructor requests stop and joins
};
```

Every message is moved into the mailbox and moved out of it exactly once; `Message` itself holds a `std::promise`, which is move-only, so the type system refuses to let a `Message` be copied in the first place — confinement is enforced by the compiler, not by a comment. The `Accumulator`'s `total` is a plain local variable inside `run`, never a member accessed from outside: the only way to read it is to send a `Snapshot` message and wait on the returned future, which is the mailbox pattern applied to the read path as well as the write path. `std::jthread`'s destructor requesting a stop and joining automatically means the actor's shutdown is exception-safe and leak-free without a separate explicit `stop()`/`join()` call site to remember, and `std::condition_variable_any::wait` taking a `std::stop_token` directly (both C++20 additions, covered in [Chapter 7]({{ '/docs/07-coordination-primitives/' | relative_url }})) means the mailbox's blocking receive wakes cleanly on shutdown with no polling loop.

This pattern is worth reaching for specifically when a component's correctness is easier to state as "processes one event at a time, in order, against private state" than as "some invariant holds across several fields that multiple threads touch" — an order book, a per-connection session, a state machine driving a device. It is not a general replacement for shared-state concurrency: a workload that needs many threads touching the same data concurrently for throughput (the parallel algorithms of [Chapter 14]({{ '/docs/14-parallel-algorithms-and-execution-policies/' | relative_url }}), for instance) gains nothing from forcing everything through one actor's single-threaded mailbox loop, and doing so would only serialize work that didn't need to be serialized.

## Running in a container

Bounded mailboxes interact directly with container resource quotas, and the interaction is worth making explicit rather than discovering under load. A mailbox's capacity is a deliberate back-pressure valve: once full, `send()` blocks the caller rather than growing memory without limit, and under a memory-constrained container (`--memory` or a Kubernetes memory limit), an *unbounded* mailbox is a straightforward way to get OOM-killed: a burst of inbound messages that a slow actor can't drain fast enough grows the queue until the container's cgroup memory limit kills the process, at a point in the code with no obvious connection to the mailbox that caused it. Sizing every actor's mailbox capacity explicitly, and choosing what `send()` does when full (block, as above, or return a would-block result the caller can act on) is the direct analog of the ring buffer's fixed capacity in Chapter 21, applied per actor rather than per ring.

A pool of actors, each with its own `jthread`, is also directly constrained by a container's CPU quota in a way `hardware_concurrency()` won't reveal. Spawning one actor thread per logical CPU reported by `hardware_concurrency()` assumes that many cores' worth of scheduling time is actually available; under a CFS `cpu.max` quota tighter than the visible core count, that assumption is wrong, and a pool of actors that are each individually cheap can still collectively exceed the container's throttled budget, visible as climbing `throttled_usec` in `cpu.stat` even though the application looks idle thread-by-thread. Size an actor pool from the configured quota (CPU limit in millicores, divided by expected per-actor duty cycle), not from the core count alone, and treat a sudden rise in end-to-end mailbox latency under otherwise-stable load as the first symptom to check against `throttled_usec` before assuming the actor logic itself regressed.

## Standards: C++20 / C++23 / C++26

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20: jthread + stop_token give an actor's worker thread cooperative,
// RAII-managed shutdown, and condition_variable_any::wait can take a
// stop_token directly, as used in the Mailbox above.
std::jthread worker([](std::stop_token st) {
    while (!st.stop_requested()) { /* process mailbox */ }
});
```

```cpp
// C++23: std::move_only_function (header <functional>) lets a mailbox
// carry heterogeneous move-only closures as messages — "do this" rather
// than a fixed message enum — without std::function's copyability cost.
#include <functional>

Mailbox<std::move_only_function<void()>> commands(64);
commands.send([owned = std::make_unique<Session>()]() mutable {
    owned->tick();
});
```

```cpp
// C++26 (proposed, experimental — no shipping compiler implements
// std::execution yet): an actor's mailbox loop expressed as a sender
// scheduled onto a shared scheduler, rather than a dedicated jthread per
// actor — useful once an actor pool grows large enough that one OS thread
// per actor stops being the right trade-off.
namespace ex = std::execution;

ex::sender auto actor_loop = ex::schedule(pool.get_scheduler())
    | ex::then([&mailbox] { return mailbox.receive(); })
    | ex::then([](auto msg) { handle(std::move(msg)); });
```

`jthread` and `stop_token` are what make the pattern above practical in the first place: before C++20, an actor's shutdown required a hand-rolled atomic flag, a condition variable the shutdown path had to separately notify, and a manual `join()` call that an exception path could all too easily skip. `std::move_only_function` extends the pattern from a fixed set of message types to arbitrary move-only closures as messages — useful once an actor's mailbox needs to carry "do this specific thing" rather than a small, enumerable set of operations, at the cost of losing the exhaustiveness checking a closed `enum`-based message type gives you. `std::execution`'s relevance here is the same caveat as the previous two chapters: a large actor pool built one OS thread per actor eventually hits the same scaling wall thread-per-connection servers hit, and a sender-based scheduler is the proposed answer — but it remains unimplemented and experimental, and the `jthread`-per-actor pattern above is the correct default until that changes.

## What we learned

- An actor is private state plus a mailbox: it processes messages one at a time against data nothing outside it can reach directly, which is a stronger guarantee than a mutex gives, because there is no lock to forget — the state is unreachable, not merely protected.
- CSP channels solve a related problem differently: an anonymous conduit any sender or receiver can use, with `select` multiplexing several channels at once, versus an actor's point-to-point addressing by identity.
- Confinement is the structural discipline underneath both models (exactly one owner for a given piece of mutable data at any time), and C++'s move semantics enforce it at compile time, at zero runtime cost, through move-only message types.
- A `jthread` owning private state, pulling moved messages off a bounded queue, gets you the actor model's isolation guarantee in modern C++ without a framework; it's the right tool when correctness is best stated as "one event at a time, in order," not as a replacement for shared-state concurrency on throughput-bound workloads.
- Mailbox capacity is a container-aware design decision: an unbounded mailbox under a memory-limited container is an OOM kill waiting for a burst, and an actor pool sized from `hardware_concurrency()` rather than the container's actual CPU quota will throttle in ways `cpu.stat`'s `throttled_usec` reveals before the application logs do.

This closes the communications-and-concurrency sequence: mechanisms (Chapter 22) and the design discipline built on top of them. Next, **concurrent REST endpoints** puts both to work behind an HTTP interface.
