---
title: "Capstone: Ingest, Match, Publish"
order: 33
layout: tutorial
sectionid: docs
part: practice
description: "An end-to-end low-latency pipeline (ingest, match, publish) that composes the concurrency, lock-free messaging, and observability patterns from the rest of the book, measured under load."
duration: "26 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/56-capstone-comparison.md + linux-systems-programming/_docs/41-capstone-fleet.md | anchor books: all -->

## What we'll cover

- Compose a single end-to-end pipeline, ingest, match, publish, using one consistent workload so every stage is measured on the same basis.
- Instrument the pipeline to show which concurrency model actually ran each stage, not just which one was configured.
- Instrument the pipeline to show what synchronization between stages actually cost, in both latency and throughput.
- Tie the measured results back to the patterns from earlier parts: thread pools, lock-free queues, mechanical sympathy, and observability.

Every earlier chapter in this book picked one concurrency model, one synchronization primitive, one workload, and measured it in isolation — a thread pool here, a lock-free ring there, a fast path somewhere else, each chosen to show that one idea at its clearest. That isolation was deliberate and it was also a simplification: a real low-latency service is never one technique running alone. It is several of them wired together into stages, each stage handing work to the next under constraints the earlier stage didn't have to think about. This chapter builds that wiring once, as a single pipeline (ingest, match, publish), and runs it under one workload so the earlier chapters' individually-true claims can be checked against how they behave stacked on top of each other.

## The Pipeline: Ingest, Match, Publish

The workload is an order book. Clients submit orders (`NEW` to add one, `CANCEL` to remove one), tagged with a client-assigned sequence number and a deadline. The pipeline's job is to accept orders concurrently from many clients, apply them to a single shared order book in the order the matching stage decides is canonical, and publish every resulting event (an acknowledgment, a trade, a rejection) to subscribers, all while bounding tail latency from the moment an order arrives to the moment its outcome is published.

Three stages do this work, and each stage's design is a direct application of an earlier chapter rather than a new idea invented for this one.

**Ingest** accepts connections concurrently — a small pool of worker threads from [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}), each handling a subset of client connections the way [Concurrent gRPC Services]({{ '/docs/25-concurrent-grpc-services/' | relative_url }}) and [Concurrent REST Endpoints]({{ '/docs/24-concurrent-rest-endpoints/' | relative_url }}) described, whichever transport a given deployment chooses. Each ingest thread decodes inbound frames, stamps them with an arrival timestamp, checks the order's deadline against [Time, Timers, and Deadlines]({{ '/docs/03-time-timers-and-deadlines/' | relative_url }})'s wall-clock discipline, and rejects anything already expired before it ever reaches the book — a deadline that has passed by the time an order is decoded is not useful work for the matching stage to do, it is wasted work that would only cost that stage cycles it cannot get back. Orders that pass the deadline check are published onto a lock-free ring.

**Match** is a single thread, pinned to one core, and it is single-threaded on purpose. An order book is fundamentally a serial data structure — "apply this order, then that one, in a specific sequence" is the entire contract of price-time priority matching, and a lock around a shared book would only reintroduce, as a bottleneck, the same serialization a single dedicated thread already gives for free. This is [Design and Architecture Patterns]({{ '/docs/31-design-and-architecture-patterns/' | relative_url }})'s single-writer pattern applied at the stage level: the match thread is the sole writer of the order book, every ingest thread is a reader-free producer into its input ring, and there is exactly one place in the whole pipeline where two orders could race — and it has been designed so that they structurally cannot. The match thread runs [The Low-Latency Fast Path]({{ '/docs/19-the-low-latency-fast-path/' | relative_url }})'s playbook directly: pinned core, zero heap allocation per order (the book's internal structures are pre-sized), and a busy-poll read of its input ring rather than a blocking wait, since a parked match thread waiting on a futex wakeup is exactly the scheduler round-trip a matching engine's latency budget cannot absorb.

**Publish** takes the match stage's output (one event per processed order) and fans it out to subscribers. Unlike the match stage, publish genuinely benefits from parallelism: encoding and writing to N independent subscriber connections is embarrassingly parallel work, so a small pool of publish threads, each draining the same output ring and writing to a disjoint subset of subscribers, uses [Lock-Free Data Structures]({{ '/docs/09-lock-free-data-structures/' | relative_url }})'s multi-consumer techniques without reintroducing a lock on the hot path.

Ingest and publish are each a boundary where the pipeline hands work from one concurrency domain to another, and both boundaries are the same structure: a bounded, lock-free ring built on [Lock-Free Messaging and the Disruptor]({{ '/docs/21-lock-free-messaging-and-the-disruptor/' | relative_url }})'s single-writer-per-sequence design. Ingest's ring is many-producer (every ingest thread writes) feeding the single match-thread consumer; publish's ring is single-producer (the match thread, the pipeline's sole writer of outcomes) feeding several consumer threads. Both rings are bounded rather than growable, which is what makes back-pressure visible instead of silent: when the match thread falls behind the arrival rate, the ingest ring's gating sequence refuses new claims, and ingest threads shed load (reject new orders with a `BUSY` response) rather than let an unbounded queue absorb the backlog the way a `std::deque` behind a mutex would, trading an invisible memory liability for a visible, immediate one exactly as Chapter 21 described for the general case.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, full pipeline architecture left to right. Left: a column of blue #4a73b8 "ingest thread" boxes (labeled ingest-1..ingest-N) each receiving an arrow from a small "client" icon, each stamped "deadline check (ch3)" and each feeding into a shared orange #a06030 ring labeled "ingest ring (MPSC, ch21) -- single writer per slot, gated by match thread's sequence". An arrow from that ring into a single green #5a8870 box labeled "match thread -- PINNED CORE, single writer of order book (ch19, ch31), busy-poll read, zero alloc". A red #c0392b dashed arrow loops from the ingest ring back to the ingest threads labeled "BACK-PRESSURE: ring full -> reject new orders (BUSY), never grow unbounded". From the match thread, an arrow into a second orange ring labeled "publish ring (SPMC, ch9/ch21)", fanning out to a row of blue "publish thread" boxes (publish-1..publish-K) each writing to a "subscriber" icon. A thin dashed line runs along the top of the whole diagram labeled "OTel span: ingest_ts -> match_ts -> publish_ts (ch29)" with small span-start/span-end marks over the ingest box, the match box, and the publish boxes. A footer band shows a stopwatch icon labeled "end-to-end latency = publish_ts - ingest_ts, measured ch18-style (warmed, percentile, not mean)". -->
{% include excalidraw.html name="33-pipeline-architecture" caption="Figure 33.1 — the full ingest-to-publish pipeline: many ingest threads feeding a single pinned match thread over a lock-free ring, fanning out through a second ring to several publish threads, with an OTel span carried through every stage" %}

## Instrumenting the Pipeline

A pipeline built from three different concurrency shapes is exactly where "which model actually ran this" stops being an academic question and starts being the first thing worth verifying, not assuming. The instrument is the same one [Benchmarking Without Deception]({{ '/docs/18-benchmarking-without-deception/' | relative_url }}) insists on for any claim about where time goes: measure the thing directly rather than infer it from the configuration. For this pipeline, that means recording, for every processed order, which OS thread (`gettid()`) touched it at each stage, and feeding that into [Observing Concurrency]({{ '/docs/29-observing-concurrency/' | relative_url }})'s tracing setup as a span attribute rather than a debug print that gets compiled out of the build that matters.

A single OTel trace per order, with one span per stage (`ingest`, `match`, `publish`), carries the thread id, the ring occupancy at the moment the order was claimed, and the elapsed time within that span, as attributes. This does two things a static architecture diagram cannot. First, it confirms the match stage really is single-threaded in the running system, not just in the source: every `match` span in every trace should carry the identical `thread.id` attribute, and a verification pass that groups spans by stage and counts distinct thread ids should report exactly one for `match` and N (the configured pool size) for `ingest` and `publish`. A match stage that ever reports more than one distinct thread id has a configuration bug serious enough to invalidate every correctness assumption the single-writer design depends on, and it is precisely the kind of bug that produces no compiler warning and no crash — only a book-keeping discrepancy that surfaces much later as a data race nobody can reproduce. Second, the ring-occupancy attribute recorded at each hand-off is what makes the cost of synchronization between stages visible rather than inferred: a `match` span's ingest-ring-occupancy attribute climbing steadily across a trace window is the pipeline's own evidence that ingest is outpacing match, well before the ring fills completely and back-pressure engages.

The span-attribute discipline matters as much as the instrumentation itself. Thread-local correlation state does not survive a hand-off between an ingest thread and the match thread the way it might within a single coroutine's frame — the order's trace context has to travel explicitly as part of the message that crosses the ring, not as ambient state either side assumes the other can see. This is the same lesson [Communication Models]({{ '/docs/22-communication-models/' | relative_url }}) draws about state crossing a concurrency boundary: carry it explicitly in the payload, or lose it the moment the receiving side is a different thread than the sender expected.

## Measuring End to End

The metric that matters is the one no individual stage's own benchmark can produce alone: the wall-clock interval from the moment an order's bytes are fully received at ingest to the moment its outcome is written to a subscriber's socket at publish. Measuring it correctly means applying Chapter 18's full discipline rather than a quick `std::chrono` delta around a single run — warm the pipeline before recording a single measurement, run enough iterations that a percentile estimate is meaningful rather than three samples dressed up as a distribution, and report `p50`/`p99`/`p99.9` rather than a mean that a handful of outliers can hide inside.

Two load shapes are worth running, because they stress different parts of the design. A sustained load at a fixed, moderate order rate exercises the steady-state path (ingest ring occupancy staying low, match keeping pace, publish fanning out without falling behind), and its percentiles are the number a capacity-planning conversation actually wants. An overload burst, submitted faster than the match thread can drain, is what tests the back-pressure path specifically: the ingest ring should fill, ingest threads should start returning `BUSY` rather than blocking indefinitely or growing an unbounded buffer, and the orders that do get admitted during the burst should show their tail latency climb in a way that is bounded by the ring's fixed capacity and the match thread's fixed throughput — not open-ended, because nothing in this design has an unbounded queue anywhere for the overload to hide inside.

The disciplined way to state results in a published chapter, the discipline this book has held to throughout, is to describe what the included benchmark measures and let the example produce the numbers on the hardware actually running it, rather than presenting any particular latency figure here as this book's own measurement. A matching engine's achievable p99 depends on core topology, kernel configuration, NIC and scheduler tuning, and the specific hardware under test closely enough that a number quoted in prose would be more likely to mislead a reader about their own hardware than to inform them about this pipeline's design.

## Tying the Book Together

Looked at end to end, nearly every earlier chapter in this book shows up as a specific, consequential design decision in this pipeline rather than a technique chosen for its own sake. [Atomics and the Memory Model]({{ '/docs/08-atomics-and-the-memory-model/' | relative_url }}) and [Lock-Free Data Structures]({{ '/docs/09-lock-free-data-structures/' | relative_url }}) are the acquire/release pairing underneath both rings' claim-and-publish sequences. [Mechanical Sympathy]({{ '/docs/20-mechanical-sympathy/' | relative_url }}) is why the ring's slots and the match thread's book structures are laid out to avoid false sharing between the hot sequence counters and the cold event payloads. [Error Handling vs Exception Handling]({{ '/docs/26-error-handling-vs-exception-handling/' | relative_url }}) governs how a malformed order or a full ring is reported back to ingest without an exception ever unwinding across a ring hand-off, where there is no stack on the other side to catch it. [Coding Practices for Concurrency]({{ '/docs/30-coding-practices-for-concurrency/' | relative_url }}) is the review discipline that keeps the match thread's single-writer invariant from eroding the first time someone adds a feature that seems like it only needs to "peek" at the book from another thread. And [Concurrency in Containers]({{ '/docs/32-concurrency-in-containers/' | relative_url }}) governs how this pipeline is actually deployed: the match thread's pinned core is only a real guarantee under a cpuset-exclusive allocation, and every pool in this design (ingest's, publish's) is sized from the deployment's real quota rather than a host-wide probe.

None of this composition was free, and that is worth drawing out explicitly. Each stage's concurrency model was chosen because of what it had to do, not out of a general preference: a thread pool for ingest because connection handling parallelizes trivially, exactly one pinned thread for matching because the book does not, and a small consumer pool for publish because fan-out does again. A pipeline using the same model for every stage, all threads or all single-writer, would have under-served at least one of the three jobs. The earlier chapters' individually-true claims about which model wins at what did not stop being true once stacked together; they combined into a design where each stage's model is the one its job actually needs.

## Running in a container

Each stage runs as its own container in this chapter's compose stack, which makes the container chapter's pinning rules directly operational rather than theoretical: the match container gets a cpuset-exclusive core allocation (two cores — one for the match thread, one held in reserve so its busy-poll loop's full utilization never starves the container's own health-check or logging path), while ingest and publish run in containers sized from a shared CPU quota with pool sizes derived the way [Concurrency in Containers]({{ '/docs/32-concurrency-in-containers/' | relative_url }}) describes, not from `hardware_concurrency()`. A load generator runs as a fourth container, driving the sustained and overload profiles above against the ingest container's exposed port. Running the match container without its cpuset-exclusive allocation, a quick, deliberate misconfiguration, is a useful exercise in its own right: the same workload under a shared quota instead of a pinned core shows CFS throttling pauses landing directly on the match thread's latency distribution, visible both in the recorded p99.9 and in `cpu.stat`'s `throttled_usec` climbing in lockstep with the degraded tail. The compose stack wires OTel export from all four containers to a single collector, so the per-stage trace above is inspectable as one timeline regardless of which container produced which span.

## Standards: C++20 / C++23 / C++26

The pipeline's hand-off points are where standards versions make a visible difference: how the match thread's busy-poll loop falls back to a cheap block, how a per-order outcome is returned without heap-allocating a closure, and, on the furthest horizon, how an entire stage might be expressed as composed asynchronous work.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20: the match thread busy-polls the ingest ring briefly, then falls
// back to atomic wait/notify rather than spinning forever when the
// pipeline is genuinely idle -- cheap in both the hot and the idle case.
std::uint64_t seen = ingest_ring.published.load(std::memory_order_acquire);
for (int spins = 0; spins < kSpinBudget; ++spins) {
    if (seen != last_claimed) break;
    seen = ingest_ring.published.load(std::memory_order_acquire);
}
if (seen == last_claimed) {
    ingest_ring.published.wait(last_claimed, std::memory_order_acquire);
}
```

```cpp
// C++23: std::expected (header <expected>) carries a per-order outcome
// -- accepted, rejected, or deadline-expired -- across the ingest/match
// boundary without an exception type that would have to unwind across
// a plain ring hand-off with no call stack to catch it on the other side.
#include <expected>

enum class OrderError { ring_full, deadline_expired, malformed };

std::expected<OrderId, OrderError> submit(const Order& o) {
    if (o.deadline < clock::now()) return std::unexpected(OrderError::deadline_expired);
    if (!ingest_ring.try_claim()) return std::unexpected(OrderError::ring_full);
    return ingest_ring.publish(o);
}
```

```cpp
// C++26 (proposed, experimental -- no shipping compiler implements
// std::execution yet): the publish stage expressed as a sender pipeline
// scheduled across a worker pool, composing fan-out instead of a
// hand-rolled consumer-thread loop.
namespace ex = std::execution;

ex::sender auto publish_stage =
    ex::schedule(publish_pool.get_scheduler())
    | ex::then([] { return drain_publish_ring(); })
    | ex::bulk(subscriber_count, [](int i, auto& batch) { send_to(i, batch); });
ex::sync_wait(std::move(publish_stage));
```

`atomic::wait`/`notify` is the practical choice already in production use across this book's examples: a bounded spin budget keeps the match thread's common-case latency at its busy-poll floor, while the fallback avoids pinning a core at 100% utilization indefinitely once there is genuinely no work. `std::expected` is a direct, small win at exactly the ingest/match boundary this pipeline depends on, since a ring hand-off has no stack frame on the receiving side for an exception to unwind into — a typed return value is the only option that was ever going to work cleanly there, and C++23 is the first standard where it comes from the library rather than a hand-rolled variant. `std::execution`'s bulk-and-schedule composition is worth recognizing as the likely future shape of the publish stage's fan-out, but it remains an experimental, non-shipping feature as of this writing, and nothing in the pipeline's correctness depends on it arriving on any particular timeline.

## What we learned

- A real low-latency pipeline composes several concurrency models rather than picking one: a thread pool where work parallelizes (ingest, publish) and exactly one pinned single-writer thread where it structurally cannot (match), each choice following directly from what that stage's job requires.
- The hand-offs between stages are bounded, lock-free rings built on the single-writer sequence discipline from the messaging chapter, and their fixed capacity is what turns an overload condition into a visible, immediate back-pressure signal (`BUSY`) instead of an unbounded, silently growing queue.
- "Which thread actually ran this stage" is a claim worth verifying with a real instrument — a `thread.id` span attribute recorded per stage — rather than assumed from the architecture diagram; a match stage reporting more than one distinct thread id has broken the design's central correctness guarantee.
- End-to-end latency has to be measured with the same discipline as any single-stage benchmark: warmed, repeated, reported as percentiles rather than a mean, under both a sustained load and an overload burst that specifically exercises the back-pressure path.
- Deployment choices from the containers chapter are not optional polish here: the match thread's pinned core is only a real guarantee under cpuset-exclusive allocation, and a shared-quota misconfiguration shows up directly as CFS throttling in the match stage's own tail latency.
- No latency number in this chapter is presented as the book's own measurement; the included example is where a reader's own hardware produces the real figures.

<!-- EXAMPLE SPEC: examples/concurrency/33-capstone-ingest-match-publish/ implements the full three-stage pipeline described above: a concurrent ingest listener (thread-per-connection pool) decoding NEW/CANCEL order frames with a deadline check, a many-producer lock-free ring feeding a single pinned matching thread that applies price-time-priority matching to an in-memory order book with zero per-order heap allocation, and a single-producer ring fanning out through a small publish thread pool to subscriber connections; every stage emits an OTel span (ingest/match/publish) carrying a thread-id attribute and ring-occupancy attribute, exported to an OTel collector via lgtm-docker-stack. A companion load generator drives a sustained profile and a deliberate overload burst. Verified by a Lua verify.lua that asserts (1) every ingested order that is accepted (not rejected for a full ring or an expired deadline) appears exactly once in the published output, in the same relative order the match thread processed it; (2) all "match" spans across a full run share one and only one thread-id attribute; (3) under the overload burst, the ingest ring's occupancy reaches capacity and a measurable fraction of submissions receive BUSY rather than blocking indefinitely or growing memory unbounded; and (4) recorded p50/p99/p99.9 end-to-end latency figures are present in the benchmark's output (values are reported by the run, not asserted against a fixed threshold, consistent with this chapter's refusal to assert a portable absolute latency number). Each stage runs as its own container under lgtm-docker-stack, with the match container alone given a cpuset-exclusive core pin, matching the "Running in a container" section's configuration. -->
The example at `examples/concurrency/33-capstone-ingest-match-publish/` is the full, runnable version of the architecture above, and it is the place to watch the back-pressure path actually engage and to generate the percentile figures this chapter deliberately did not put a number on.
