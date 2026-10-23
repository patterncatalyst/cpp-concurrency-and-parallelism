---
title: "Design and Architecture Patterns"
order: 31
layout: tutorial
sectionid: docs
part: practice
description: "Pipeline and SEDA architectures, sharding and the single-writer pattern, the reactor and proactor behind half-sync/half-async, fan-out/fan-in, and a decision framework for matching a concurrency architecture to a latency or throughput goal."
duration: "16 min"
---

<!-- PROVENANCE: NEW | anchor books: Grokking Concurrency, Son, Grimm -->

## Learning objectives

By the end of this chapter you can:

- Decompose a workload into a SEDA or pipeline architecture with independently sized pools and bounded, observable queues between stages.
- Apply the single-writer pattern at the system level by sharding state so each shard's writes need no lock.
- Distinguish reactor (readiness-based) from proactor (completion-based) dispatch and structure a half-sync/half-async boundary around either one.
- Extend a pipeline stage with fan-out/fan-in, joining parallel replicas with a `std::latch`.
- Choose and justify a concurrency architecture for a given workload shape and a given latency or throughput target.

## Why this matters

Every primitive and pattern in the earlier chapters answers a question about two threads and one piece of shared data. None of them answers the question a system's first design review actually asks: what is the shape of this service, and does that shape match what the workload needs? A team that reaches for a thread pool everywhere, or a lock-free queue everywhere, has a toolbox but not an architecture, and the mismatch shows up as a rewrite once the service is under real load.

This chapter supplies the missing vocabulary: pipeline and SEDA for decomposing a request into stages, sharding and the single-writer pattern for parallelizing by data rather than by phase, and half-sync/half-async for keeping ordinary blocking code on top of non-blocking I/O. Naming which one a design actually is, before committing to it, is what turns a stack of individually sound techniques into a system that holds up under load.

## What we'll cover

- Cover pipeline and SEDA (staged event-driven architecture) designs for decomposing a workload into concurrent stages.
- Cover sharding and the single-writer pattern as a way to parallelize without synchronizing.
- Cover the half-sync/half-async architecture as a bridge between blocking application code and async I/O.
- Give a decision framework for choosing a concurrency architecture based on workload shape and latency targets.

Every earlier chapter in this book answered "how do two threads safely touch the same data" or "how does one component hand work to another." This chapter is about the shape of the whole system those components sit inside: the handful of architectures that recur across concurrent services regardless of language or domain, each trading a specific kind of simplicity for a specific kind of constraint. None of these patterns is new; this chapter builds the vocabulary to name which one a given design actually is, and the judgment to pick the right one before the wrong one gets load-tested into a rewrite.

## Pipelines and SEDA

A **staged event-driven architecture** (SEDA), the pattern Matt Welsh's original work on internet services formalized, decomposes a request's processing into a sequence of stages, each with its own thread pool and its own bounded queue feeding it. A request moves through the pipeline stage by stage (parse, validate, compute, persist, respond), crossing a queue boundary between each pair of stages rather than running start to finish on one thread. [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }})'s sizing rules apply independently to every stage's pool, because a parse stage that's pure CPU work and a persist stage that's mostly waiting on disk or a downstream store have nothing in common workload-wise and should never share one pool sized by either one's rule alone.

The queue between two stages does real work beyond moving data: it decouples each stage's throughput from its neighbors', so a slow persist stage backs up its own queue without starving the parse stage upstream, and it gives each stage an independent admission-control point: the same block/reject/drop choice [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}) laid out, applied per stage rather than once for the whole pipeline. It also makes the pipeline observable in the terms [Observing Concurrency]({{ '/docs/29-observing-concurrency/' | relative_url }}) established: a queue-depth metric per stage shows which stage is the bottleneck, not just that the request was slow somewhere.

The cost is the hand-off itself. Every stage boundary is a context switch and usually a cache-cold start for the next stage's thread, the opposite of a single-thread-per-request model's locality. A pipeline earns that cost back when stages differ in blocking behavior or resource profile; it's a poor fit for a request whose entire path is a few microseconds of uniform CPU work, where the hand-off would dwarf the work being staged.

Fan-out and fan-in extend the pipeline to parallel replicas of a single stage: a stage fans a request out to N identical next-stage workers, and a downstream join stage fans the results back in once all N finish; a `std::latch` set to N, released by each worker, is the direct primitive for that join. This is the shape behind a scatter-gather search across shards, or a computation split into independent partitions and recombined at the end; it composes with SEDA naturally, since the replicas are simply N instances of one stage's pool.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, left-to-right flow. Four blue #4a73b8 stage boxes in sequence: "Parse", "Validate", "Compute", "Persist": each with a small pool icon (three dots) beneath its label and a cream bounded-queue box between each pair of stages, each queue box annotated with a small bar-chart icon labeled "depth metric". Below the "Compute" stage, branch it into three green #5a8870 parallel "Compute" replica boxes (fan-out), each feeding into an orange #a06030 "Join (latch N=3)" box before continuing to "Persist" (fan-in). A red #c0392b annotation beneath the whole chain reads "each queue boundary = context switch + cold cache for the next stage". -->
{% include excalidraw.html name="31-seda-pipeline" caption="Figure 31.1. A SEDA pipeline: independently pooled and queued stages, with a fan-out/fan-in detour around the Compute stage joined by a latch before the pipeline continues" %}

## Sharding and the Single-Writer Pattern

Where a pipeline parallelizes across the *phases* of a request, sharding parallelizes across the *data* a system holds, by partitioning state into N shards (by key hash, by key range, or by some domain-specific split such as symbol, account, or tenant) and assigning each shard exactly one writer thread. [Lock-Free Messaging and the Disruptor]({{ '/docs/21-lock-free-messaging-and-the-disruptor/' | relative_url }})'s single-writer principle, there applied to one ring buffer's sequence counters, generalizes directly: if every mutable piece of a shard's state has exactly one writer, that writer needs no lock to touch it, because nothing else ever writes it. A request for key `K` is routed to the shard owning `K` (a modulo or consistent-hash lookup), and that shard's single thread (which may itself be [The Actor Model and Channels]({{ '/docs/23-the-actor-model-and-channels/' | relative_url }})'s confined actor loop, pulling requests off that shard's mailbox) processes it without ever coordinating with any other shard's thread.

This is the architecture behind partitioning a market-data feed or an order book by instrument symbol: each symbol's book has exactly one writer, so two symbols' updates never contend for the same lock, and the system's total write throughput scales with the number of shards rather than being capped by one shared structure's serialization point. The single hard case sharding introduces is any operation spanning more than one shard (a transaction touching two accounts in different shards, say), where the single-writer guarantee no longer covers the whole operation by construction. The answers are to coordinate explicitly (a two-phase protocol, or routing the whole operation through a designated coordinator that owns both shards' locks in a fixed order) or to redesign the key space so the operation doesn't span shards in the first place, which is usually the better fix when the cross-shard case is common enough to matter, since explicit cross-shard coordination reintroduces exactly the contention sharding was meant to remove.

```cpp
// A sharded router: each shard owns its state and is driven by exactly one
// worker thread, reached only through that shard's mailbox. No lock is
// needed on shard state because no other thread ever touches it.
template <typename Key, typename State>
class ShardedStore {
public:
    explicit ShardedStore(std::size_t n_shards) : shards_(n_shards) {}

    void dispatch(const Key& key, std::move_only_function<void(State&)> op) {
        auto& shard = shards_[std::hash<Key>{}(key) % shards_.size()];
        shard.mailbox.send(std::move(op));  // routed; never touched here
    }

private:
    struct Shard {
        Mailbox<std::move_only_function<void(State&)>> mailbox{64};
        std::jthread worker{[](std::stop_token st) { /* drain mailbox, apply ops to State */ }};
    };
    std::vector<Shard> shards_;
};
```

Resharding, moving a key range from one shard to another to rebalance load, is the operational wrinkle sharding defers rather than avoids: migrating a range safely requires briefly quiescing writes to that range on the old shard before the new shard takes ownership, or routing requests for keys mid-migration through a short-lived coordinator that knows which shard currently owns them. It's a real cost, but it's a cost paid occasionally, during a planned rebalance, rather than on every request the way a shared-state design's locking cost would be.

## Half-Sync/Half-Async

A **reactor** demultiplexes readiness events from many file descriptors through one blocking call (`epoll_wait` or its equivalents, the mechanism [Async Runtimes and Event Loops]({{ '/docs/12-async-runtimes-and-event-loops/' | relative_url }}) covered), and dispatches each ready descriptor's handler synchronously on the thread running that call. The reactor tells a handler "this descriptor is ready for reading," not "here is the data": the handler still performs the read itself once notified. A **proactor** moves that read onto the operating system: with `io_uring` or an I/O completion port, the kernel performs the operation and notifies the application only once it's done, handing the handler a completed result rather than mere readiness. The distinction is readiness-based versus completion-based notification, and on Linux, `io_uring` pulls the reactor model's traditional epoll-based implementations toward the proactor shape.

Either way, a reactor or proactor's event loop is poorly suited to running application logic directly on its own thread: a handler that blocks (a slow downstream call, a lock held too long) stalls every other descriptor multiplexed through that loop. **Half-sync/half-async**, from the POSA literature, splits the system into a synchronous layer, where application code is ordinary blocking call-and-return logic with no callbacks, and an asynchronous layer, where a reactor or proactor handles I/O without ever blocking its own thread, connected by a queueing layer that hands completed I/O results to sync-side workers and outgoing requests back to the async side to dispatch.

That queueing layer is the boundary [Observing Concurrency]({{ '/docs/29-observing-concurrency/' | relative_url }})'s context-propagation discussion was about: a request crossing from the async side to a sync-side worker and back needs its trace context carried across both hops explicitly, for the same reason a thread-pool submission does. The payoff is that application code stays ordinary, readable, blocking logic, while the I/O-heavy, concurrency-sensitive part stays confined to the async layer, instead of every piece of business logic written in continuation-passing style because some of it eventually touches a socket.

## Choosing a Concurrency Architecture

None of these patterns is a default; each answers a different question about a workload, and a short framework narrows the choice faster than trying all of them.

If the workload partitions cleanly by key, with little or no cross-key interaction, sharding with a single writer per shard is close to free parallelism: no lock, no contention, throughput that scales with shard count. If a request's processing has several phases with different cost or blocking profiles (some CPU-bound, some I/O-bound, some with wildly different latency), a pipeline or SEDA decomposition isolates each phase's resource needs and makes the bottleneck observable per stage, at the cost of hand-off overhead between stages. If most of a request's time is spent waiting on I/O and the per-request logic itself is simple, a reactor or proactor keeps a small number of threads servicing a large number of connections without paying for one thread per connection, and half-sync/half-async is the way to keep the application logic itself written as ordinary blocking code on top of that. If a single request's latency is dominated by one expensive, independent computation that can be split into parallel pieces, fan-out across a pool followed by a fan-in join is the direct answer, whether that pool is a generic [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}) pool or N shard workers being queried in parallel.

These compose rather than compete in a real system: a SEDA stage is often internally sharded (a persist stage with one writer per shard of the data it's persisting), and a half-sync/half-async boundary often feeds the first stage of a pipeline rather than feeding application logic directly. [The Low-Latency Fast Path]({{ '/docs/19-the-low-latency-fast-path/' | relative_url }})'s single-digit-microsecond budget tends to push toward the architectures with the fewest hand-offs on the critical path: sharding with confined, lock-free single writers, or a tight reactor loop with no queueing layer at all for the hottest requests. A throughput-oriented batch system can afford a deeper pipeline with more stages, because its latency budget per request is measured in milliseconds rather than microseconds and the isolation a pipeline buys is worth more than the hand-off cost it adds. The architecture question is ultimately the same question [Mechanical Sympathy]({{ '/docs/20-mechanical-sympathy/' | relative_url }}) asked about hardware: how many boundaries does the critical path actually need to cross, and what does each one cost, measured rather than assumed.

## Running in a container

A multi-stage SEDA pipeline is straightforward to run and observe as a single process in one container, with each stage's pool pinned to distinct cores via `--cpuset-cpus` the same way [Lock-Free Messaging and the Disruptor]({{ '/docs/21-lock-free-messaging-and-the-disruptor/' | relative_url }}) pinned a producer and its consumers, and each stage's queue depth exported as the saturation metric Chapter 29 defined: the per-stage view is what tells you which stage to scale, rather than an aggregate number that only says the pipeline as a whole is behind. Splitting the same pipeline across multiple containers (one service per stage, connected over the compose network rather than in-process queues) trades in-process hand-off cost for network latency and makes the half-sync/half-async boundary explicit at the container edge, which is a reasonable choice once a stage needs to scale independently of its neighbors on separate hosts, but is unnecessary overhead for a pipeline that fits comfortably in one process and one container.

Either way, [Concurrency in Containers]({{ '/docs/32-concurrency-in-containers/' | relative_url }}) applies per stage, not once for the whole pipeline: a cgroup CPU quota caps the container as a whole, and a pipeline sizing each stage's pool off `hardware_concurrency()` rather than the container's actual `cpu.max` oversubscribes the quota in aggregate even if each individual stage's pool looks reasonably sized on its own; it's the same lesson Chapter 15 established for a single pool, now applied once per stage.

## Standards: C++20 / C++23 / C++26

Three standards map cleanly onto this chapter's patterns: a one-shot and a cyclic synchronization primitive for fan-out/fan-in and multi-phase pipelines, a coroutine-based generator and an error type suited to a pull-based pipeline stage, and a pipeline-composition model on the horizon that mirrors a SEDA stage chain directly in code.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20: std::latch for a one-shot fan-in join (wait for N parallel shard
// workers to finish one phase before the join stage proceeds), and
// std::barrier for a pipeline where every participant must reach a sync
// point each round before any of them starts the next round.
std::latch fan_in(3);
auto worker = [&fan_in](Shard& s) {
    s.process_phase();
    fan_in.count_down();
};
fan_in.wait();  // join stage proceeds once all 3 shard workers finish

std::barrier round_sync(4, [] { /* runs once, after all 4 arrive */ });
// each pipeline participant, every round:
round_sync.arrive_and_wait();
```

```cpp
// C++23: std::generator (a coroutine-based range) lets a pull-based
// pipeline stage lazily yield transformed items to the next stage without
// hand-building a queue, and std::expected propagates a stage's failure
// across the queue boundary without throwing across a thread hand-off.
#include <expected>
#include <generator>

std::generator<std::expected<Record, ParseError>> parse_stage(InputRange& in) {
    for (auto&& line : in) {
        if (auto rec = try_parse(line)) {
            co_yield *rec;
        } else {
            co_yield std::unexpected(rec.error());
        }
    }
}
```

```cpp
// C++26 (proposed; targets the accepted P2300 std::execution model, not
// yet shipping in a mainstream standard library — shown against the
// stdexec reference implementation's API shape). A SEDA-style pipeline
// expressed as a sender chain, where each stage's scheduler stands in for
// that stage's pool, making the hand-off between stages a visible part of
// the composition rather than an implicit queue the reader has to infer.
namespace ex = std::execution;

ex::sender auto pipeline =
    ex::schedule(parse_pool.get_scheduler())   | ex::then(parse)
  | ex::continues_on(compute_pool.get_scheduler()) | ex::then(compute)
  | ex::continues_on(persist_pool.get_scheduler()) | ex::then(persist);
ex::sync_wait(std::move(pipeline));
```

`std::latch` and `std::barrier` are the direct standard-library answer to fan-out/fan-in and round-based pipeline synchronization respectively: before C++20, both had to be hand-rolled from a mutex, a condition variable, and a counter, with the barrier's reusability (resetting for the next round) as the easy part to get subtly wrong. `std::generator` fits a pull-based pipeline stage specifically well, because a stage that lazily produces one transformed item at a time, on demand, is a more natural match for a coroutine than for a hand-built producer thread pushing into a queue the next stage polls; pairing it with `std::expected` lets a parse failure travel to the next stage as a value the type system makes impossible to ignore, rather than an exception that would have to cross a thread or coroutine-resumption boundary to be caught anywhere useful. `std::execution`'s sender chain is worth watching specifically because its shape (stage, then a scheduler hop, then the next stage) is a near-literal transcription of a SEDA pipeline's structure into composable code, which is a stronger fit than the general-purpose task-scheduling use shown in earlier chapters; it remains unimplemented in any mainstream standard library as of this writing.

## What we learned

- SEDA and pipeline architectures decompose a request into stages, each with its own pool and bounded queue, trading a per-stage hand-off cost for independent sizing, admission control, and observability per stage; fan-out/fan-in extends the same idea to parallel replicas of one stage, joined with a latch.
- Sharding partitions state by key with a single writer per shard, generalizing the single-writer principle from the Disruptor pattern to an entire system's state; the hard case is any operation spanning more than one shard, which either needs explicit coordination or a key space redesigned to avoid it.
- A reactor dispatches on readiness and a proactor dispatches on completion; half-sync/half-async keeps application code as ordinary blocking logic on a synchronous layer while an async reactor or proactor layer handles I/O, connected by a queueing boundary that needs the same explicit context propagation as any other thread hand-off.
- Choosing an architecture follows from workload shape: sharding for cleanly partitionable state, pipelines for phases with different cost profiles, reactor/proactor and half-sync/half-async for I/O-bound work with simple per-request logic, fan-out/fan-in for one expensive computation split into parallel pieces; real systems compose these rather than picking exactly one.
- A tighter latency budget favors fewer hand-offs on the critical path (sharded single writers, a tight reactor loop); a throughput-oriented system can afford a deeper pipeline, because its latency budget has more room to absorb the isolation a pipeline buys.

[Concurrency in Containers]({{ '/docs/32-concurrency-in-containers/' | relative_url }}) picks up directly from the per-stage, per-shard sizing questions this chapter deferred, and applies the cgroup-aware discipline from earlier chapters to a whole architecture running under a single resource quota.
