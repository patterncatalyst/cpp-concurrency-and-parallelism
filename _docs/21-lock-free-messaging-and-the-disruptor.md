---
title: "Lock-Free Messaging and the Disruptor"
order: 21
layout: tutorial
sectionid: docs
part: low-latency-and-high-throughput
description: "Ring buffers revisited as a messaging substrate, the Disruptor pattern, batching and back-pressure, and the single-writer principle that makes it all safe."
duration: "15 min"
---

<!-- PROVENANCE: NEW | anchor books: Son -->

## What we'll cover

- Revisit the ring buffer from a messaging angle: a fixed-size, pre-allocated channel between producer and consumer.
- Introduce the Disruptor pattern: sequence barriers and claim strategies that coordinate multiple consumers over one ring.
- Cover batching as a throughput lever and back-pressure as the mechanism that keeps a fast producer from overrunning a slow consumer.
- Establish the single-writer principle and why it's the property that makes the whole pattern lock-free.

This chapter builds on [Chapter 9]({{ '/docs/09-lock-free-data-structures/' | relative_url }})'s SPSC ring buffer and [Chapter 20]({{ '/docs/20-mechanical-sympathy/' | relative_url }})'s cache-line discipline. Neither introduced anything new here: the ring is the same structure, and the cursor that tracks how far a consumer has read is exactly the kind of hot, frequently-written word that false sharing destroys if it lands on the wrong cache line.

## Ring Buffers Revisited

Chapter 9 built the SPSC ring as a data structure: a backing array and two monotonic counters, `head` and `tail`, each with exactly one writer. Looked at as a messaging substrate rather than a generic container, the same structure earns a different vocabulary. The array becomes a fixed set of pre-allocated **event slots** — not raw values but mutable objects the ring owns for its entire lifetime. A producer doesn't push a new value; it claims the next slot, writes into the object already sitting there, and publishes the slot as ready. A consumer doesn't pop a value; it reads a published slot in place and advances its own position. Nothing is allocated or freed on the hot path, because nothing needs to be: the ring's capacity is fixed at construction, and every slot is reused forever.

This reframing matters because it's the difference between a queue and a channel. A generic queue is usually judged by its interface — `push`, `pop`, maybe `try_pop`. A messaging ring is judged by what crosses it: a sequence of discrete, typed events moving from one side to the other, with the ring itself contributing nothing to their meaning. The producer's claim-write-publish sequence and the consumer's wait-read-advance sequence are the whole contract, and both are built entirely out of ordinary atomic loads and stores — the same acquire/release pairing Chapter 8 covered for a single hand-off, now repeating indefinitely over a bounded set of reusable slots.

<!-- DIAGRAM SPEC: cream #fdfbf7 background. A row of eight numbered ring slots drawn as boxes in a horizontal strip. A blue #4a73b8 "producer" box sits above the strip with an arrow labeled "claim + write" pointing at the slot just past an orange #a06030 "published sequence" marker. Two green #5a8870 "consumer" boxes sit below the strip, each with its own dashed cursor arrow pointing at a slot behind the published marker, labeled "consumer sequence (C1)" and "consumer sequence (C2)". A red #c0392b dashed arrow runs from the slower consumer's cursor back to the producer box, labeled "gating sequence = min(C1, C2) — back-pressure when ring is full". A bracket beneath consumer C1's cursor spans three slots labeled "one batch: read all published, not yet processed". -->
{% include excalidraw.html name="21-disruptor-ring" caption="Figure 21.1 — the ring as a messaging channel: a single producer claims and publishes slots, independent consumers trail the published sequence at their own pace, and the slowest consumer's position gates how far the producer can run ahead" %}

## The Disruptor Pattern

The Disruptor pattern, first described by LMAX for their trading platform, is what happens when you take the SPSC ring and generalize it to fan out to multiple independent consumers without reintroducing a lock. The mechanism is a **sequence barrier**: each consumer owns an atomic sequence counter recording the last slot index it has fully processed, and the producer (or, in a multi-stage pipeline, an upstream consumer) only advances past a slot once every downstream sequence that depends on it has moved past that point too.

Concretely, the ring tracks one **published sequence** (the highest slot index the producer has made visible), and each consumer tracks its own read position independently. A consumer never coordinates with its peers directly; it only compares its own sequence against the published sequence, processes everything newly available, and advances. Three consumers reading the same ring see the same events in the same order, each at its own pace, with no consumer ever blocking another. This is fan-out without broadcast copying: the event data is written once, and every consumer reads the same memory.

The producer side needs a **claim strategy** to decide which slot to write next and when it's safe to do so. In the single-producer case this is trivial — the producer's own uncontended counter, exactly as in Chapter 9's SPSC ring. A multi-producer variant needs producers to coordinate who gets which slot, typically with a compare-and-swap loop on a shared claim counter, which reopens the ABA and contention concerns Chapter 9 raised for MPMC structures. The pattern's real strength shows up in **pipelines**: a diamond dependency where one consumer (say, a journaling stage) must run before a second consumer (say, a business-logic stage) sees the same event, is expressed by having the second consumer's sequence barrier gate on both the producer's published sequence *and* the first consumer's sequence. No lock enforces the ordering — the dependent consumer refuses to read past a slot the upstream stage hasn't cleared yet, which is nothing more than an atomic load and a comparison.

## Batching and Back-Pressure

A consumer that wakes up, processes exactly one event, and re-checks the published sequence pays a synchronization cost for every single event: a cache-coherence round trip on the published-sequence read, and potentially a wake-up cost if it was parked. Batching removes nearly all of that cost by reading the published sequence once and processing every slot between the consumer's last position and that sequence in a single pass, before checking again. If the producer published ten events while the consumer was busy with the previous batch, the consumer picks up all ten in one sequence-barrier read instead of ten. Under load, this is precisely when batching pays off most: the busier the producer, the larger the batches, and the lower the per-event synchronization overhead becomes. At light load, a consumer still processes events essentially one at a time, since there's nothing accumulated to batch — the mechanism costs nothing extra in that case; there's just not much to amortize.

Back-pressure is the other half of the same gating sequence. The producer cannot claim slot `N` until every consumer that still needs to read an older slot in that same physical position (`N - capacity`) has advanced past it — the ring is finite, and overwriting an unread slot would corrupt data a consumer hasn't seen yet. This is enforced the same way forward progress is: the producer compares its intended claim against the slowest consumer's sequence, and if the ring is full relative to that consumer, the producer waits (spinning, yielding, or parking, depending on the configured wait strategy) rather than overwriting live data. Contrast this with a lock-based queue built on, say, `std::deque` behind a mutex with no capacity bound: a slow consumer there doesn't block the producer at all — the queue grows unchecked, trading memory for latency until something else (an OOM kill, a GC pause, a blown cache working set) makes the cost visible, usually at the worst possible moment. The ring's fixed capacity turns an invisible, unbounded liability into a visible, bounded one: back-pressure is loud and immediate rather than silent and deferred.

## The Single-Writer Principle

Everything above reduces to one property, already established in Chapter 9 for the SPSC case and now generalized: **every mutable location in the system has exactly one writer**. The producer is the sole writer of the published sequence. Each consumer is the sole writer of its own sequence counter. No thread ever writes a location another thread also writes, which means there is no write-write race for any synchronization primitive to arbitrate — the entire scheme works with plain atomic loads and stores (acquire on read, release on publish) and never needs a compare-and-swap loop, let alone a mutex.

This is why a single-producer Disruptor ring beats a lock-based queue on both throughput and tail latency, not just on average throughput. A mutex-protected queue serializes every producer and consumer through one critical section; even an uncontended `std::mutex` pays a CAS and, once contended, a futex round trip through the kernel, as [Chapter 5]({{ '/docs/05-shared-state-and-the-futex/' | relative_url }}) covered — and contention is exactly what happens under the bursty load patterns that matter in practice. The Disruptor's single-writer counters never contend with each other by construction, so there is no lock to queue behind and no convoy effect where one slow operation under the lock delays every other producer and consumer waiting on it. The cost moves from "serialize everyone through a shared critical section" to "each party polls its own and its neighbors' independent counters," which is cheap, parallel, and has no worst case that resembles lock convoying. The multi-producer variant gives some of this back — a CAS loop on a shared claim counter is still better-behaved under contention than a mutex, but it is no longer single-writer, and the pattern's strongest guarantees belong to the case where it is.

## Running in a container

A Disruptor-style pipeline's throughput depends almost entirely on where its threads land, which makes core placement the first thing to control in a container. Pin the producer and each consumer to distinct physical cores with `--cpuset-cpus`, and avoid placing two of them on hyperthread siblings of the same physical core — a busy-spinning consumer on one sibling steals execution resources from a producer scheduled onto the other, which looks like a contention problem but is actually a topology problem. `taskset -c` inside the container, combined with `--cpuset-cpus` at `docker run` (or the equivalent `CPUSetCpus` under podman) to restrict which host cores the container may use at all, keeps the CFS scheduler from migrating a hot consumer thread mid-run and invalidating its cache state.

Wait strategy matters more inside a container than outside one. A busy-spin consumer (the lowest-latency option) burns its full allotted CPU time continuously; under a `cpu.max` quota it will exhaust its slice and get throttled by the kernel well before `nproc`-based assumptions would suggest, and cgroup v2 exposes this directly as `throttled_usec` in `cpu.stat` — a climbing `throttled_usec` on a spinning consumer's cgroup is the first sign that the quota, not the algorithm, is adding latency. A yielding or futex-parking wait strategy trades a little best-case latency for much better behavior under a CPU quota, since a parked thread consumes no quota at all while waiting. Note too that `hardware_concurrency()` reflects cpuset-based affinity restrictions on glibc 2.36 and later, but it does not reflect a CFS `cpu.max` quota — a container capped to half a core's worth of CPU time can still report a full core count, which is a bad basis for deciding how many consumer threads to spawn; size the consumer pool from the configured quota, not from `hardware_concurrency()` alone.

## Standards: C++20 / C++23 / C++26

Three standards touch different parts of a Disruptor-style implementation: how a consumer waits without busy-spinning forever, how per-event handlers are stored without heap-allocating a copyable `std::function`, and, on the furthest horizon, how the whole pipeline might be expressed as composed asynchronous work rather than hand-rolled threads.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20: atomic wait/notify lets a consumer block on the published
// sequence instead of pure busy-spin, with no futex plumbing to hand-roll.
std::atomic<std::uint64_t> published{0};

// Consumer: spin briefly, then block cheaply if nothing new has arrived.
std::uint64_t seen = published.load(std::memory_order_acquire);
published.wait(seen, std::memory_order_acquire);  // returns when value != seen
```

```cpp
// C++23: std::move_only_function (header <functional>) stores a per-event
// handler without requiring it to be copyable, avoiding std::function's
// copy-constructibility requirement and its heap allocation for captures
// that only need to move.
#include <functional>

std::move_only_function<void(Event&)> handler =
    [state = std::make_unique<Accumulator>()](Event& e) mutable {
        state->add(e.value);
    };
handler(next_event);
```

```cpp
// C++26 (proposed, experimental — no shipping compiler implements
// std::execution yet): a consumer stage expressed as a sender scheduled
// onto a thread-pool scheduler, composing with upstream stages instead of
// hand-rolling the wait loop.
namespace ex = std::execution;

ex::sender auto pipeline =
    ex::schedule(pool.get_scheduler())
    | ex::then([] { return claim_next_batch(); })
    | ex::then([](auto batch) { process(batch); });
ex::sync_wait(std::move(pipeline));
```

The `atomic::wait`/`notify` pair from Chapter 8 is the practical default today: it gives a consumer a cheap blocking fallback without introducing a condition variable or a third-party futex wrapper, and it composes directly with the sequence-counter design above. `std::move_only_function` is a smaller but real win for pipelines with per-stage closures that own non-copyable state (a unique accumulator, an owned file handle) — before C++23 those had to be wrapped in a `shared_ptr` purely to satisfy `std::function`'s copyability requirement, which is pure overhead on a hot path. `std::execution` is worth knowing about and nothing more right now: it reframes a Disruptor pipeline as composed senders over a scheduler rather than threads explicitly waiting on sequence barriers, but it ships in no current compiler, and the proposal shape may still change before it does.

## What we learned

- A Disruptor-style ring is the SPSC/MPMC ring from Chapter 9 looked at as a messaging channel: fixed, pre-allocated event slots, a published sequence the producer advances, and independent consumer sequences that trail it at their own pace.
- The pattern's defining mechanism is the sequence barrier: a consumer gates on the producer's published sequence and, in a pipeline, on upstream consumers' sequences too, which expresses fan-out and staged dependencies with nothing but atomic loads and comparisons.
- Batching amortizes synchronization cost by processing every newly published slot in one pass instead of re-checking per event, and back-pressure falls out of the same gating sequence: the producer cannot overwrite a slot the slowest consumer hasn't read yet, turning an unbounded-queue liability into a bounded, visible one.
- The single-writer principle (exactly one writer per mutable location) is what removes the lock entirely for the single-producer case, and it's why the pattern beats a mutex-protected queue on tail latency as well as throughput: there is no critical section for a convoy to form behind.
- Core placement dominates a Disruptor pipeline's measured performance inside a container; a spinning wait strategy and a CFS `cpu.max` quota interact badly, visible directly as `throttled_usec`, and `hardware_concurrency()` won't warn you about it.

<!-- EXAMPLE SPEC: examples/concurrency/21-lock-free-messaging-and-the-disruptor/ implements a single-producer ring with two independent consumers (a "journal" stage and a dependent "business logic" stage gated on the journal's sequence), a configurable wait strategy (busy-spin, yield, or atomic wait/notify), and a --batch-report flag that logs observed batch sizes; it measures sustained throughput and p99.9 publish-to-consume latency against an equivalent std::mutex + std::deque baseline at matched producer rates. Verified by a Lua verify.lua asserting total events consumed by each stage equals events published, that the dependent stage never reads past the journal stage's sequence, and that back-pressure engages (producer blocks) once the ring fills relative to the slower consumer; built via lgtm-docker-stack with taskset-pinned producer/consumer variants for the core-placement comparison in the container section above. -->
The example at `examples/concurrency/21-lock-free-messaging-and-the-disruptor/` builds exactly this two-stage pipeline and is the place to measure your own hardware's numbers rather than trust anyone else's. For a historical reference point: LMAX's original 2011 Disruptor whitepaper reported sustained throughput above 25 million messages per second on the hardware available to them at the time, against a three-order-of-magnitude-slower lock-based queue on the same machine — worth treating as a data point about the shape of the win, not as a number to expect on current hardware or to quote as this book's own measurement.
