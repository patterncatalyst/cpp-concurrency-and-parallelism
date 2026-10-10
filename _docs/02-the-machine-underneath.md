---
title: "The Machine Underneath"
order: 2
layout: tutorial
sectionid: docs
part: foundations
description: "The hardware concurrency sits on top of: cores, simultaneous multithreading, cache coherence, NUMA topology, and the scheduler's context-switch cost."
duration: "15 min"
---

<!-- PROVENANCE: NEW | anchor books: Tanenbaum, Williams -->

## What we'll cover

- Map the distinction between physical cores and SMT/hyperthreaded logical cores, and why that distinction changes thread-pool sizing decisions.
- Walk the cache hierarchy (L1/L2/L3) and the coherence protocol that keeps cached copies of shared data consistent across cores.
- Introduce NUMA topology: local vs remote memory nodes, and why a thread's physical placement affects latency before any lock is even involved.
- Quantify the cost of an OS context switch and when the scheduler decides to pay it.

Every chapter after this one talks about locks, atomics, and scheduling as if the machine were a uniform pool of interchangeable execution units. It isn't. A core is not just "a place work runs" — it has siblings that steal its cache, a path to memory that may or may not cross a socket boundary, and a scheduler that charges real cycles every time it hands the core to someone else. None of that is optional background. It's the reason a correct, well-locked program can still run four times slower than it should, with every tool reporting no contention at all.

## Cores, SMT, and Hyperthreading

A modern server CPU reports more logical processors than it has physical cores. Simultaneous multithreading (SMT, Intel's branding is Hyper-Threading) lets one physical core present two (occasionally more) logical cores to the operating system, each with its own architectural register state, sharing the same execution ports, load/store units, and L1/L2 caches underneath. The idea is to fill stalls: while one logical thread waits on a cache miss or a dependency chain, the other can issue instructions into the ports the first one left idle. For workloads with irregular, memory-bound instruction streams — a web server juggling many independent requests — this genuinely raises throughput, because the two threads' stalls rarely line up.

It does the opposite for a single latency-sensitive compute thread. `std::thread::hardware_concurrency()` reports the logical count, and sizing a thread pool to that number for CPU-bound, cache-sensitive work puts two competing threads on every physical core — each halves the other's share of L1/L2 capacity and execution ports, and neither one gets the cycle count a dedicated core would give it. `lscpu -e` (or reading `/sys/devices/system/cpu/cpu*/topology/thread_siblings_list`) exposes which logical IDs share a physical core; a pool meant to run one hot compute thread per physical core should pin to one sibling from each pair and leave the other idle, rather than trust the logical count. This is also why low-latency trading systems routinely disable SMT in the BIOS entirely on the cores that matter: a dedicated physical core gives one thread deterministic, non-shared access to the L1 and the execution ports, and removing the sibling removes a whole category of jitter that no amount of application-level tuning can see or control.

## The Cache Hierarchy and Coherence

Between a core and DRAM sit two or three levels of cache, each smaller and faster than the one behind it. A rough shape on a current server part: L1 is 32–64 KiB per core, split into instruction and data, roughly four cycles away. L2 is a few hundred KiB to a few MiB per core (or per core pair), on the order of twelve cycles. L3 is shared across all the cores on a socket, several to tens of megabytes, around 40 cycles. A miss that falls all the way through to DRAM costs on the order of 100–300 cycles — two orders of magnitude slower than an L1 hit. Every cache line is 64 bytes on essentially every mainstream architecture, and that number matters more than any of the latencies, because it's the unit the coherence protocol operates on.

<!-- DIAGRAM SPEC: Layered pyramid on the left, cream #fdfbf7 background: Core 0 and Core 1 boxes (blue #4a73b8) each with a private L1 and L2 box beneath them (small, labeled "~4 cycles" and "~12 cycles"), both feeding into one shared L3 box (green #5a8870, labeled "~40 cycles") spanning both cores, which feeds into a DRAM box (orange #a06030, labeled "~100-300 cycles"). On the right, a MESI state diagram: four small circles labeled M (Modified), E (Exclusive), S (Shared), I (Invalid), arrows between them labeled with the triggering event (local read, local write, remote read snoop, remote write/invalidate), red #c0392b arrow highlighting the Modified-to-Invalid transition triggered by another core's write to the same line. -->
{% include excalidraw.html name="02-cache-hierarchy-mesi" caption="Figure 2.1 — the cache hierarchy's rough latencies, and the MESI states a cache line moves through to stay coherent across cores" %}

When two cores cache the same line and one of them writes to it, the hardware has to stop the other core from reading stale data — this is cache coherence, and the mechanism most x86 and ARM server parts use a variant of is MESI (Modified, Exclusive, Shared, Invalid), tracked per cache line. A line a core has written and not yet flushed is **Modified**; a line only one core holds, unwritten, is **Exclusive**; a line several cores hold read-only copies of is **Shared**; a line whose copy is stale because another core wrote it is **Invalid**. A write to a Shared line forces every other cached copy to Invalid — a broadcast (snoop) or directory lookup, depending on the platform — and the writing core's copy transitions to Modified. A subsequent read by another core on that now-invalid line has to fetch the current value, either from the writer's cache directly (a cache-to-cache transfer) or via memory, both markedly slower than a local hit.

This is the mechanism underneath **false sharing**: two unrelated variables, written by two different threads, that happen to land in the same 64-byte line. Logically the threads never touch each other's data. Physically, every write from either side invalidates the other's copy of the whole line, and the two threads end up paying full cross-core cache traffic for data they never share. Nothing in the source code suggests contention — no shared variable, no lock — and profilers that count cache misses but don't attribute them to a specific struct layout can miss it entirely. The fix is padding or alignment, discussed concretely with `std::hardware_destructive_interference_size` in the standards section below; the diagnosis is recognizing that the cache line, not the variable, is the unit two threads can collide on.

## NUMA Topology

A multi-socket server, and increasingly a single large chip built from multiple dies, does not have one uniform path to memory. Each socket or die has its own memory controller and its own bank of locally attached DRAM; a core can reach that bank quickly, and reach the DRAM attached to a different socket only by crossing an interconnect — Intel's UPI, AMD's Infinity Fabric — which adds real latency, often 30–100% over a local access depending on the platform and the distance. This is Non-Uniform Memory Access: "local" and "remote" are properties of which core is asking, not properties of the memory itself.

`numactl --hardware` prints the nodes present and the relative distance between them (a self-distance of 10, a cross-socket distance commonly in the 20s); `/sys/devices/system/node/` exposes the same mapping programmatically, including which CPUs belong to which node, so a long-lived service can discover its own topology at startup rather than assume one. The footgun that costs people the most time is Linux's **first-touch** allocation policy: `malloc` (or `new`) reserves address space, but a physical page isn't bound to a NUMA node until it's first written. A common pattern — main thread allocates a large buffer, then hands it off to worker threads pinned across several NUMA nodes — binds every page to the main thread's node on first touch, so every worker not on that node pays the remote-access penalty on every single read, for the life of the buffer, with nothing in the code announcing it. The fix is to touch (write) each region of memory from the thread, and therefore the node, that will actually own it — either explicitly with `numa_alloc_onnode` from `libnuma`, or implicitly by having each worker initialize its own slice of a shared buffer before the hot path begins. Chapter 16 builds this into an explicit allocation and pinning strategy; here the point is narrower: a lock-free, perfectly structured piece of concurrent code can still be slow, and the reason can be entirely a placement decision made before the first lock was ever taken.

## The Scheduler and Context-Switch Cost

The OS scheduler — the Completely Fair Scheduler or its EEVDF successor on current Linux kernels — decides which runnable thread occupies each core at each moment, and that decision is never free. A switch happens for two reasons: **voluntary**, when the running thread blocks on a syscall, a mutex, or I/O and has nothing left to do; and **involuntary**, when the thread's time slice expires or a higher-priority thread becomes runnable and preempts it.

<!-- DIAGRAM SPEC: Horizontal timeline, cream #fdfbf7 background. Left segment labeled "Thread A running" (blue #4a73b8) ending at a vertical red #c0392b dashed line labeled "context switch". Below the line, three stacked cost boxes in sequence: "save registers + PC + SP" (small, orange #a06030, ~tens of ns), "TLB/ASID transition" (orange #a06030, variable), "cold cache for Thread B's working set" (green #5a8870, the dominant cost, shown as a wide fading block of small X marks representing cache misses paid back over the following microseconds). Right segment labeled "Thread B running, slow start" fading from red to blue as its cache warms back up. Caption note: "the switch itself is cheap; refilling the cache it evicted is not." -->
{% include excalidraw.html name="02-context-switch-anatomy" caption="Figure 2.2 — a context switch's direct cost is small; its indirect cost is the cache working set it evicts, paid back in the misses that follow" %}

The mechanical part of a switch — saving one thread's registers, program counter, and stack pointer, and loading another's — costs on the order of tens to a few hundred nanoseconds; it is genuinely cheap. What makes a switch expensive in practice is almost entirely indirect: the outgoing thread's working set in L1 and L2 gets evicted by the incoming thread, the TLB may need a partial or full flush depending on whether the CPU supports tagging entries by address-space ID, and the incoming thread resumes execution into a cold cache, paying a string of misses it wouldn't have paid had it simply kept running. Measured end-to-end — including that cache rewarming, not just the register save — a context switch commonly costs somewhere in the low single-digit microseconds, and considerably more under memory pressure or with a large working set. For a service handling requests in tens of microseconds, an unplanned switch mid-request isn't noise; it can be the majority of the latency.

The low-latency answer is to make the scheduler stop making this decision on the hot path at all: `isolcpus` and `nohz_full` remove a core from the kernel's normal scheduling rotation and tickless housekeeping, a dedicated thread pinned to that core with no competing runnable work never needs to be preempted, and spinning or busy-polling instead of blocking on a syscall avoids ever handing the core back voluntarily. None of that is free — an isolated core that's mostly idle is capacity spent on reducing tail latency rather than throughput — but it is the direct, mechanical answer to a cost this section just quantified.

A runnable probe at `examples/concurrency/02-machine-underneath/` measures the three costs this chapter claims directly, rather than citing published numbers: pointer-chase latency at each cache level (defeating prefetch by randomizing the chase), and a forced migration between NUMA nodes compared against a pinned, local-touch allocation.

<!-- EXAMPLE SPEC: a pointer-chasing benchmark sized to fit in L1, then L2, then L3, then exceed all caches, reporting per-access latency at each size to make the cache hierarchy's latencies in Figure 2.1 observable; plus a NUMA comparison allocating a buffer, touching it from node 0, and timing access from a thread pinned to node 0 versus a thread pinned to a remote node; verified by verify.lua asserting latency strictly increases at each cache-size boundary and that the remote-node access is measurably slower than the local one; run via the KVM-lab (lgtm-systems-programming) since a real multi-node NUMA topology and exclusive core isolation aren't reliably available inside a container -->

## Running in a container

None of this chapter's hardware is virtualized away by a container, and that cuts both ways. Cache sizes reported under `/sys/devices/system/cpu/cpu*/cache/index*/size` are the host's real cache sizes — a container cannot shrink its neighbor's L3 footprint, which is exactly why two unrelated containers on the same socket can measurably slow each other down through L3 and memory-bandwidth contention even with CPU quotas fully respected. `numactl --hardware` run inside a container typically reports the host's real NUMA topology too, unless the container runtime restricts it: `--cpuset-mems` (or the equivalent Kubernetes `memory manager` policy) constrains which nodes a container's memory may come from, independent of `--cpuset-cpus`, which constrains which cores it may run on — and if the two are set inconsistently, a container can be pinned to run on node 0's cores while allowed to allocate memory anywhere, reintroducing the remote-access penalty from the NUMA section through a configuration mismatch rather than a code bug.

What a container *can* hide is the logical-to-physical core mapping discussed in the SMT section. A `--cpuset-cpus` list of logical IDs says nothing about which of them are SMT siblings of each other; a container scheduled onto two logical cores that happen to be two threads of the same physical core gets far less real parallelism than its CPU count suggests, and `lscpu -e` or `/sys/.../topology/thread_siblings_list` inside the container (where visible) is the only way to know. An orchestrator's CPU Manager, where available, can be configured to respect physical-core boundaries when assigning exclusive cores to a pod; absent that, the container's view of "how many CPUs do I have" and "how much independent execution hardware do I actually get" can diverge exactly as hardware_concurrency() and a cgroup quota diverged in the previous chapter — one more permission that isn't automatically an outcome.

## Standards: C++20 / C++23 / C++26

The library surface for reasoning about this chapter's hardware is thin by design — the standard describes a machine abstractly — but three concrete tools have landed or are landing. C++20 adds `std::atomic_ref`, which lets code perform atomic operations on an *existing*, ordinarily-typed object rather than requiring it to have been declared `std::atomic<T>` from construction — useful for retrofitting atomicity onto a field inside a cache-line-aligned struct without changing that struct's layout or size. C++23 adds the `[[assume(expr)]]` attribute, a standard, compiler-independent way to tell the optimizer an invariant holds at a point in the code — a cache-friendly loop bound, an alignment guarantee, a value range — without the UB risk of achieving the same effect by writing a branch that's never supposed to be taken. C++26 proposes `std::simd` (from the Parallelism TS, folded into the standard via P1928), a portable vector type whose width is meant to map onto the machine's actual SIMD registers; as of GCC 16 and clang 22 it is implemented only experimentally (most mainstream compilers still require the older, non-standard experimental parallelism TS headers or compiler intrinsics for production vector code), so treat it as the forward-looking case for now rather than something to ship against.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// Retrofit atomicity onto one field of an existing, cache-line-aligned
// struct without redeclaring it std::atomic<T> and changing its layout.
struct alignas(64) Counter {
    long value = 0;  // ordinary storage; no atomic<> wrapper
};
Counter shared_counter;

void bump() {
    std::atomic_ref<long> ref(shared_counter.value);
    ref.fetch_add(1, std::memory_order_relaxed);
}
```

```cpp
// C++23
// Tell the optimizer a cache-friendly invariant holds, without writing a
// branch the compiler has to prove is unreachable.
void sum_aligned(const float* p, std::size_t n, float* out) {
    [[assume(reinterpret_cast<std::uintptr_t>(p) % 64 == 0)]];
    [[assume(n % 16 == 0)]];
    float acc = 0.0f;
    for (std::size_t i = 0; i < n; ++i) acc += p[i];
    *out = acc;
}
```

```cpp
// C++26 (proposed; experimental-only support as of GCC 16 / clang 22)
// std::simd exposes a portable vector width meant to track the machine's
// real SIMD registers, rather than requiring intrinsics per architecture.
#include <experimental/simd>
namespace stdx = std::experimental;

void add_arrays(const float* a, const float* b, float* out, std::size_t n) {
    using V = stdx::native_simd<float>;
    std::size_t i = 0;
    for (; i + V::size() <= n; i += V::size()) {
        V va(a + i, stdx::element_aligned);
        V vb(b + i, stdx::element_aligned);
        (va + vb).copy_to(out + i, stdx::element_aligned);
    }
    for (; i < n; ++i) out[i] = a[i] + b[i];  // scalar remainder
}
```

## What we learned

- `hardware_concurrency()` counts logical cores, including SMT siblings that share a physical core's execution ports and L1/L2 cache; for cache-sensitive compute threads, sizing to the physical core count (or disabling SMT) beats sizing to the logical one.
- The cache hierarchy's latencies span two orders of magnitude from L1 to DRAM, and the 64-byte cache line, not the variable, is the unit the MESI coherence protocol tracks — which is why false sharing can serialize two cores with no shared variable in sight.
- NUMA makes "local" and "remote" memory a property of which core is asking; Linux's first-touch allocation policy binds a page to whichever thread writes it first, so a buffer allocated by one thread and handed to workers on other nodes silently pays a remote-access penalty on every access.
- A context switch's mechanical cost — saving and restoring registers — is cheap; its real cost is the evicted cache working set the incoming thread has to rebuild, which is why an unplanned switch mid-request can dominate a microsecond-scale latency budget.
- `isolcpus`, `nohz_full`, and busy-polling exist to keep the scheduler from ever making a decision on the hot path, trading idle capacity for predictable tail latency.
- A container cannot shrink the cache or reshape the NUMA topology underneath it — those are physical properties the cgroup layer narrows access to, not virtualizes away — and a `--cpuset-cpus` / `--cpuset-mems` mismatch can reintroduce the exact remote-memory penalty a correctly NUMA-aware program was built to avoid.
