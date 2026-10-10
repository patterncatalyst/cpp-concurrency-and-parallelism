---
title: "Benchmarking Without Deception"
order: 18
layout: tutorial
sectionid: docs
part: low-latency-and-high-throughput
description: "Warmup and the cold-call bias, coordinated omission and why it hides the tail, percentiles versus the mean, wall-clock vs CPU time, and the repeatable harness this book's other chapters cite for their own benchmark claims."
duration: "17 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/39-benchmarking-without-lies.md | anchor books: Son, Lim -->

## What we'll cover

- Show why a cold first call isn't a valid measurement, and what warmup actually needs to stabilize.
- Explain coordinated omission: the failure mode where a benchmark silently skips measuring the requests that couldn't even start.
- Argue for percentile-based reporting (p50/p99/p999) over a mean, with an example where the mean hides the real behavior.
- Separate wall-clock time from CPU time, and pin down which clock and which frequency-scaling policy a measurement actually depends on.
- Cover microbenchmark pitfalls, particularly the compiler deleting unobserved work the benchmark thought it was timing.
- Assemble the pieces into a repeatable harness other chapters in this book point to rather than re-deriving.

Several chapters in this book make a performance claim and defer the exact number to "the Chapter 18 benchmark." This is that chapter: not a specific result, but the methodology that makes any result in this book trustworthy. Everything that follows serves one question: when a measurement says a path takes 47 nanoseconds, what has to be true for that number to mean what it claims?

## Warmup and Cold-Call Bias

The first several calls to almost any function are not representative of the steady state a real caller experiences, and treating them as if they were is the most common way a benchmark deceives itself before a single line of statistics gets involved. An allocator has not yet carved out the thread-local arena it will reuse for the rest of the run; the branch predictor has not yet learned which way a length check usually goes; the instruction and data caches are cold, so the first iterations pay full memory latency for lines later iterations find resident. None of this is specific to C++ — it's a property of the hardware and allocator underneath any language — but a C++ benchmark has a wrinkle a managed runtime doesn't: there's no JIT to warm up, which tempts people into skipping warmup on the theory that native code is "ready" from the first instruction. The code is ready; the cache and branch-predictor state around it is not.

A repeatable harness runs a fixed number of throwaway iterations before it starts the clock, and discards every one of them. The right warmup count is the smallest number that makes the reported percentiles stop drifting between runs — too few and the first real samples still carry cold-cache cost, too many and the warmup phase wastes wall-clock time without buying additional stability past the point where the working set is already resident. A practical check is to log the raw samples from the first dozen post-warmup iterations alongside the rest: if they sit visibly above the steady-state median, warmup ended too early.

Run-to-run variance is a separate problem warmup does not fix. Ten runs of the same fixed workload on the same host produce ten different numbers, because the scheduler, the cache state, and the CPU's own clock frequency all move between runs for reasons that have nothing to do with the code under test. The discipline this implies is to never trust a single number from a single run: collect many individually timed samples within a run, and treat the distribution — not a single average pulled from one execution — as the result.

## Coordinated Omission

A benchmark's timed loop is almost always a **closed loop**: iteration N+1 does not start its clock until iteration N has returned. This is the natural way to write a measurement loop, and it is also, in Gil Tene's phrase, the exact shape that produces coordinated omission. Suppose one iteration stalls — a page fault, a migration to a different core, a neighboring process winning the scheduler's attention — for a thousand times the typical iteration cost. The closed loop records exactly one sample for that stall: the one iteration's latency. A real caller sending requests at a fixed rate is not a closed loop, though. It does not pause its request rate while that stall plays out; five, ten, a hundred more requests queue up behind it, each waiting its turn, each experiencing a delay close to the stall's own length. The closed loop's benchmark omitted every one of those queued requests from its sample set. It did not merely under-measure the tail — it erased the part of the distribution the tail exists to describe.

<!-- DIAGRAM SPEC: Two stacked horizontal bands on a cream #fdfbf7 background. Top band labeled "closed-loop timer": four small blue #4a73b8 boxes in a row representing iterations 1-3 at roughly equal small width, then a wide red #c0392b box labeled "iteration 4: stall (page fault / migration)" — one sample recorded for the whole stall. Bottom band labeled "fixed-rate caller's experience": the same three small boxes, the same wide red stall box, then two dashed orange #a06030 ghost boxes labeled "request 5 (queued)" and "request 6 (queued)" trailing the stall and shrinking back toward the steady-state width. A dashed vertical connector ties the two red stall boxes together labeled "same stall". Caption note beneath both bands: "the raw p99 sees one outlier; the corrected p99 backfills the requests queued behind it." -->
{% include excalidraw.html name="18-coordinated-omission" caption="Figure 18.1 — a closed-loop timer records one sample for a stall; a fixed-rate caller actually experiences several queued requests behind it" %}

The correction is mechanical once the picture is clear: for every raw sample `v` exceeding an expected interval `E` (the per-operation time a sustained caller would target between requests), backfill synthetic samples `v - E, v - 2E, ...` down to `E`, standing in for the requests that would have queued behind the stall. A harness can set `E` to the run's own measured median, so the correction needs no extra input. The backfill should be capped at some bound so a single pathological stall cannot grow the sample array without limit. The resulting corrected percentile, `co_p99`, is always greater than or equal to the raw `p99` from the same run — that inequality is the cheapest sanity check a harness can assert on itself, and it's what a verification script should check rather than any specific nanosecond figure, since the figure depends on the host running it.

Reporting the raw percentile alone, which is what most hand-rolled benchmark loops do by default, is not wrong arithmetic. It is measuring a question nobody asked: "what did the one stall that happened cost me," rather than "what does my tail actually look like to the callers queued behind it."

## Percentiles vs the Mean

None of the numbers this chapter cares about should be an arithmetic mean, and that is deliberate. Latency distributions are heavy-tailed: the overwhelming majority of calls finish in some narrow band of nanoseconds, and a small minority — touched by a scheduler decision, a page fault, or a cache eviction — finish orders of magnitude slower. Averaging those together drags the mean toward the tail by exactly the outliers a reader most needs to see reported accurately, while simultaneously hiding how bad the tail actually gets. A mean of 200 ns is consistent with "every call took 200 ns" and with "999 calls took 40 ns and one took 160,200 ns," and those describe two very different systems to operate against. A percentile answers a sharper question — "what latency do 99% of calls beat?" — without blending the tail into the body.

The simplest correct percentile implementation is nearest-rank indexing over a fully sorted sample array: `sorted[floor(p * (n - 1))]`. It needs no interpolation and no bucketing, and it is correct at any sample count a single benchmark run is likely to produce. A production latency-tracking library would instead bucket values logarithmically, trading a small, bounded amount of precision for the ability to report percentiles in constant memory over an effectively unbounded stream of samples — worth knowing as the next step once a harness needs to run past tens of millions of samples or report percentiles continuously rather than from one finished array, but not a requirement for the fixed-size runs this chapter's own harness performs.

## Wall-Clock Time, CPU Time, and the Clock Itself

A latency measurement answers "how long did a caller wait," which is wall-clock time, not CPU time. A thread that blocks — on a lock, a page fault, or the scheduler handing a core back — accumulates wall-clock time a caller actually experienced while accumulating little or no CPU time, since it was not running. A profiler measuring CPU time (`clock()`, `getrusage`'s `ru_utime`) reports that blocked interval as nearly free, which is backwards for a benchmark whose purpose is to capture what a caller waited through. `std::chrono::steady_clock` is the right clock: monotonic, immune to NTP or manual wall-clock adjustments moving it backward mid-measurement, and measuring real elapsed time regardless of whether the thread was running, blocked, or preempted. `std::chrono::system_clock` is the wrong choice for timing for the same reason it's the right choice for a log timestamp — it can jump.

The rate the clock measures against has to stay fixed too. CPUs run under a frequency-scaling driver that picks a clock rate per core, per instant, and that rate can range by several times across a run under a power-saving governor with turbo boost active, for reasons unrelated to the code under test. That variation lands in `max_ns` and in whatever tail percentile gets reported, indistinguishable from real code-path variance unless controlled for. Pinning the governor to its performance policy for the run's duration removes the confound; leaving it at a power-saving default and reporting the tail as if it reflected only the code under test is one of the easier ways a benchmark deceives its own author.

## Microbenchmark Pitfalls: the Compiler Deletes What You Don't Watch

The final trap has nothing to do with clocks: a sufficiently capable compiler will prove a benchmark's result is never used and delete the code that produces it, leaving an accurate measurement of an empty loop. If a timed iteration computes a value and nothing afterward reads it, the optimizer is entitled to remove the computation entirely — not approximately, but completely, down to a function that returns without doing the work the benchmark believes it is timing.

The fix is to make the result observably used: accumulate every iteration's output into a running value the program actually reads afterward, such as a checksum printed at the end of the run. Because the final value is observable, the optimizer cannot prove any step feeding it is dead, and the accumulation doubles as a correctness check — a workload with a fixed, known input should always produce the identical checksum, so a diverging checksum across two runs signals a logic bug rather than measurement noise. This is the same role a dedicated microbenchmarking library's "do not optimize" intrinsic plays: it marks a value as having escaped to the outside world without spending the cost of a real side effect like a syscall. A hand-rolled checksum accumulator is a fine substitute when a harness is small enough to read end to end — warmup, per-iteration timing, coordinated-omission correction, and the dead-code trap all visible in one file rather than hidden inside a framework's reporting format.

## A Repeatable Harness

Putting the pieces together gives a specific, repeatable shape: discard a fixed number of warmup iterations without timing them; time every remaining iteration individually between two `steady_clock` reads; fold each iteration's result into an accumulator the program reads at the end, so nothing gets optimized away; sort the raw samples and report `min`, the median, `p99`, and `max`; run `co_correct` over the same raw array using the run's own median as the expected interval, re-sort, and report `co_p99` alongside the raw figure; and do all of this with the CPU frequency governor pinned for the run's duration. Every other chapter in this book that measures something — an atomic ordering's cost, a lock-free ring buffer's throughput, a false-sharing penalty — is building on exactly this shape rather than inventing its own, which is the point of writing it down once.

<!-- EXAMPLE SPEC: examples/concurrency/18-benchmarking-without-deception/ implements the harness above against a deliberately simple, fixed workload (an atomic fetch_add loop with a known iteration count), exposing --iters and --warmup flags and printing min/median/p99/max alongside co_p99/co_n; a --naive mode skips warmup and times a single unwarmed wall-clock sample instead, printing no percentiles at all, to make the methodology gap visible in the program's own output rather than only in prose; verified by a Lua verify.lua asserting co_p99_ns >= p99_ns, co_n >= n, the accumulated checksum matches the closed-form expected sum for the fixed workload, and that --naive's output contains no p99_ns/median_ns fields; built via lgtm-docker-stack, with a taskset-pinned invocation compared against an unpinned one to show migration-induced variance in max_ns. -->

## Running in a container

Running this chapter's harness inside a container introduces two confounds that have nothing to do with the code being measured. The first is the CPU quota set by `--cpus=N` (the cgroup v2 `cpu.max` controller): the kernel still schedules the container's threads on every core the host makes visible, but it periodically throttles the cgroup once it exhausts its allotted CPU time for the current period, and every throttled period shows up as a multi-millisecond stall indistinguishable from the scheduling noise this chapter already spends two sections correcting for. The throttled time itself is visible and worth reading directly rather than inferred from the tail: `cpu.stat` inside the cgroup reports it as `throttled_usec`, a microsecond count, and a nonzero or climbing value there during a benchmark run is a direct admission that some of the reported tail latency is quota exhaustion, not the code path under test.

The second confound is subtler: `std::thread::hardware_concurrency()` on a reasonably current glibc reflects the container's `cpuset.cpus` restriction — shrinking correctly if the cgroup narrows which cores are visible — but it does not reflect the `cpu.max` quota at all. A container capped to half a core's worth of CPU time by quota but with every core still visible through its cpuset will report the host's full core count from `hardware_concurrency()`, and a benchmark harness that sizes its thread pool from that number will oversubscribe the actual CPU budget it has been given, producing contention the code under test did not cause. Reading `cpu.max` directly, rather than trusting `hardware_concurrency()` to reflect it, is the only reliable way to size a benchmark's concurrency to what the container will actually schedule.

## Standards: C++20 / C++23 / C++26

The harness's core mechanism — a monotonic clock, a sorted sample array, a checksum accumulator — needs nothing from any of these three standards and has worked since `std::chrono::steady_clock` arrived in C++11. What each revision changes is how cleanly the surrounding machinery — background monitoring, reporting, and warmup scheduling — can be expressed.

C++20's `std::jthread` paired with `std::stop_token` gives a background governor-watching thread cooperative cancellation without a hand-rolled atomic flag: the watcher checks `stop_requested()` on each pass, and the `jthread`'s destructor requests the stop and joins automatically when the benchmark function returns. C++23's `std::print`/`std::println` (`<print>`) replace the usual `iostream` or `printf` formatting dance in the reporting function with a single type-safe call. C++26's `std::execution` (senders/receivers) is proposed and experimental — no shipping compiler implements it as of this writing — but it offers a scheduler abstraction that can usefully bulk-schedule the warmup phase across a thread pool, since warmup iterations, unlike the timed loop itself, do not need to preserve a single-threaded closed-loop ordering.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// A jthread cooperatively watches the CPU frequency while the timed loop
// runs, using a stop_token instead of a hand-rolled atomic<bool> flag.
void watch_governor(std::stop_token tok, std::vector<long>& freq_khz) {
    while (!tok.stop_requested()) {
        freq_khz.push_back(read_scaling_cur_freq_khz());
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

void run_benchmark(std::size_t iters) {
    std::vector<long> freqs;
    std::jthread watcher(watch_governor, std::ref(freqs));
    auto samples = timed_loop(iters);
    // watcher's destructor calls request_stop() then join() automatically.
    report(samples, freqs);
}
```

```cpp
// C++23
// std::print/std::println (<print>) replace the iostream/printf dance
// in the reporting function with a single type-safe call.
void report(std::vector<std::int64_t> sorted) {
    std::ranges::sort(sorted);
    std::println("n={} min_ns={} p50_ns={} p99_ns={} max_ns={}",
                  sorted.size(), sorted.front(),
                  percentile(sorted, 0.50), percentile(sorted, 0.99),
                  sorted.back());
}
```

```cpp
// C++26 (proposed, experimental: std::execution has no shipping compiler
// implementation as of this writing)
void run_warmup_parallel(std::size_t warmup_iters) {
    namespace ex = std::execution;
    auto sched = get_thread_pool_scheduler();  // a concrete scheduler type
    ex::sync_wait(ex::schedule(sched)
                  | ex::bulk(warmup_iters, [](std::size_t) { run_once(); }));
    // The timed loop itself stays single-threaded: bulk scheduling is only
    // safe to apply to warmup, which has no closed-loop ordering to preserve.
}
```

## What we learned

A benchmark earns trust by removing confounds one at a time rather than by producing an impressive-looking number: discard the cold calls that measure allocator and cache warmup instead of the code under test, correct for the requests coordinated omission would otherwise erase from the tail, report a percentile instead of a mean, measure wall-clock time on a monotonic clock while holding the frequency governor fixed, and keep the compiler from optimizing away the very thing being measured by making every iteration's result observably used. A container adds two of its own confounds on top of these — quota throttling visible in `cpu.stat`'s `throttled_usec`, and a core count from `hardware_concurrency()` that reflects the cpuset but not the quota — that a benchmark run inside one has to account for separately from the host-level sources of noise this chapter spends most of its time on.

[The Low-Latency Fast Path]({{ '/docs/19-the-low-latency-fast-path/' | relative_url }}) spends the discipline built here: once a `p99` can be trusted, the next question is how to make it small, through core pinning, zero-allocation hot paths, and the busy-poll-versus-block trade-off.
