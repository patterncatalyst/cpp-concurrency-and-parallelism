---
title: "Thread Pools and Work Scheduling"
order: 15
layout: tutorial
sectionid: docs
part: parallelism-and-throughput
description: "Sizing a thread pool correctly, work-stealing task queues, bounded queues and back-pressure, and the cgroup-aware sizing a pool needs to behave inside a container."
duration: "16 min"
---

<!-- PROVENANCE: NEW (adapted from cpp-statelessness/_docs/05-threading.md, linux-systems-programming/_docs/41-capstone-fleet.md) | anchor books: Son, Williams -->

## What we'll cover

- Establish a sizing rule for a thread pool based on workload type (CPU-bound vs I/O-bound) rather than a fixed guess.
- Compare a single shared task queue against per-thread queues and the contention each implies.
- Cover work-stealing deques as the load-balancing strategy that gets per-thread queues' low contention without their load imbalance.
- Cover bounded queues and back-pressure as the alternative to letting a pool's backlog grow without limit.
- Make the pool size cgroup-aware so it reflects the container's CPU quota rather than the host's core count.

A thread pool answers a question every service with more work than cores eventually asks: how many threads, doing what, pulled from where. Get the count wrong and the pool leaves cores idle or fights itself for them. Get the queue design wrong and every submission serializes behind one lock, no matter how many workers stand ready to help. A pool is a handful of threads and a queue, but its failure modes are easy to build and hard to spot in a profiler — they show up as throughput plateauing below the hardware's actual capacity, not as an obvious bug.

## Sizing a Thread Pool

[The Machine Underneath]({{ '/docs/02-the-machine-underneath/' | relative_url }}) established that `std::thread::hardware_concurrency()` reports logical processors, not independent execution units, and that a context switch's real cost is the cache it evicts, not the register save. Both facts drive pool sizing directly.

For CPU-bound work — computation with no blocking syscalls, no I/O waits, no sleeping — the right pool size is the number of cores the workload may actually use concurrently, full stop. One thread per physical core keeps each thread resident until it finishes its slice; a second thread per core, chasing the logical count SMT reports, buys nothing but two threads splitting one core's L1 and execution ports. Adding threads past this point doesn't parallelize further — there's no more hardware to run on — it just adds scheduling overhead and cache contention between threads now taking turns on cores they're also fighting each other for.

For I/O-bound work — a thread blocked most of the time on a socket read, a disk write, or a downstream RPC — the calculation differs, because a blocked thread isn't competing for a core; it's off the run queue, and another thread can use the core it vacated. A workable estimate, borrowed from queuing theory's utilization law, is `threads ≈ cores × (1 + wait_time / compute_time)`: a handler spending 9 ms waiting on a database per 1 ms of CPU work can usefully run ten threads per core, since nine of the ten are blocked at any moment and only one is actually running. The formula is an estimate, not a guarantee — real wait times vary under load, and the downstream service has its own capacity limit a bigger pool here can't fix — but it replaces a guess with a number derived from the workload's actual shape.

Mixed workloads — some blocking I/O, some real computation, in the same handler — are usually better split into two pools sized by their own rules than compromised into one size for both: a pool sized for I/O-bound waiting oversubscribes the CPU-bound fraction, and a pool sized for CPU-bound work leaves I/O-bound tasks queued behind blocked threads. Where the toolchain allows it, replacing blocking I/O with an async equivalent on the CPU-sized pool removes the I/O pool as a concept — nothing blocks, so nothing needs the extra threads blocking required.

## Task Queues: One Queue or Many

The simplest pool design has one shared queue: workers pop from it in a loop, a mutex (or a lock-free MPMC structure) serializes access, and a condition variable or semaphore wakes a worker when work arrives. This is easy to reason about and, for a pool with modest submission rates, entirely adequate — the queue operations themselves are nanoseconds, and with four or eight workers the lock is rarely contended long enough to matter.

It stops being adequate as the submission rate or worker count grows. Every push and pop takes the same lock, so the queue becomes a single serialization point every worker and producer funnels through regardless of idle capacity elsewhere in the pool. Past a certain throughput, threads spend more time waiting on the queue's lock than doing the work it hands them — aggregate throughput caps out below what the cores could sustain, at a number set by lock overhead, not work capacity.

The alternative is a queue per worker: each thread owns its queue, pushes work locally, and pops from only its own queue in the common case. Uncontended access to an unshared queue costs essentially nothing. The problem it creates is load imbalance — nothing guarantees work arrives evenly, so one thread's queue backs up while another sits idle with nothing to steal, because a pure per-thread design has no way to reach into an idle neighbor's queue.

## Work-Stealing Deques

Work-stealing resolves exactly that imbalance, and it's the standard production answer to the single-queue bottleneck. Each worker owns a double-ended queue (a deque) of its own tasks. The owner pushes and pops from one end — call it the bottom — treating its own queue as a LIFO stack; the most recently pushed task is usually also the most cache-hot one (its data is still warm from having just generated it), so popping it back off immediately is both the cheapest and the most cache-friendly choice. When a worker's own deque runs dry, it picks another worker at random (or round-robin) and steals from the opposite end — the top — taking the oldest task in that queue rather than the newest.

Stealing from the far end rather than the owner's end is the design's central trick: a thief and the deque's owner only contend when the deque holds exactly one item, since every other access touches opposite ends of the structure. The common case — an owner popping its own freshly pushed work, a thief occasionally lifting the oldest item off a busy neighbor — needs no lock at all with a correctly implemented lock-free deque (the Chase-Lev algorithm is the reference design most implementations trace back to), and even a naive mutex-per-deque version keeps contention rare, because steals happen only when a worker is starved, not on every dispatch the way a single shared queue requires.

<!-- DIAGRAM SPEC: Four worker boxes (blue #4a73b8) in a row labeled Worker 0..3, each with a horizontal deque drawn beneath it as a row of small task boxes. A label "bottom (owner push/pop, LIFO)" points to the left end of each deque and a label "top (thief steal, FIFO)" points to the right end. Worker 1's deque is drawn empty (cream #fdfbf7, dashed outline). A curved orange #a06030 arrow runs from Worker 1 to the top (right) end of Worker 3's deque, labeled "steal: lift oldest task". A separate green #5a8870 arrow loops from Worker 0 back to the bottom (left) end of its own deque, labeled "local pop: no lock needed". Caption note beneath: "owner and thief touch opposite ends; they only collide when one task remains." -->
{% include excalidraw.html name="15-work-stealing-deque" caption="Figure 15.1 — a work-stealing pool: each worker pops its own freshly pushed work from the bottom of its deque, and an idle worker steals the oldest task from the top of a busy neighbor's deque" %}

Work-stealing assumes tasks are roughly independent and that stealing one doesn't break an assumption the submitting code made about which thread would run it — code relying on thread affinity for correctness, not just performance, has to opt out of stealing, typically through a side channel to a specific worker's queue rather than the shared pool API. It also assumes task granularity is coarse enough that the occasional steal's overhead doesn't dominate; a pool handed millions of sub-microsecond tasks spends more time deciding who runs what than running anything, and batching work into coarser units is the usual fix.

## Bounded Queues and Back-Pressure

Every queue design so far has assumed producers submit no faster than workers can drain. When that assumption breaks — a burst of requests, a downstream slowdown that stalls every worker at once — an unbounded queue just keeps accepting, and the backlog grows without any signal to the producer that anything is wrong. Memory grows with it, and because the oldest queued item is now served last relative to when it arrived, every queued request's latency grows too; a service that was fast under normal load degrades silently into one where every response is late by the length of a backlog nobody can see from outside the process.

A bounded queue converts that silent degradation into an explicit decision at submission. Give the queue a capacity, enforced with a counting semaphore or an atomic size check, and a producer past that capacity has three honest options: block until a slot frees, propagating back-pressure, correct when the producer can usefully slow down; reject immediately, correct when the producer has a cheaper fallback (stale data, a retry-able error) than waiting; or drop the oldest or lowest-priority item to make room, correct only when recency beats completeness, as for a market-data feed where a stale tick is worse than a missing one.

What a bounded queue should never do silently is keep growing. A queue depth that an operator can read, paired with a capacity that an operator chose deliberately, turns "the service is falling over" from a postmortem discovery into a metric anyone could have alerted on before the backlog mattered. Capacity sizing itself follows from the same wait-time reasoning as pool sizing: a queue sized to absorb the largest burst the system is expected to tolerate without the producer blocking, and no larger, because any additional capacity is additional worst-case latency waiting to happen to whichever request lands at the back of a full queue.

## cgroup-Aware Sizing in Containers

Every sizing rule above assumes the pool knows how many cores it actually has, and inside a container that number is not what it looks like. `std::thread::hardware_concurrency()` queries the host's CPU topology through `sched_getaffinity` or `/proc/cpuinfo`, both of which report the physical machine's core count regardless of any CPU limit the container runtime has imposed — a pool sized off that call on a sixty-four-core host, running inside a container capped at two cores, builds sixty-four threads' worth of pool for two cores' worth of hardware.

The correct number lives in the cgroup filesystem. Under cgroup v2, `/sys/fs/cgroup/cpu.max` holds two numbers — a quota and a period, in microseconds — whose ratio, rounded up, is the CPU-equivalents the kernel will actually schedule this cgroup onto per period; `200000` over `100000` is two cores' worth, regardless of how many logical cores the host reports. A quota of `max` means no limit, and the pool should fall back to `hardware_concurrency()` rather than treat an absent quota as zero. The older cgroup v1 hierarchy splits the same information across `cpu.cfs_quota_us` and `cpu.cfs_period_us`, where a negative quota again means unlimited. Reading both forms at startup, preferring v2 when present, derives a number tracking the container's actual budget, not the host's.

That number belongs in the sizing formulas from the first section, substituted directly for "cores" — a CPU-bound pool under a two-core quota should build two workers, not the host's sixty-four, and an I/O-bound pool's wait-time multiplier still applies on top of that smaller base. [Concurrency in Containers]({{ '/docs/32-concurrency-in-containers/' | relative_url }}) takes this further: cpuset constraints, orchestrator-supplied limit environment variables, and pinning under an orchestrator's CPU manager. This chapter's narrower claim is that pool construction needs to read the cgroup before it reads `hardware_concurrency()`, not instead of it.

A runnable companion at `examples/concurrency/15-thread-pool/` makes the two queue designs and the sizing claim observable rather than asserted.

<!-- EXAMPLE SPEC: a single-shared-queue pool and a work-stealing-deque pool, both running the same CPU-bound task mix, reporting aggregate throughput and per-task queue-wait latency as submitter and worker counts scale up; plus a cgroup probe that reads cpu.max (falling back to cpu.cfs_quota_us/cpu.cfs_period_us) and prints the derived CPU-equivalent count against hardware_concurrency(); run via Docker (lgtm-docker-stack) under a --cpus limit, since cgroup CPU quota behavior is fully reproducible in a container without needing real NUMA topology or core isolation; verified by a Lua verify.lua asserting the work-stealing pool's throughput stays within a small margin of the single-queue pool at low worker counts but exceeds it once worker count passes roughly eight, and that the cgroup-derived count matches the configured --cpus value rather than the host's hardware_concurrency() -->


## Running in a container

The sizing mistake above has a visible signature once a pool runs under a quota rather than just being theoretically oversized: throughput plateaus at the quota, with added overhead the oversized pool itself introduces. Run a CPU-bound benchmark at pool sizes 1, 2, 4, and 8 under a `--cpus=2` limit, and the throughput curve rises through 2 and then flattens, or dips, at 4 and 8 — the CFS bandwidth controller enforces the quota as a hard ceiling on CPU-time per period, so extra threads don't get extra cycles, they get extra time-slicing among themselves for the same fixed budget, paying for every added context switch out of a quota already fully spoken for. Tail latency is the more damaging symptom: an oversubscribed pool periodically burns its whole period's quota early and is descheduled until the period rolls over, and whichever request was in flight on a throttled thread stalls for however much of the period remains — frequently tens of milliseconds, against a request budget meant to be single-digit milliseconds end to end.

The fix is the cgroup-aware sizing this chapter just built: read `cpu.max` (or the v1 equivalents) once at startup, compute the CPU-equivalent count, and size every pool the process owns from that number — not just the application pool, but any library that spins up its own threads by default, since a correctly sized application pool sharing a quota with an oversized library pool is still oversubscribed in aggregate. The container runtime never adjusts `hardware_concurrency()` to match the quota it enforces; the pool has to do that adjustment itself, every time.

## Standards: C++20 / C++23 / C++26

C++20 gives thread pools a cleaner worker and a cleaner shutdown path in `std::jthread` and `std::stop_token`. A hand-rolled pool before C++20 needed an explicit atomic shutdown flag that every worker's loop checked, plus careful ordering between setting that flag and calling `join()` on each `std::thread`. `std::jthread` requests cooperative stop and joins automatically in its destructor, and a worker loop can thread a `std::stop_token` through its wait predicate so a shutdown request wakes a thread that's blocked waiting for the next task rather than leaving it to notice the flag only after another task arrives.

C++23 adds `std::move_only_function`, which matters to a task queue's element type specifically. `std::function` requires its target to be copy-constructible, which forces a task that captures a `std::unique_ptr` or a `std::promise` into either an unnecessary `shared_ptr` wrapper or a heap-allocated workaround just to satisfy a copyability requirement the pool never actually needs — nothing in a typical pool ever copies a queued task, it moves it from the queue into the worker that's about to run it. `std::move_only_function` drops the copyability requirement entirely, so a task holding move-only captured state stores directly, without the extra indirection.

C++26 is where task scheduling gains a standard vocabulary, via the senders/receivers model from P2300 (`std::execution`), accepted into the C++26 working draft. It standardizes schedulers, senders, and execution contexts as composable building blocks — a `std::execution::thread_pool`-style context exposes a scheduler senders run on, and algorithms compose across schedulers without each library inventing its own executor concept. No mainstream standard library ships a complete implementation as of this writing; the reference most production experimentation runs against is NVIDIA's open-source `stdexec`, tracking the accepted proposal ahead of vendor support. Treat the code below as the target shape, not something to build a production pool on today.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// A worker loop that wakes on either new work or a cooperative stop
// request, and a pool whose destructor joins every worker automatically.
class ThreadPool {
public:
    explicit ThreadPool(unsigned n) {
        for (unsigned i = 0; i < n; ++i) {
            workers_.emplace_back([this](std::stop_token st) { run(st); });
        }
    }
    // ~ThreadPool() is implicit: each jthread requests_stop() and joins.

    void submit(std::function<void()> task) {
        {
            std::lock_guard lk(mtx_);
            queue_.push_back(std::move(task));
        }
        cv_.notify_one();
    }

private:
    void run(std::stop_token st) {
        while (true) {
            std::unique_lock lk(mtx_);
            cv_.wait(lk, st, [&] { return !queue_.empty(); });
            if (st.stop_requested() && queue_.empty()) return;
            auto task = std::move(queue_.front());
            queue_.pop_front();
            lk.unlock();
            task();
        }
    }

    std::mutex mtx_;
    std::condition_variable_any cv_;
    std::deque<std::function<void()>> queue_;
    std::vector<std::jthread> workers_;
};
```

```cpp
// C++23
// move_only_function drops std::function's copyability requirement, so a
// task that owns a unique_ptr or a promise stores without an extra
// shared_ptr wrapper just to satisfy copy construction nobody needs.
class Pool23 {
public:
    void submit(std::move_only_function<void()> task) {
        std::lock_guard lk(mtx_);
        queue_.push_back(std::move(task));  // move, never a copy, required
    }

private:
    std::mutex mtx_;
    std::deque<std::move_only_function<void()>> queue_;
};

void example(Pool23& pool, std::unique_ptr<Result> owned) {
    pool.submit([p = std::move(owned)]() mutable {
        process(*p);
    });  // compiles: the lambda is move-only, and so is the queue element
}
```

```cpp
// C++26 (proposed; targets the accepted P2300 std::execution model,
// not yet shipping in a mainstream standard library — shown against the
// stdexec reference implementation's API shape)
#include <execution>
namespace ex = std::execution;

void run_on_pool(ex::thread_pool& pool, std::vector<int>& data) {
    auto sched = pool.get_scheduler();
    auto work = ex::schedule(sched)
              | ex::then([&] { std::ranges::sort(data); })
              | ex::then([&] { return std::accumulate(data.begin(), data.end(), 0); });
    int total = ex::sync_wait(std::move(work)).value();
}
```

## What we learned

A pool's size follows from the workload, not a reflex call to `hardware_concurrency()`: cores for CPU-bound work, cores scaled by a wait-to-compute ratio for I/O-bound work, and separate pools when a workload is genuinely both. A single shared queue is fine at modest scale and becomes the pool's throughput ceiling at larger scale, because every worker and producer serializes through the same lock. Work-stealing deques fix that by giving each worker a low-contention queue of its own while still letting an idle worker pull from a busy one, contending only at the rare moment a deque holds exactly one item. A queue needs a bound and an explicit back-pressure policy — block, reject, or drop — because an unbounded queue doesn't fail loudly, it just makes every queued request later than the last. And inside a container, every sizing decision has to be rederived from the cgroup's actual CPU quota, because `hardware_concurrency()` reports the host's hardware, not the slice the container was actually given.
