---
title: "Concurrency in Containers"
order: 32
layout: tutorial
sectionid: docs
part: practice
description: "cgroup CPU quota versus cpuset, why hardware_concurrency() lies inside a container, sizing pools to the real quota, and pinning under an orchestrator."
duration: "16 min"
---

<!-- PROVENANCE: NEW (adapted from cpp-statelessness/_docs/05-threading.md, 11-build-tooling.md) | anchor books: statelessness -->

## What we'll cover

- Distinguish a cgroup CPU quota (a time budget per period) from a cpuset (a fixed set of visible cores).
- Demonstrate concretely why std::thread::hardware_concurrency() reports the host's core count, not the container's quota.
- Cover deriving a correct pool size from the cgroup quota or an orchestrator-supplied CPU_LIMIT.
- Cover CPU pinning under an orchestrator and the interaction with cgroup and cpuset constraints.

Every thread pool, every allocator arena count, every polling loop this book has built so far assumed the thread could see the machine it was actually running on. Inside a container that assumption is wrong in a specific, mechanical way: the kernel interface a C++ program queries for CPU count reflects one cgroup control, and the limit that actually throttles the program reflects a different one entirely. The two controls are easy to confuse because they are configured from the same `--cpus` flag or the same Kubernetes `resources` block, but they are enforced by unrelated code paths in the kernel, and a pool sized correctly under one is badly oversized under the other. This chapter works through both controls, the specific place `std::thread::hardware_concurrency()` gets it wrong, and the sizing and pinning rules that hold regardless of which orchestrator put the container there.

## cgroup CPU Quota vs cpuset

The Linux cgroup v2 CPU controller exposes two independent knobs, and a container's `--cpus=2` or a pod's `resources.limits.cpu: "2"` can map to either one depending on what sits underneath.

`cpu.max` is a **time budget**: a quota in microseconds and a period in microseconds, written as two numbers in one file — `200000 100000` means 200 ms of CPU time allowed per 100 ms period, which is the kernel's way of expressing "2 cores' worth of time." The Completely Fair Scheduler's bandwidth controller tracks aggregate runtime across every thread in the cgroup and, once the quota for the current period is exhausted, deschedules every one of those threads until the next period boundary. Critically, the quota says nothing about which physical cores the cgroup's threads may use — they remain free to run on any core the scheduler picks, spread across as many cores as there are runnable threads, for as long as the aggregate time budget allows. Eight threads each getting 25 ms of wall time on eight different cores exhausts a 200 ms quota exactly as fast as two threads running flat out on two cores for 100 ms. The quota taxes total CPU-seconds, not core count.

`cpuset.cpus` is the opposite kind of control: a **fixed set of CPU IDs** the cgroup's tasks are allowed to run on at all, enforced the same way `sched_setaffinity` restricts an individual thread — the scheduler's placement decision excludes every core outside the set outright. A cgroup pinned to `cpuset.cpus=4-5` can use exactly cores 4 and 5, for as much wall-clock time as it wants, with no period-based accounting and no throttling event. There is no quota to exhaust: a thread spinning continuously on core 4 just keeps running there, competing only with whatever else cgroup policy has also placed on that core.

The two controls are orthogonal and frequently combined without either side realizing it. A container can be assigned `cpuset.cpus=0-7` (visible on all eight host cores) while also carrying `cpu.max = 200000 100000` (a two-core time budget) — the Docker and Kubernetes default when requesting `--cpus=2` on an otherwise unconstrained host. That container's threads can land on any of eight cores but collectively burn only two cores' worth of time per period; a workload that spreads across all eight gets throttled hard and often, each thread claiming a thin, unpredictable slice. A different container might instead carry `cpuset.cpus=4-5` with no `cpu.max` entry at all (`max` meaning unlimited) — full, unthrottled use of exactly two specific cores, the shape Kubernetes' CPU Manager static policy produces for a Guaranteed-QoS pod, covered later in this chapter. Both configurations describe "two cores" to a human reading the resource request, and they behave completely differently under load: one throttles in bursts, the other never throttles because there is no time budget to exceed.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, two stacked horizontal lanes representing the same 8-core host. Top lane labeled "cpu.max = 200000 100000 (a time budget)": all 8 CPU icons drawn in blue #4a73b8 with a dashed outline meaning "visible, any may be used"; a horizontal timeline beneath the lane marked in 100ms periods, with a red #c0392b bar filling the first 20ms of each period and a red "THROTTLED" label spanning the remaining 80ms, annotated "aggregate runtime across ALL used cores counted against one quota". Bottom lane labeled "cpuset.cpus = 4-5 (a fixed core set)": cores 0-3 and 6-7 greyed out and crossed through, cores 4 and 5 shown solid green #5a8870 with "100% usable, no throttling" beneath them, annotated "scheduler excludes every other core outright — no period, no budget to exhaust". A vertical orange #a06030 divider between the two lanes labeled "same '--cpus=2' request, two different enforcement mechanisms". -->
{% include excalidraw.html name="32-quota-vs-cpuset" caption="Figure 32.1 — cpu.max throttles aggregate time across all visible cores; cpuset.cpus restricts which cores are visible at all, with no time accounting" %}

Kubernetes layers its own terminology over the same two mechanisms. A Burstable or BestEffort pod gets `cpu.max` derived from `resources.limits.cpu` (or no limit at all) with `cpuset.cpus` left spanning every core on the node. A Guaranteed pod (`requests.cpu` equal to `limits.cpu`, both an integer number of cores) is eligible for the kubelet's CPU Manager static policy, which, when enabled, removes that container from `cpu.max` accounting entirely and instead grants it exclusive, pinned cores via `cpuset.cpus`. The practical upshot: two pods that both "request two cores" can be running under mechanically different enforcement, and a program that only reads `cpu.max` will see nothing at all on the pinned one, because there is no quota file populated with a meaningful value once a cgroup is cpuset-exclusive.

## Why hardware_concurrency() Lies in a Container

`std::thread::hardware_concurrency()` is specified loosely ("the number of hardware thread contexts," and allowed to return 0 if it cannot be determined), but every mainstream implementation resolves it by asking the kernel how many CPUs this process could run on right now. On Linux, that means `sched_getaffinity()` under the hood, and glibc 2.36 and later makes this binding explicit: `get_nprocs()` and `hardware_concurrency()` both read the calling thread's affinity mask, so a `cpuset.cpus` restriction is reflected correctly. A container pinned to two cores via cpuset reports `2`, not the host's full count. This is the easy case, and it works.

The cgroup CPU quota is a different story, and this is the trap worth building a mental alarm around: `cpu.max` has no effect on the affinity mask at all. A time budget does not remove any core from the set a thread may be scheduled onto — it only limits how much aggregate time the cgroup's threads may consume before being throttled. A container given `--cpus=2` with no accompanying cpuset restriction sits on a host with, say, sixteen visible cores, and `hardware_concurrency()` faithfully reports `16`, because sixteen cores really are reachable by `sched_setaffinity`. The number is not a bug in the standard library; it answers the question it was actually asked, "how many cores can a thread here be scheduled on" — a different question from "how much CPU time has this container been granted." A program that conflates the two and sizes a thread pool, an OpenMP parallel region, or a PMR allocator's arena count from `hardware_concurrency()` alone spins up sixteen threads to share a two-core time budget, and every one of Chapter 20's mechanical-sympathy concerns about contention and cache pollution now compounds with CFS throttling pauses spread across fourteen more threads than the quota can actually run concurrently.

A minimal demonstration makes the gap concrete without needing a full cgroup-reader library:

```cpp
#include <cstdio>
#include <fstream>
#include <optional>
#include <string>
#include <thread>

// Returns effective cores from cgroup v2's cpu.max, or nullopt if
// unconstrained (quota == "max") or the file isn't present at all.
std::optional<double> cgroup_cpu_quota() {
    std::ifstream f{"/sys/fs/cgroup/cpu.max"};
    if (!f) return std::nullopt;
    std::string quota;
    long period = 0;
    if (!(f >> quota >> period) || quota == "max" || period <= 0) {
        return std::nullopt;
    }
    return std::stod(quota) / static_cast<double>(period);
}

int main() {
    const unsigned hw = std::thread::hardware_concurrency();
    const auto quota = cgroup_cpu_quota();

    std::printf("hardware_concurrency() = %u\n", hw);
    if (quota) {
        std::printf("cgroup cpu.max quota   = %.2f cores\n", *quota);
    } else {
        std::printf("cgroup cpu.max quota   = unlimited or unavailable\n");
    }
}
```

Run on the bare host, both numbers typically agree, or the quota line reports unlimited. Run the identical binary inside `docker run --cpus=2 ...` on a sixteen-core host and the gap opens up directly: `hardware_concurrency()` keeps reporting `16`, the quota line reports `2.00`. Nothing about the container narrowed what the thread could see; it narrowed only how much it could run.

## Sizing Pools to the Quota

The fix is to stop treating `hardware_concurrency()` as the pool-sizing input and instead read the actual constraint, falling back to the host count only when no constraint exists. The read has to check both the quota and, separately, the cpuset, because either one alone can be the binding constraint:

```cpp
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <fstream>
#include <optional>
#include <sched.h>
#include <string>
#include <thread>

std::optional<double> cgroup_cpu_quota() {
    std::ifstream f{"/sys/fs/cgroup/cpu.max"};
    if (!f) return std::nullopt;
    std::string quota;
    long period = 0;
    if (!(f >> quota >> period) || quota == "max" || period <= 0) {
        return std::nullopt;
    }
    return std::stod(quota) / static_cast<double>(period);
}

unsigned affinity_cpu_count() {
    cpu_set_t set;
    CPU_ZERO(&set);
    if (::sched_getaffinity(0, sizeof(set), &set) != 0) {
        return std::thread::hardware_concurrency();
    }
    return static_cast<unsigned>(CPU_COUNT(&set));
}

// The pool size a CPU-bound stage should actually use: the tighter of
// the cpuset-visible core count and the cgroup quota, never below 1.
unsigned recommended_cpu_pool_size() {
    if (const char* env = std::getenv("CPU_LIMIT")) {
        const double v = std::atof(env);
        if (v > 0.0) return std::max(1u, static_cast<unsigned>(std::floor(v)));
    }
    const unsigned affinity = affinity_cpu_count();
    if (const auto quota = cgroup_cpu_quota()) {
        return std::max(1u, static_cast<unsigned>(
            std::floor(std::min(*quota, static_cast<double>(affinity)))));
    }
    return std::max(1u, affinity);
}
```

An orchestrator-supplied `CPU_LIMIT` environment variable, when present, wins outright — the orchestrator already knows the real allocation, including cases (a fractional quota, a CPU Manager static-policy pin) a generic cgroup reader has to work harder to characterize correctly, so re-deriving it in every process is both redundant and a second place for the logic to drift out of sync with the platform. In its absence, the tighter of the two kernel-reported numbers is the right answer: a quota smaller than the cpuset implies CFS throttling is the active constraint; a cpuset smaller than the quota (the Guaranteed-pod case) implies there is effectively no time budget to worry about and the pinned core count is the ceiling.

This matters for every pool a C++ service creates or inherits, not only the application's own `std::thread` pool from [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}). The parallel algorithms' execution policies, OpenMP's default team size, TBB's task arena, and every allocator in the jemalloc/tcmalloc/mimalloc family that sizes per-CPU arenas from a raw core probe are sources of the same oversubscription at their defaults. The general rule for a CPU-bound stage is `N = floor(min(quota, cpuset_count))` threads; an I/O-bound stage that spends most of its time blocked can safely run more threads than that ceiling, bounded instead by memory and connection limits, since a thread parked in `epoll_wait` consumes none of the quota while it waits.

## Pinning Under Orchestration

Pinning a thread to a specific core with `sched_setaffinity` inside a container interacts with whichever of the two cgroup mechanisms is active, and the two interactions are not symmetric. Under a pure `cpu.max` quota with no cpuset restriction, pinning still works mechanically (the affinity call succeeds and the thread genuinely stops migrating), but it does nothing to protect that thread from CFS throttling, because the quota is accounted across the whole cgroup regardless of which cores its threads happen to be pinned to. A pinned, busy-spinning thread under a tight quota burns through the cgroup's entire time budget by itself and gets throttled exactly as it would unpinned; pinning here buys cache locality and eliminates migration jitter, but it buys no additional CPU time.

Under a cpuset restriction, pinning composes cleanly, with one caveat: the affinity mask a thread requests must be a subset of the cgroup's own `cpuset.cpus`, or the call fails outright, since a cgroup cannot grant a thread access to a core the cgroup itself cannot use. Kubernetes' CPU Manager static policy is the orchestrated version of exactly this setup. Enabled on the kubelet and requested by a container in a Guaranteed-QoS pod with an integer CPU count, it removes that container's cores from the node's shared pool and assigns them exclusively via `cpuset.cpus`, with no other pod's threads competing for them. A C++ process inside such a pod can call `sched_setaffinity` to pin its hot-path threads to specific cores within that exclusive set, matching [The Low-Latency Fast Path]({{ '/docs/19-the-low-latency-fast-path/' | relative_url }})'s pinning discussion, and the result is a guarantee the plain `--cpus` quota case cannot offer: those cores are never time-shared with anything else the orchestrator might schedule, so there is no throttling event to defend against in the first place.

The practical rule for a latency-sensitive container follows directly from the two mechanisms, not from any single knob: request whole, integer cores rather than a fractional quota, request them under a QoS class and CPU Manager configuration that grants cpuset-exclusive pinning rather than a shared time budget, pin the hot-path threads explicitly within that exclusive set once running, and size every pool (the application's own, and every library's that creates one implicitly) from the pinned core count rather than from `hardware_concurrency()`. Where exclusive pinning is not available and a shared quota is the reality, keep thread count at or below the quota, monitor `cpu.stat`'s `throttled_usec` field continuously, and treat any sustained climb in it as the clearest available signal that the fix is a smaller pool or a larger quota, not a faster algorithm.

## Running in a container

The cgroup-detection example in this chapter (`cgroup-probe`, printing `hardware_concurrency()`, the cpuset-visible count, and the `cpu.max` quota side by side) is the chapter's own worked instance of the gap above, and it is most convincing run progressively. On the bare host all three numbers typically agree, or the quota reports unlimited. Run it under `docker run --cpus=4 --cpuset-cpus=0-7 cgroup-probe` on a host with more than eight cores and the cpuset count drops to 8 while the quota drops to 4.00 — two different numbers, both smaller than the host total, for two different reasons. Narrow the cpuset further, to `--cpuset-cpus=0-3`, and the cpuset count and the quota converge, because the cpuset is now the tighter constraint. Drop `--cpuset-cpus` entirely and keep only `--cpus=2` and the cpuset count jumps back to the full host count while the quota stays at 2.00 — the oversubscription scenario from this chapter's opening, reproduced on demand. Running the probe alongside `cat /sys/fs/cgroup/cpu.stat` before and after a deliberately oversized pool makes `throttled_usec` climb visibly, the most convincing evidence that a pool sized from `hardware_concurrency()` rather than the quota is actively paying for it.

## Standards: C++20 / C++23 / C++26

Nothing in the standard addresses cgroups or CPU quotas directly — this remains Linux-specific, `/sys/fs/cgroup` and `sched_getaffinity` territory at every standard version this book covers. What does shift across standards is how a cgroup-reading helper is written and how a pool reacts once it has a verified core count: `std::optional`-based detection gives way to a typed-error alternative in C++23, and C++26's cooperative scheduling proposal offers a (still experimental) way to hand a verified thread count to a scheduler rather than a raw pool constructor.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20: std::optional collapses "no quota configured" and "couldn't
// read the file" into the same empty state — a caller sizing a pool
// from this can't tell a healthy unconstrained host from a read failure.
std::optional<double> cgroup_cpu_quota_v20() {
    std::ifstream f{"/sys/fs/cgroup/cpu.max"};
    if (!f) return std::nullopt;          // file missing: cgroup v1, or no cgroups at all
    std::string quota; long period = 0;
    if (!(f >> quota >> period)) return std::nullopt;   // malformed: also folds in here
    if (quota == "max" || period <= 0) return std::nullopt;  // unlimited: same empty state
    return std::stod(quota) / static_cast<double>(period);
}
```

```cpp
// C++23: std::expected (also <expected>) separates "unlimited" from an
// actual read failure, which matters when a monitoring path wants to
// alert on the latter but not the former.
#include <expected>

enum class QuotaStatus { unlimited, no_cgroup_v2, malformed };

std::expected<double, QuotaStatus> cgroup_cpu_quota_v23() {
    std::ifstream f{"/sys/fs/cgroup/cpu.max"};
    if (!f) return std::unexpected(QuotaStatus::no_cgroup_v2);
    std::string quota; long period = 0;
    if (!(f >> quota >> period)) return std::unexpected(QuotaStatus::malformed);
    if (quota == "max" || period <= 0) return std::unexpected(QuotaStatus::unlimited);
    return std::stod(quota) / static_cast<double>(period);
}
```

```cpp
// C++26 (proposed, experimental -- std::execution ships in no shipping
// compiler as of this writing): a scheduler constructed with a thread
// count read from the quota, rather than a raw thread pool sized by
// hand -- the sizing policy above feeds the scheduler instead of a
// constructor argument the caller has to remember to compute correctly
// every time a pool is created.
namespace ex = std::execution;   // schedulers/senders vocabulary

const unsigned n = recommended_cpu_pool_size();   // from "Sizing Pools to the Quota"
exec::static_thread_pool pool{n};   // exec:: in the stdexec reference, not std::execution
auto sched = pool.get_scheduler();
```

`std::expected` is the more durable improvement of the two here: a cgroup reader that returns `std::optional` cannot distinguish "this host has no CPU limit at all" from "the file could not be parsed," and a deployment pipeline that wants to fail loudly on the second case while treating the first as entirely normal needs that distinction preserved through the return type rather than reconstructed by re-parsing the file a second time. `std::execution`'s scheduler construction is a smaller, syntactic shift (the sizing logic itself does not change, only where the resulting number is handed off), worth knowing the shape of without expecting it on a production toolchain yet.

## What we learned

- `cpu.max` (a time budget enforced by the CFS bandwidth controller across every visible core) and `cpuset.cpus` (a fixed, pinned set of visible cores with no time accounting) are independent cgroup v2 controls, and a single `--cpus=N` or Kubernetes `resources` block can map to either one or both at once.
- `std::thread::hardware_concurrency()` reflects `cpuset.cpus` correctly on glibc 2.36 and later, because it reads the affinity mask — but it never reflects `cpu.max`, because a time quota does not remove any core from that mask. A quota-limited container on a large host reports the host's full core count regardless of how little CPU time it has actually been granted.
- Every pool that matters — the application's own thread pool, the parallel algorithms, OpenMP, TBB, and the allocator's arena count — should be sized from `min(cpuset count, cgroup quota)` or an orchestrator-supplied `CPU_LIMIT`, never from `hardware_concurrency()` alone.
- `cpu.stat`'s `throttled_usec` field (not `throttled_time`) is the direct evidence of CFS throttling; a climbing value under a fixed pool size is the clearest sign the quota, not the algorithm, is adding latency.
- Pinning a thread under a pure quota stops migration but does not exempt it from throttling, since the quota is accounted across the whole cgroup. Pinning under a cpuset — the shape Kubernetes' CPU Manager static policy produces for Guaranteed-QoS pods with integer CPU requests — grants genuinely exclusive, unthrottled cores.
- For a latency-sensitive container: request whole cores under a QoS class and CPU Manager configuration that yields cpuset-exclusive pinning rather than a shared quota, pin hot-path threads explicitly within that set, and size pools from the pinned count rather than a host-wide probe.

<!-- EXAMPLE SPEC: examples/concurrency/32-concurrency-in-containers/ builds a small cgroup-probe binary that prints hardware_concurrency(), the sched_getaffinity()-derived cpuset count, and the cgroup v2 cpu.max quota side by side, plus a pool-bench binary (reused from the Chapter 21-style harness) that runs a fixed CPU-bound workload at pool sizes derived from each of the three numbers under a tightening sequence of --cpus / --cpuset-cpus limits, logging cpu.stat's throttled_usec before and after each run. Verified by a Lua verify.lua asserting that the cpuset count tracks --cpuset-cpus exactly, that the cpu.max-derived quota tracks --cpus exactly, that hardware_concurrency() does NOT change when only --cpus (no --cpuset-cpus) is applied, and that throttled_usec strictly increases when the pool is sized from hardware_concurrency() instead of the derived quota under a tight --cpus limit; built and run via lgtm-docker-stack across the progressive --cpus/--cpuset-cpus sweep described in "Running in a container" above. -->
The example at `examples/concurrency/32-concurrency-in-containers/` runs exactly this progression and is the place to watch `throttled_usec` move on your own host rather than take the gap on faith.
