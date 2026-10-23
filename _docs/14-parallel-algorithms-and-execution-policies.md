---
title: "Parallel Algorithms and Execution Policies"
order: 14
layout: tutorial
sectionid: docs
part: parallelism-and-throughput
description: "The standard execution policies, the parallel STL algorithms built on them, C++26 additions, and when parallel execution actually pays off."
duration: "15 min"
---

<!-- PROVENANCE: NEW | anchor books: Brandt, Lim -->

## Learning objectives

By the end of this chapter you can:

- Choose among `seq`, `par`, and `par_unseq` for a given callable, based on what each policy permits and forbids.
- Identify which parallel STL algorithms require an associative, usually commutative, combining operation and why.
- Recognize vectorization-unsafe operations (locking, blocking, non-lock-free allocation) that are safe under `par` but not under `par_unseq`.
- Assess whether C++26's proposed `std::execution` and explicit data-parallel facilities are ready to build against today.
- Apply a cost model (`N × w` against dispatch overhead `c`) to decide whether parallelizing a loop will actually pay off.

## Why this matters

Parallel STL turns a performance change into what looks like a one-argument edit: add `std::execution::par` to a call site and the algorithm is now permitted to run across threads. That ease is also the risk. The same small change can introduce a data race or a self-deadlock if the callable isn't ready for the guarantee it just relaxed, and the failure often won't surface until the algorithm runs on different hardware or a different data size than whatever a developer tested with.

Knowing when to reach for a parallel algorithm matters as much as knowing how. A loop with cheap, memory-bound work can get slower under `par`, not faster, once dispatch overhead is counted against it. The execution-policy vocabulary this chapter builds is also the foundation the next three chapters, on thread pools, NUMA, and SIMD, build on directly.

## What we'll cover

- Cover the three C++17 execution policies (`seq`, `par`, and `par_unseq`), the guarantees each one relaxes, and what each one forbids inside the algorithm's callable.
- Survey a representative set of parallel STL algorithms and how their requirements on the callable differ from the sequential algorithms they're named after.
- Preview the C++26 additions to this area, and why they're worth treating as experimental rather than code to ship today.
- Build a cost model for when converting a loop to a parallel algorithm actually pays for itself, versus when the dispatch overhead swallows any gain.

[Chapter 1]({{ '/docs/01-concurrency-vs-parallelism/' | relative_url }}) put "parallel, not concurrent" in its own cell of the grid: one logical operation, fanned across cores by the runtime, with almost no task structure visible in the calling code. The parallel STL is where that cell lives in practice. Every algorithm in this chapter already exists as a sequential one (`std::sort`, `std::transform`, `std::reduce`'s ancestor `std::accumulate`), and the whole interface is a first argument: pass an execution policy, and the algorithm is permitted to use more than one thread, more than one SIMD lane, or both. The policies themselves shipped in C++17, not C++20; this chapter covers refinements since, but the core mechanism predates the C++20/23/26 window this book tracks.

## Execution Policies: seq, par, and par_unseq

`std::execution::seq` is the baseline: the algorithm still runs, element by element, with no concurrency and no vectorization guarantee beyond what the compiler would do anyway for an ordinary loop. Passing it changes nothing about correctness requirements versus calling the algorithm with no policy at all; it exists mostly so that a policy-parameterized call site can dial parallelism down to zero without a separate code path.

`std::execution::par` is where the guarantees actually relax. The standard library is permitted to invoke the algorithm's callable from multiple threads, for different elements, with no promise about which thread runs which element or in what order. What that permission costs the caller is a data-race obligation: the callable must be safe to invoke concurrently with itself, which means any shared mutable state it touches needs the same discipline (a mutex, an atomic, or none at all because there's nothing shared) that [Chapter 6]({{ '/docs/06-mutual-exclusion-and-locking/' | relative_url }}) and [Chapter 8]({{ '/docs/08-atomics-and-the-memory-model/' | relative_url }}) already cover for any multithreaded code. A `std::mutex` is perfectly legal inside a `par` callable. Blocking is not forbidden; only data races are.

```cpp
std::vector<int> data(1'000'000);
std::atomic<long> sum{0};
std::for_each(std::execution::par, data.begin(), data.end(),
              [&sum](int x) { sum.fetch_add(x, std::memory_order_relaxed); });
```

`std::execution::par_unseq` adds vectorization to parallelization, and the price for that is sharper than most engineers expect on first reading the standard. Under `par_unseq`, the library may interleave the *execution of different iterations within a single thread*: not just schedule them on different threads, but run fragments of several iterations' worth of instructions in an order that assumes no iteration ever blocks or waits on another, because a vector unit executing several logical iterations as one SIMD operation cannot context-switch between them the way the OS scheduler switches between threads. That assumption makes a specific, easy-to-miss category of code actively unsafe rather than merely slow: acquiring a lock inside a `par_unseq` callable, allocating memory (which may itself take a lock inside the allocator), or calling anything that can block relative to the forward progress of another "iteration," can deadlock, not because of a race, but because the two iterations that need to rendezvous may, under the hood, be the same hardware thread, and one of them is never going to get a turn to release what the other is waiting on.

```cpp
// WRONG under par_unseq: a lock acquired inside a callable the standard may
// vectorize is not merely slow, it can deadlock against itself.
std::mutex m;
std::for_each(std::execution::par_unseq, v.begin(), v.end(), [&](int& x) {
    std::lock_guard<std::mutex> lock(m);   // forbidden: may block a SIMD lane
    x = transform(x);
});
```

The standard's own phrasing for this is that `par_unseq`'s callable must not perform any "vectorization-unsafe" operation: a category that includes acquiring a lock, allocating or deallocating memory through a non-lock-free allocator, and invoking anything else that could legally block the calling thread. `par` relaxes the *ordering* guarantee and asks for thread-safety; `par_unseq` relaxes ordering further and additionally forbids blocking, because it reserves the right to run iterations in a way where blocking has no well-defined meaning at all.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, three stacked rows, each a horizontal strip labeled with a policy name. Row 1 "seq" in blue #4a73b8: five numbered boxes in strict left-to-right order, one arrow per step, annotated "no concurrency, no vectorization guarantee -- the baseline". Row 2 "par" in green #5a8870: the same five boxes distributed across three thread lanes in no fixed order, annotated "may run on multiple threads -- callable must be safe to invoke concurrently; locks and allocation are fine". Row 3 "par_unseq" in orange #a06030: the same five boxes shown partially overlapping inside two SIMD-lane bars, with a red #c0392b "X" over a small lock icon inside one bar, annotated "may interleave iterations within ONE thread -- locking or blocking inside the callable can deadlock against itself". -->
{% include excalidraw.html name="14-execution-policy-rules" caption="Figure 14.1: what each execution policy permits the library to do with your callable, and what it forbids the callable from doing in return" %}

## The Parallel STL

Most parallel algorithms are a direct policy-parameterized overload of a sequential one, with the same signature plus a leading policy argument: `std::sort`, `std::for_each`, `std::transform`, `std::find`, `std::all_of`, and dozens more all follow this shape, and converting a call site is frequently nothing more than inserting `std::execution::par` as the first argument.

```cpp
std::sort(std::execution::par, v.begin(), v.end());
std::transform(std::execution::par_unseq, in.begin(), in.end(), out.begin(),
               [](double x) { return x * x; });
```

A smaller set of algorithms exist specifically *because* a policy was added, rather than being a policy-parameterized version of something pre-existing. `std::reduce` is the sharpest example: it looks like `std::accumulate`, folding a binary operation over a range into one result, but it carries a requirement `accumulate` never had, because `accumulate` is defined to apply its operation strictly left to right and `reduce` explicitly is not. A parallel reduction needs the freedom to combine partial sums from different threads in whatever order they finish, so the standard requires `reduce`'s binary operation to be both associative and commutative: true for ordinary integer or exact-arithmetic addition, not strictly true for floating-point addition, where reordering changes the rounding error accumulated along the way. Using `std::reduce` on floating-point data is not undefined behavior, but it trades a specific, reproducible rounding result for a different, also-valid but not necessarily identical one; worth knowing before a test compares a `reduce` result against an `accumulate` baseline and expects bit-for-bit agreement.

`std::transform_reduce` composes the two ideas (map then fold) in one pass, specifically so an implementation isn't forced to materialize the intermediate transformed range before reducing it, the same fusion motivation range adaptors bring to sequential code. `std::exclusive_scan` and `std::inclusive_scan` extend the same associative-and-commutative requirement to prefix sums, parallelizable with the classic two-pass or Blelloch-style scan algorithms precisely because the combining operation doesn't care what order partial results arrive in. The pattern across all of them: a parallel algorithm that's merely the sequential one with threads under the hood needs nothing extra from its caller beyond the thread-safety `par`/`par_unseq` already demand; a parallel algorithm whose *result* depends on evaluation order needs a mathematically weaker operation (associative, usually commutative too) before parallelizing it is even meaningful, not just before it's fast.

## C++26 Additions

C++26's standard library work most relevant to this chapter runs in two directions, and both are worth labeling by their actual maturity rather than by how settled they sound in a committee paper. The first is `std::execution`'s senders and receivers (P2300), already previewed in [Chapter 11]({{ '/docs/11-coroutines-in-depth/' | relative_url }}) and [Chapter 12]({{ '/docs/12-async-runtimes-and-event-loops/' | relative_url }}) for async composition. The same model, extended toward bulk and parallel work, could in principle let a parallel algorithm accept a scheduler describing exactly which thread pool or GPU should run it, rather than the coarse seq/par/par_unseq policy enum this chapter has covered so far. The second is movement toward standardizing explicit data-parallel types (`std::simd`-shaped facilities), giving code an explicit, portable vocabulary for the SIMD lanes `par_unseq` only ever hints at implicitly through a permission rather than a type.

```cpp
// C++26 (proposed; shape illustrative, no shipping compiler support) --
// a scheduler-aware bulk operation expressed through std::execution rather
// than through an execution-policy enum value.
auto work = std::execution::bulk(std::execution::schedule(gpu_scheduler),
                                  data.size(),
                                  [&](std::size_t i) { data[i] = transform(data[i]); });
std::execution::sync_wait(std::move(work));
```

Both directions are experimental as this is written: no mainstream compiler ships a conforming `std::execution` implementation, and explicit data-parallel types remain in active standardization rather than settled, shipping library surface. Treat the C++26 column throughout this chapter as a preview of where the vocabulary is heading, not as an API available to build against today; the seq/par/par_unseq model from C++17, refined by `unseq` in C++20, is what every mainstream standard library actually ships.

## When Parallelism Pays Off

A parallel algorithm has fixed costs a sequential loop never pays: dispatching work across threads, chunking the range into pieces sized for each worker, and, on implementations like libstdc++'s, where the parallel backend is layered on Intel's oneTBB rather than built from scratch, potentially linking an entirely separate library just to get `par` to do anything but silently execute sequentially. That last point is worth checking explicitly on whatever toolchain ships your binary: a standard library that accepts `std::execution::par` without a conforming parallel backend linked in is permitted to execute the algorithm as if `seq` had been requested, which compiles, runs, and produces a correct but non-parallel result with no diagnostic that anything was skipped.

Past that fixed cost, the question of whether `par`/`par_unseq` is worth reaching for reduces to a crossover: let `N` be the number of elements, `w` the work done per element inside the callable, and `c` the fixed overhead of dispatching across threads (or lanes) at all. Parallelizing pays off once `N × w` comfortably exceeds `c`; it doesn't once the per-element work is trivial enough that `c` dominates regardless of how large `N` grows. A `std::transform` whose callable is a single floating-point multiply is memory-bandwidth-bound long before it's compute-bound: every core is waiting on the same memory bus, and adding more of them to a bandwidth-saturated workload buys nothing, sometimes even a regression once `c` is added back in for no corresponding gain. The same algorithm with a callable doing real per-element work (a hash, a lookup, a small loop of its own) amortizes `c` over parallelizable compute, and that's the case where `par`/`par_unseq` earns the overhead rather than merely moving it around.

The practical rule that falls out: measure before converting a hot loop into a parallel algorithm call, the same discipline [Chapter 18]({{ '/docs/18-benchmarking-without-deception/' | relative_url }}) applies everywhere else in this book, and expect the win to show up on large `N` with nontrivial `w`, not on the small, tight loops a profiler is most likely to flag as hot in the first place, which are frequently hot precisely because they're cheap enough to run a huge number of times, not because any single call does enough work to amortize a thread dispatch.

## Running in a container

Core counts and speedup numbers from a parallel algorithm are only as meaningful as the core topology they ran on, and that is the one measurement a container routinely lies about by omission rather than by malice: `std::thread::hardware_concurrency()` (the same call [Chapter 1]({{ '/docs/01-concurrency-vs-parallelism/' | relative_url }}) flagged as reporting a permission, not an outcome) reads host topology and knows nothing about a `cpu.max` quota, so a parallel sort benchmarked inside an unconstrained container and inside one throttled to two cores can request the same thread count from the standard library's backend while one of them has nowhere real to run those threads. A speedup number collected without pinning the container's CPU allotment and recording it alongside the result is not reproducible evidence of anything; it's evidence of whatever the scheduler happened to grant that run.

<!-- VM-LAB NOTE: this chapter's example runs in the KVM lab via lgtm-systems-programming rather than a laptop container, because core counts and measured speedup are only meaningful against pinned, real cores -- a container sharing a host's cores with other tenants, or a laptop under thermal throttling, cannot produce a crossover measurement worth trusting. Never mutate the lab host's NUMA layout or CPU governor; read them, don't change them, and tear the VM down after the run via the lab's standard lifecycle scripts. -->

The runnable version of this chapter's cost model lives at `examples/concurrency/14-par-sort-reduce/`.

<!-- EXAMPLE SPEC: sorts and reduces the same data across a sweep of N (element count) and w (synthetic per-element work) under std::execution::seq and std::execution::par, pinned to a fixed core count via taskset inside the KVM lab, reporting wall time and distinct CPUs touched (sched_getcpu() union, per Chapter 1's method) rather than a bare speedup ratio. KVM-lab via lgtm-systems-programming; never mutates host NUMA/governor settings. Verified by a Lua verify.lua asserting distinct_cpus for the par case exceeds 1 and exceeds the seq case's distinct_cpus, and that the par/seq wall-time ratio improves (decreases) as w increases across the sweep for fixed N -- the sign of the crossover, not a specific ratio, since exact speedup numbers are hardware- and scheduler-dependent and are reported as illustrative only, never asserted as this book's own benchmark. -->

## Standards: C++20 / C++23 / C++26

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20 -- seq, par, and par_unseq already existed from C++17. C++20 adds a
// fourth policy, unseq: vectorization permitted, parallelization (threads)
// NOT permitted. Useful for a loop that's safe to auto-vectorize but whose
// callable is unsafe to run concurrently across threads for some unrelated
// reason (e.g. touching non-thread-safe global state that a single thread
// running vectorized iterations never actually contends).
std::for_each(std::execution::unseq, v.begin(), v.end(),
              [](double& x) { x = std::sqrt(x); });
```

```cpp
// C++23 -- identical execution-policy surface; no new policy and no change
// to seq/par/par_unseq/unseq's requirements shipped in this standard. The
// parallel-algorithms story in C++23 is unchanged from C++20.
std::for_each(std::execution::unseq, v.begin(), v.end(),
              [](double& x) { x = std::sqrt(x); });
```

```cpp
// C++26 (proposed; no shipping compiler support) -- std::execution senders
// and schedulers express "run this bulk operation on this specific
// resource" as a composable value, a strictly richer vocabulary than
// choosing from a fixed four-member policy enum.
auto work = std::execution::bulk(std::execution::schedule(pool_scheduler),
                                  v.size(),
                                  [&](std::size_t i) { v[i] = std::sqrt(v[i]); });
std::execution::sync_wait(std::move(work));
```

The headline fact for this chapter: `seq`, `par`, and `par_unseq` are C++17, not C++20; nothing in the C++20/23/26 window this book otherwise tracks introduced them. C++20's sole addition to the policy set is `unseq`; C++23 changes nothing about any of the four; C++26's proposed contribution is a different vocabulary layered alongside the existing policies, not a fifth policy value, and it remains experimental until a shipping compiler says otherwise.

## What we learned

- `seq`, `par`, and `par_unseq` are C++17 facilities, refined rather than introduced across C++20/23/26; attributing them to C++17 is the accurate baseline for everything else in this chapter.
- `par` permits concurrent execution and demands a thread-safe callable; `par_unseq` additionally permits interleaving iterations within one thread for vectorization, which makes locking or any other blocking operation inside the callable a potential self-deadlock, not merely a slowdown.
- Most parallel algorithms are policy-parameterized versions of a sequential one with an identical contract; a smaller set (`reduce`, `transform_reduce`, the scans) exist because their result depends on evaluation order, and require an associative (usually commutative) combining operation before parallelizing them is even meaningful.
- C++26's proposed `std::execution` bulk/scheduler model and explicit data-parallel types extend this area but remain experimental, with no shipping compiler support as of this writing.
- Parallelizing pays off when total work (`N × w`) comfortably exceeds the fixed dispatch overhead; a trivial per-element callable on a memory-bandwidth-bound loop can lose to the sequential version once that overhead is added back in.
- Speedup and core-count numbers are only meaningful against pinned, real cores: a container's `hardware_concurrency()` doesn't see its own CPU quota, and this chapter's own example runs in the KVM lab for exactly that reason, never on a shared or throttled host.

Next, [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}) turns from "parallelize this one algorithm call" to the longer-lived question underneath it: sizing and running a pool of workers that many independent pieces of work share over a program's whole lifetime.
