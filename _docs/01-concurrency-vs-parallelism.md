---
title: "Concurrency vs Parallelism"
order: 1
layout: tutorial
sectionid: docs
part: foundations
description: "The two independent axes of concurrency and parallelism, the four execution models that result, and how to measure them precisely."
duration: "13 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/49-concurrency-vs-parallelism.md | anchor books: Grokking Concurrency, Tanenbaum -->

## What we'll cover

- Separate concurrency (a property of how a program is structured) from parallelism (a property of how it executes on hardware), and show why the two are independent axes rather than synonyms.
- Walk the four execution models that result from crossing those axes, each with a short C++ snippet.
- Measure execution models with counts — tasks in flight, distinct CPUs touched — instead of wall-clock duration, which the scheduler and the optimizer can both falsify.
- Keep the comparison C++-only: the language offers several answers to "how do I structure and run this work," and choosing among them is this book's subject.

## The Two Axes: Structure vs Execution

Concurrency and parallelism get used as if they were one idea, and the mix-up costs real engineering time. A program is **concurrent** when it is structured to have more than one unit of work outstanding at once — several requests being handled, several tasks queued, several state machines advancing independently. A program is **parallel** when the machine actually executes more than one of those units at the same time, on more than one core. The first is a claim about your source code. The second is a claim about the hardware underneath it at a given moment. Nothing requires them to move together.

Sixteen tasks queued on a single-core machine are fully concurrent and never parallel — they take turns, no matter how cleverly they're scheduled. A single `std::for_each` call with an execution policy can saturate every core on the box while the calling code reads as one sequential statement with almost no concurrent structure in it at all. Because the axes are independent, there are four cells, not two, and all four are real:

| | not parallel | parallel |
| --- | --- | --- |
| **not concurrent** | sequential | runtime-parallelized single operation |
| **concurrent** | many tasks, one core | many tasks, many cores |

<!-- DIAGRAM SPEC: 2x2 grid, cream #fdfbf7 background. Horizontal axis labeled "Concurrency (structure)" with ticks "one task" / "many tasks". Vertical axis labeled "Parallelism (execution)" with ticks "one CPU" / "many CPUs". Four cells: top-left "Sequential" (blue #4a73b8 border, single box, one task on one CPU, neither axis engaged); top-right "Parallel, not concurrent" (green #5a8870, one logical operation fanned across several CPU icons by the runtime, source has no visible task structure); bottom-left "Concurrent, not parallel" (orange #a06030, several task boxes queued, arrow pinning them all to a single CPU icon); bottom-right "Concurrent and parallel" (red #c0392b, several task boxes spread across several CPU icons, some CPUs holding more than one task to show oversubscription). Small caption under the grid: "cpus_allowed is a permission; CPUs actually touched is an outcome." -->
{% include excalidraw.html name="01-execution-models" caption="Figure 1.1 — the four execution models formed by crossing structure (concurrency) and execution (parallelism)" %}

The question worth asking about any piece of code is never "is this concurrent or parallel" but "which axis am I looking at, and which one did I actually request." `std::thread::hardware_concurrency()` and `sched_getaffinity` tell you what the machine will *permit*. Only observing where threads actually ran — `sched_getcpu()` sampled while the program runs — tells you what happened. A permission is not an outcome, and conflating the two is the single most common source of concurrency bugs that are actually capacity-planning bugs in disguise.

The split matters for decisions that look unrelated to each other until you name them correctly. Sizing a thread pool is a parallelism decision — it asks how many CPUs are actually available to convert queued work into progress, and oversizing it past that number buys nothing but context-switch overhead. Deciding how many requests a connection handler can have outstanding at once is a concurrency decision — it's about how much independent state the program is willing to track, and it stays meaningful even on a single core. Lock contention lives on the concurrency axis: two threads can contend for a mutex while pinned to the same core, never running in parallel for even an instant, and the contention is just as real. Treating "we need more parallelism" and "we need more concurrency" as the same request is how a service ends up with sixteen threads fighting over four cores while the actual bottleneck was a queue depth of one.

## The Four Execution Models

Each model below runs the identical unit of work, `process(i)`; they differ only in how that work is placed on the machine.

**Sequential** — one task runs to completion before the next begins. No threads exist. This is the baseline: neither concurrent nor parallel.

```cpp
for (int i = 0; i < n; ++i) {
    process(i);
}
```

**Concurrent, not parallel** — many runnable tasks, deliberately confined to one CPU. Spawning `std::jthread` objects supplies the structure; pinning every one of them to CPU 0 removes the hardware's ability to run more than one at a time. The structure didn't change; the parallelism was taken away on purpose.

```cpp
cpu_set_t one_cpu;
CPU_ZERO(&one_cpu);
CPU_SET(0, &one_cpu);

std::vector<std::jthread> workers;
for (int i = 0; i < n; ++i) {
    workers.emplace_back([i] { process(i); });
    pthread_setaffinity_np(workers.back().native_handle(), sizeof one_cpu, &one_cpu);
}
```

**Parallel, not concurrent** — a single logical operation, fanned across cores by the runtime, with almost no task structure visible in the source. The call site reads like one statement because it is one statement; the parallelism lives entirely inside the standard library's execution policy.

```cpp
std::vector<int> data(n);
std::for_each(std::execution::par, data.begin(), data.end(),
              [](int& x) { x = process(x); });
```

**Concurrent and parallel** — more runnable tasks than cores, unpinned. Tasks both share cores and occupy many of them simultaneously; this is the ordinary shape of an oversubscribed thread pool under real load.

```cpp
std::vector<std::jthread> workers;
const unsigned n_workers = 2 * std::thread::hardware_concurrency();
for (unsigned i = 0; i < n_workers; ++i) {
    workers.emplace_back([i] { process(i); });
}
```

Nothing above required a language outside C++ to demonstrate. `std::jthread` supplies structure; `pthread_setaffinity_np` (reached through `native_handle()`) supplies or withholds hardware; `std::execution::par` supplies hardware without asking the caller to supply structure. The four cells are four different answers to "who decides, and at what granularity."

## Observables That Are Counts, Not Clocks

Timing one of these models against another is tempting and almost always misleading. Wall-clock duration is sensitive to CPU frequency scaling, to whatever else is scheduled on the box at the moment, and to what the optimizer decided to keep. A "the parallel run was faster" assertion that passes on a quiet laptop can fail on a loaded CI runner, and a benchmark that measures nothing real can still report a flattering number.

The fix is to assert on things that are reproducible in *sign* even when they are not reproducible in magnitude. Three observables do the job:

- **Distinct CPUs touched** — union every `sched_getcpu()` reading taken during the run into a bitmap and report its population count. `sched_getcpu()` is a vDSO read (no syscall, Chapter 3 covers why that's cheap), and its value is stale the instant it returns; that's fine, because nothing acts on a single reading. The union proves which CPUs were visited at least once.
- **Tasks in flight, high-water mark** — a counter incremented when a task starts and decremented when it finishes, tracked with a compare-exchange loop rather than a mutex, because a lock around the counter would itself serialize the very tasks the counter is trying to observe overlapping.
- **Interleaving, counted from a monotonic ticket sequence** — every task draws a ticket from a shared atomic counter at each sample point; a gap between a task's own consecutive tickets means some other task was scheduled in between. No timestamps, no sleeps, no assumption about the scheduler's quantum.

```cpp
void bump_max_inflight(std::atomic<int>& high_water, int now) {
    int seen = high_water.load(std::memory_order_relaxed);
    while (now > seen &&
           !high_water.compare_exchange_weak(seen, now, std::memory_order_relaxed)) {
        // compare_exchange_weak refreshes `seen` on failure; retry until this
        // thread wins the race or another thread already recorded a larger mark.
    }
}
```

`memory_order_relaxed` is sufficient for all three counters: they carry no data dependency to anything else in the program, nothing reads them to decide what to do next, and `join()` on every worker is the synchronization edge that makes the final read well-defined. These are observations about a run, not coordination between workers — the easy end of the memory-model spectrum Chapter 8 covers in full.

A runnable version of all four models, instrumented this way, lives at `examples/concurrency/01-execution-models/`.

<!-- EXAMPLE SPEC: one C++ program that runs the same `process()` workload under all four models from this chapter (sequential, concurrent-pinned, parallel-via-execution-policy, oversubscribed) and prints distinct_cpus, max_inflight, and interleaves for each instead of a duration; verified by verify.lua asserting sequential has interleaves==0 and distinct_cpus==1, concurrent-pinned has distinct_cpus==1 with max_inflight>1, and parallel/both have distinct_cpus>1; built and run via Docker through lgtm-docker-stack since the workload needs CPU affinity but not a NUMA topology -->

## Keeping the Comparison C++-Only

Most languages give you one blessed way to express concurrent structure and leave parallel execution to the runtime: goroutines in one case, `async`/`await` over a thread pool in another. The comparison across languages usually stops at "which keyword do I write." C++ refuses to pick for you. `std::thread` gives raw OS threads with manual affinity control. Parallel algorithms give data parallelism with no explicit thread code at all. Coroutines, covered from Chapter 11 onward, give cooperative concurrency that need not add any parallelism whatsoever — a single-threaded coroutine scheduler is concurrent and not parallel by construction, the same cell a thread pinned to one CPU occupies, reached by a completely different mechanism.

That multiplicity is this book's actual subject, not a complication to work around. Every later chapter is really answering one of two questions about a piece of code: what structure does it impose (concurrency), and what hardware does it ask for or forbid (parallelism). Holding those two questions apart, and having clean vocabulary for both, is what the rest of the material builds on.

It also explains why later chapters split the way they do. [Shared State and the Futex]({{ '/docs/05-shared-state-and-the-futex/' | relative_url }}) and the mutual-exclusion chapters that follow it are almost entirely about the concurrency axis — mutexes, atomics, and lock-free structures all exist to let independently structured tasks touch shared data safely, and every one of them works whether or not those tasks ever run in parallel. [Parallel Algorithms and Execution Policies]({{ '/docs/14-parallel-algorithms-and-execution-policies/' | relative_url }}) is almost entirely about the other axis — converting available hardware into completed work, independent of how that work was structured. A chapter that blurs the two tends to reach for the wrong fix: adding threads to a program that's contention-bound on the concurrency axis, or restructuring code that was already parallel enough and merely starved for cores.

## Running in a container

A container changes what "parallel" can mean without changing a line of the program. `std::thread::hardware_concurrency()` reads host CPU topology — on Linux, effectively `sysconf(_SC_NPROCESSORS_ONLN)` — and knows nothing about a cgroup's `cpu.max` quota or `cpuset.cpus` pinning. A service throttled to two CPU-seconds per second of wall time by `cpu.max = "200000 100000"` can still ask `hardware_concurrency()` and get back the host's full core count, size a thread pool for sixteen workers, and then spend most of its time context-switching those sixteen threads through two CPUs' worth of actual execution time. The code's concurrency didn't change; the parallelism it can convert that structure into shrank to a fraction of what the code assumes.

`sched_getaffinity` is the more trustworthy read where a `cpuset` is in play, because the kernel does restrict the affinity mask to the cpuset's CPUs — a thread pool sized from `CPU_COUNT` over that mask, rather than from `hardware_concurrency()`, degrades gracefully under a quota instead of oversubscribing silently. Running the four-model example from this chapter inside a container started with `--cpus=2` is the fastest way to see the gap directly: `hardware_concurrency()` still reports the host's core count, but `distinct_cpus` for the `parallel` and `both` models caps at two no matter how many workers are spawned, because the kernel has nowhere else to schedule them — the permission narrowed, and the outcome narrowed with it.

Under an orchestrator the same gap shows up one layer further out. A Kubernetes pod with a CPU Manager `static` policy and an integer CPU request gets whole cores exclusively, reflected faithfully in `sched_getaffinity`; a pod under the default `none` policy gets a share of a shared cgroup, and `sched_getaffinity` reports the node's full core set even though the pod is only entitled to a fraction of its time. The affinity mask and the cgroup quota are two different limits, enforced two different ways, and a program that reads only one of them is still flying blind on the other.

## Standards: C++20 / C++23 / C++26

The axes themselves don't change across standards, but the vocabulary for requesting a point on the grid does. C++20 gives structure a safer primitive with `std::jthread` and `std::stop_token`, so "many tasks" no longer means remembering to join every one of them by hand. C++23 adds `std::move_only_function`, which lets a task queue hold heterogeneous, move-only work items — including ones that own a `std::jthread`'s handle — without the type-erasure overhead `std::function`'s copyability requirement used to force. C++26 proposes `std::execution` (P2300), the first standard vocabulary for expressing "what work, on what execution resource" as a composable value rather than as a side effect of calling `std::thread`'s constructor or an execution policy — precisely the concurrency/parallelism split this chapter draws, lifted into the type system. No shipping compiler implements it yet; treat the C++26 tab below as proposed and experimental, not as code you can build today.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// Structure (concurrency) via jthread + stop_token; cooperative shutdown,
// automatic join on destruction, no manual thread bookkeeping.
std::jthread worker([](std::stop_token st) {
    while (!st.stop_requested()) {
        process_next();
    }
});
// worker.request_stop() is implicit at scope exit, then an implicit join.
```

```cpp
// C++23
// A heterogeneous, move-only task queue -- each entry can own a jthread's
// stop_source along with its work, something std::function's copy
// requirement made awkward.
std::vector<std::move_only_function<void()>> tasks;
tasks.emplace_back([owned = std::move(worker)]() mutable {
    owned.request_stop();
});
```

```cpp
// C++26 (proposed, no shipping compiler support as of GCC 16 / clang 22)
// std::execution senders express "what work, on what resource" as a value.
// This composes a scheduler (parallelism) with a sender (structure) instead
// of mixing both concerns into a thread or policy call.
auto work = std::execution::schedule(pool_scheduler)
          | std::execution::then([] { return process_next(); });
std::execution::sync_wait(std::move(work));
```

## What we learned

- Concurrency is a property of structure — how many tasks are outstanding. Parallelism is a property of execution — how many CPUs are occupied at once. They are independent, which is why all four combinations of them are real.
- `hardware_concurrency()` and `sched_getaffinity` report a permission; only sampling `sched_getcpu()` across a run reports an outcome. Only the second is evidence of what actually happened.
- The four execution models — sequential, concurrent-not-parallel, parallel-not-concurrent, both — can all be built from standard C++ alone: `std::jthread`, manual affinity through `native_handle()`, and `std::execution::par`.
- Measure execution models with counts whose *sign* is stable across runs — distinct CPUs touched, an in-flight high-water mark, ticket-sequence gaps — rather than durations, which the scheduler and the optimizer can both distort.
- C++ gives you several ways to express structure and several ways to request hardware, rather than one blessed answer for each; this book's job is choosing well among them, not reducing them to one.
- A container's cgroup quota or cpuset narrows the parallelism axis without touching the program's concurrency structure, and `hardware_concurrency()` won't tell you it happened.
