---
title: "NUMA, Affinity, and Data Locality"
order: 16
layout: tutorial
sectionid: docs
part: parallelism-and-throughput
description: "CPU pinning and affinity, NUMA-aware allocation, the latency gap between local and remote memory, and how cpuset constraints interact with it."
duration: "15 min"
---

<!-- PROVENANCE: NEW | anchor books: Son, Lim, Tanenbaum -->

## What we'll cover

- Cover setting CPU affinity for a thread with `sched_setaffinity`/`pthread_setaffinity_np`, and why pinning helps or hurts depending on the workload.
- Cover NUMA-aware allocation — `numa_alloc_onnode` and first-touch policy — as placing memory on the node local to the thread that will use it most.
- Quantify the latency gap between local and remote NUMA memory access, and why it compounds with the false-sharing cost from mechanical sympathy.
- Cover how a `cpuset` constrains which NUMA nodes and cores are visible to a process, and the interaction with a container's CPU limit.

[The Machine Underneath]({{ '/docs/02-the-machine-underneath/' | relative_url }}) introduced NUMA as a property of the hardware: a multi-socket server, or a single chip built from several dies, gives every core a fast path to its own local memory bank and a slower one to every other node's. This chapter turns that fact into practice — how to find out which node a thread is running on, how to keep its data on that node, and how to stop the operating system from undoing the work by scheduling the thread somewhere else next time slice.

## CPU Pinning and Affinity

A thread's CPU affinity mask tells the scheduler which cores it's allowed to run on; by default every thread's mask covers the whole machine, and the scheduler is free to migrate it between cores — even between NUMA nodes — whenever load balancing seems to call for it. For most code this default is correct: migration is cheap relative to the work being balanced, and restricting it by hand would just make the scheduler's job harder for no benefit. For a thread whose entire value proposition is low, predictable latency against data it keeps local, an unplanned migration is a direct cost: the thread loses its warm cache the same way any context switch does, and if the migration crosses a NUMA boundary it also loses local access to everything it had allocated as local before the move — the data doesn't move with it, so every access after an inter-node migration pays the remote-latency penalty until the thread either migrates back or its data does.

`pthread_setaffinity_np` sets the mask for a running thread from inside the process; the lower-level `sched_setaffinity` syscall does the same thing and is what `pthread_setaffinity_np` calls underneath. Pinning a thread to a single core removes it from load-balancing consideration entirely — the scheduler simply has nowhere else to put it — and pinning a group of threads to the cores of a single NUMA node keeps every thread in that group one hop from the same local memory, which is usually the actual goal: not "this exact core" so much as "this node, and nowhere else."

Pinning is not free of cost, and getting it wrong is worse than not doing it. A thread pinned to a single core that then blocks on I/O or contends for a lock still has nowhere else to run while it's runnable again, so a pinned thread that isn't actually CPU-bound just reproduces the single-core bottleneck the scheduler's default migration would have otherwise relieved. Pinning two unrelated pinned threads to the same core is a worse version of the same mistake — now they take turns on hardware neither can leave. The workloads that benefit are the ones the scheduler is actively hurting by moving: a tight polling loop, a hot path with a large resident working set that an unplanned migration would evict, or a thread in a pipeline stage whose neighbors are themselves pinned and depend on consistent, repeatable timing from this one. `isolcpus` at boot removes a set of cores from the kernel's normal scheduling rotation entirely, so that even an unrelated process briefly scheduled onto one of them doesn't happen by default — pinning plus isolation together give a hot thread a core the rest of the system has agreed to leave alone.

## NUMA-Aware Allocation and First-Touch

Pinning a thread to a node solves only half the locality problem; the other half is making sure the memory that thread touches is actually on that node, and Linux's default allocation policy makes this easy to get backwards. `malloc` (and `new` underneath it, for allocations large enough to bypass any thread-local cache) reserves virtual address space immediately, but the kernel does not bind a physical page to any NUMA node until that page is first written — this is first-touch allocation, and it is the default policy on every mainstream Linux distribution. The thread that writes to a page first determines which node's physical memory backs it, regardless of which thread allocated it and regardless of which thread does the bulk of the reading and writing afterward.

This produces a specific, common bug shape: a startup routine on the main thread allocates a large buffer and zero-initializes it in a loop — a perfectly reasonable thing to do, and exactly the operation that binds every page to the main thread's node — and then the buffer is handed off to worker threads pinned across several nodes to process in parallel. Every worker not on the main thread's node now pays the remote-access penalty on every single touch of that buffer, for the buffer's entire lifetime, and nothing in the source code suggests why: there's no visible allocation call on the wrong node, just an initialization loop that ran before anyone had decided which thread should own which memory.

The fix takes one of two forms. The explicit one is `numa_alloc_onnode` from `libnuma`, which allocates memory bound to a specific node immediately, bypassing first-touch policy altogether — correct when the target node is known at allocation time and doesn't depend on which thread happens to run first. The implicit one, often simpler in a worker-pool shape, is to have each worker thread allocate and initialize its own slice of a larger logical buffer, so that first-touch does the right thing by construction: the thread that will use a given piece of memory is also the thread that first wrote to it, and the kernel's default policy places the memory correctly without `libnuma` ever being called. `numa_alloc_interleaved` is the right choice for the opposite case — a buffer genuinely shared and read roughly equally from every node, where no single node should bear the full remote-access cost for everyone else's reads, and interleaving pages round-robin across nodes spreads that cost evenly instead of concentrating it anywhere.

{% include excalidraw.html name="16-first-touch-misplacement" caption="Figure 16.1 — first-touch allocation binds a buffer to the initializing thread's node; workers on other nodes pay the remote-latency penalty on every access for the buffer's lifetime" %}
<!-- DIAGRAM SPEC: Two NUMA node boxes side by side (Node 0 blue #4a73b8, Node 1 green #5a8870), each with a local DRAM box beneath it. A "Main thread" icon sits in Node 0 with an arrow labeled "malloc + init loop (first touch)" pointing into Node 0's DRAM box, which is drawn full (shaded) to show the buffer physically lives there. A "Worker thread" icon sits in Node 1 with a long red #c0392b arrow crossing the gap between the two node boxes (labeled "cross-node interconnect, ~30-60% higher latency") reaching into Node 0's DRAM box, captioned "every access, for the life of the buffer." Below, a second smaller diagram shows the fix: each worker (one icon per node) with a short local arrow (orange #a06030) into its own node's DRAM box, labeled "each worker touches its own slice first." -->

## Local vs Remote Memory Latency

The latency gap first-touch placement either avoids or guarantees is not a minor tax. `numactl --hardware` reports a relative distance matrix between nodes — a node's distance to itself is conventionally 10, and the distance to a remote node on current multi-socket platforms commonly falls in the low-to-mid 20s — and that ratio is a reasonable proxy for the real latency gap: a remote access routinely costs on the order of 30 to 60 percent more than a local one, with the exact figure depending on the platform, the interconnect generation (Intel's UPI, AMD's Infinity Fabric), and how many hops separate the requesting core from the owning node on larger multi-die or multi-socket topologies. Published numbers vary enough across hardware generations that a specific figure for any one platform is worth measuring, not assuming; the direction and rough magnitude of the gap are the portable facts.

What makes the gap worse in practice than the raw latency ratio suggests is that it compounds with the cache-coherence cost [Mechanical Sympathy]({{ '/docs/20-mechanical-sympathy/' | relative_url }}) covers under false sharing. A cache line bounced between cores on the same node pays a coherence cost measured in tens of cycles; the same bounce between cores on different nodes pays the coherence cost and the cross-node interconnect latency together, because invalidating a remote core's cached copy of a line is itself a message that has to cross the same interconnect a remote memory read would. Two threads on different NUMA nodes false-sharing a cache line are doing the single most expensive thing this chapter and that one each describe separately, at the same time, and the fix for each half of the problem — padding to separate the cache lines, and pinning plus local allocation to keep nodes out of the picture — is additive: either one alone helps, and applying both is what actually closes the gap.

## cpuset and Container Interactions

A `cpuset` is the cgroup controller that restricts which cores (`cpuset.cpus`) and which NUMA nodes' memory (`cpuset.mems`) are visible to a process at all — distinct from, and orthogonal to, the CPU quota mechanism [Thread Pools and Work Scheduling]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}) reads from `cpu.max`. A quota limits how much CPU *time* a cgroup may consume per period, on whatever cores the scheduler picks; a cpuset limits which cores and nodes are visible as options at all, independent of how much of them get used. A process can be quota-limited to two cores' worth of time while its cpuset still spans every core and every node on an eight-socket machine, or pinned by cpuset to two specific cores on one specific node with no quota limiting how much of those two cores it may use.

Both halves matter for NUMA work, and they have to agree with each other to get a coherent result. `cpuset.cpus` restricting a container to cores on node 0 while `cpuset.mems` leaves all nodes available for allocation reintroduces exactly the remote-access penalty this chapter spent two sections eliminating — the container's threads run on node 0, but a first-touch allocation under memory pressure can still land on node 1's physical pages, because nothing told the kernel to prefer node 0 for this cgroup's memory. The orchestrator-level knobs matter here more than in the quota case: Kubernetes' CPU Manager with the `static` policy can assign exclusive, NUMA-aligned cores to a pod, and the companion Memory Manager with the `Static` policy pins that same pod's memory to the same node — the two have to be configured together, the same way `cpuset.cpus` and `cpuset.mems` have to be set consistently by hand, because either one set alone leaves half of the locality story unenforced. A process inside a cpuset-restricted container can call `numa_alloc_onnode` for a node the cpuset doesn't include; the call does not fail loudly, it silently falls back to an allowed node, which is a second, quieter way the same misconfiguration shows up.

## Running in a container

The runnable example for this chapter (`examples/concurrency/16-numa-affinity-and-data-locality/`) provisions a disposable KVM guest with a two-NUMA-node topology and runs a benchmark there that demonstrates each mechanism above: `numa_alloc_onnode` placing a buffer's pages on the requested node, first-touch binding a plain allocation to the node of the thread that writes it first, and — in a second run confined to a `cpuset` whose `cpuset.mems` excludes the requested node — `numa_alloc_onnode` silently falling back to an allowed node. The example runs exclusively in the KVM lab so that host NUMA layout, CPU governor, and `isolcpus` are never modified on the physical machine; `verify.lua` asserts the placement and fallback behaviors, each confirmed by reading back the actual node of every page with `get_mempolicy`.

One honest caveat the example states in its own output: when the host underneath the lab has a single physical NUMA node, the guest's two nodes are *emulated* — the guest reports two nodes and a distance matrix, and placement works correctly, but the remote-memory *latency* penalty is not reproduced, because the emulated nodes are backed by the same physical memory. The placement and `cpuset` mechanisms this chapter teaches are real and verified on that emulated topology; the local-versus-remote latency gap is reported as a soft measurement that only becomes the figures quoted above on genuinely multi-socket hardware.

This chapter's material does not run reliably in an ordinary container the way a CPU-quota benchmark does, and that limitation is itself worth stating plainly rather than working around. A container on a single-node machine has no second node to be remote from, no matter how carefully `cpuset.mems` is configured, and a container on a genuinely multi-node host usually shares that host with other tenants whose own placement decisions are invisible to it — a "local" benchmark result measured under those conditions is not trustworthy, because another container's memory traffic on the same node can dominate the measurement without appearing anywhere in the one being profiled. What a container *can* demonstrate correctly is the cpuset mismatch failure mode from the previous section: setting `cpuset.cpus` and `cpuset.mems` inconsistently and observing that `numa_alloc_onnode` for an excluded node silently falls back rather than failing, which needs only the cgroup controller to be present, not a real multi-node machine underneath it.

Real local-versus-remote latency measurement, and real pinning-and-isolation behavior, need a real NUMA topology and real control over `isolcpus` and CPU governor settings — exactly the two things a shared host and a production container runtime must not have touched out from under them. The example above runs in the disposable KVM lab (`lgtm-systems-programming`) for that reason: a VM provisioned for this purpose can have its vCPU topology, memory, and scheduling isolation configured deliberately, torn down afterward, and never risk mutating the actual machine the lab is running on. No host-level NUMA, governor, or `isolcpus` setting should ever be changed to run this chapter's material — the lab VM is the only place those knobs move.

## Standards: C++20 / C++23 / C++26

The standard library has no NUMA concept at any of these three revisions — node topology, `numa_alloc_onnode`, and `cpuset` are all platform-specific (`libnuma` and Linux syscalls), and nothing in `std::thread`, `std::jthread`, or the allocator model names a NUMA node. What has changed across C++20/23/26 is the vocabulary available for expressing hardware-topology-aware *intent* once the underlying placement is done through platform APIs.

C++20 added `std::hardware_destructive_interference_size`, which [Mechanical Sympathy]({{ '/docs/20-mechanical-sympathy/' | relative_url }}) uses directly for same-node false-sharing avoidance, and `std::jthread`, whose native handle (`.native_handle()`) is still the only portable-from-C++ path to call `pthread_setaffinity_np` underneath — the standard gives a thread a cooperative-cancellation-aware wrapper but no native affinity API of its own. C++23 and C++26 do not add a NUMA-aware allocator or an affinity API either; C++26's `std::execution` (covered in the previous chapter) defines schedulers and execution contexts abstractly enough that a NUMA-aware scheduler could in principle be built against the model, but no proposal has standardized node-aware scheduling itself, and no shipping library does this through the sender/receiver model today. The three fenced blocks below show the identical pattern at each standard not because the API changed, but because it's worth being explicit that it didn't: pinning and NUMA placement are reached through `native_handle()` plus a platform call in C++20, C++23, and C++26 alike.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// jthread's native_handle() is the only portable-from-C++ path to pthread
// affinity calls; the standard has no affinity API of its own.
void pin_to_node0(std::jthread& t, int core_in_node0) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(core_in_node0, &set);
    ::pthread_setaffinity_np(t.native_handle(), sizeof(set), &set);
}

void* alloc_local(std::size_t bytes, int node) {
    return numa_alloc_onnode(bytes, node);  // libnuma, not the standard library
}
```

```cpp
// C++23
// Same native_handle() + libnuma pattern. No new standard affinity or
// NUMA facility exists in this revision.
void pin_to_node0(std::jthread& t, int core_in_node0) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(core_in_node0, &set);
    ::pthread_setaffinity_np(t.native_handle(), sizeof(set), &set);
}

void* alloc_local(std::size_t bytes, int node) {
    return numa_alloc_onnode(bytes, node);
}
```

```cpp
// C++26
// Still native_handle() + libnuma. std::execution's schedulers (prior
// chapter) could host a NUMA-aware scheduler in principle, but no such
// scheduler is standardized or shipping as of this writing.
void pin_to_node0(std::jthread& t, int core_in_node0) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(core_in_node0, &set);
    ::pthread_setaffinity_np(t.native_handle(), sizeof(set), &set);
}

void* alloc_local(std::size_t bytes, int node) {
    return numa_alloc_onnode(bytes, node);
}
```

## What we learned

Affinity and NUMA placement are two halves of the same locality problem: pinning a thread without also controlling where its memory lands leaves first-touch to place that memory wherever it happens to be initialized, and placing memory on the right node without pinning the thread leaves the scheduler free to migrate the thread away from it. `sched_setaffinity`/`pthread_setaffinity_np` (reached, in standard C++, through a `jthread`'s `native_handle()`) solve the first half; `numa_alloc_onnode`, or simply letting each worker first-touch its own slice of shared memory, solve the second. The latency gap between a local and a remote access is real, platform-dependent, and compounds with same-line cache-coherence cost when a false-shared line also happens to cross a NUMA boundary. A `cpuset`'s `cpuset.cpus` and `cpuset.mems` have to be configured together — one constrains cores, the other constrains memory nodes, and setting only one reintroduces the remote-access penalty through the half left unconstrained. None of this is reliably observable inside an ordinary container; it needs a real multi-node machine, which is exactly why this chapter's example runs in a disposable KVM lab rather than against host hardware that has to stay untouched.
