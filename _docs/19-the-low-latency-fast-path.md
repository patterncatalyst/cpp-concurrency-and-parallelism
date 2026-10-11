---
title: "The Low-Latency Fast Path"
order: 19
layout: tutorial
sectionid: docs
part: low-latency-and-high-throughput
description: "Three concrete moves that shrink tail latency: core pinning, buffer reuse, and zero allocation, the busy-poll versus block decision, keeping syscalls and branches off the hot path, and where kernel bypass fits."
duration: "16 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/40-low-latency-fastpath.md | anchor books: Son, Lim -->

## What we'll cover

- Cover three concrete moves that shrink the latency tail: pin a core, reuse one buffer, and allocate nothing on the hot path.
- Show why a pinned core's reported count can lie once it's inside a constrained container.
- Compare busy-polling (spend a whole core to avoid the scheduler round trip) against blocking and waking.
- Keep syscalls, locks, and unpredictable branches off the path once the three big moves are in place.
- Note where kernel-bypass networking fits into the fast-path picture, without turning into a networking-stack tutorial.

[Benchmarking Without Deception]({{ '/docs/18-benchmarking-without-deception/' | relative_url }}) built the discipline for trusting a `p99`. This chapter spends that discipline on the harder question — once a `p99` can be trusted, how is it made small? The answer on Linux is a short, specific list of moves, each targeted at removing one concrete source of the multi-microsecond stalls the previous chapter's corrected percentile exists to surface.

## Three Moves That Shrink the Tail

Every technique below targets a specific line item in a latency budget, and each is worthless — or harmful — applied without a reason. Naming them up front:

- **Pin to one CPU** (`sched_setaffinity`). A thread the scheduler is free to migrate can be moved, between one message and the next, onto a core that first has to be brought back up from a low power state and whose caches hold none of its working set. That migration is itself a tail-latency event. Pinning trades the ability to flee a noisy neighbor for removing migration as a jitter source — right for a dedicated latency-critical thread, wrong for a general-purpose worker pool that benefits from load balancing.
- **Reuse one buffer** (zero heap allocation in the loop). A hot path that reads every incoming message into a freshly allocated buffer pays an allocator cost that is small on average but variable: most calls hit a thread-local fast path and return in tens of nanoseconds, while the occasional call that takes the arena lock or faults in a fresh page does not, and that variance lands squarely in the tail a benchmark reports.
- **Busy-poll** (spin on a non-blocking read instead of blocking). A blocking read on an idle socket puts the thread to sleep; when data arrives, the kernel has to wake it — a scheduler round trip, a voluntary context switch, on every message. Busy-polling never sleeps: it spins on a non-blocking call until data is there, trading an entire core for eliminating the sleep/wake round trip. This is the most expensive of the three and, on a quiet system, has the largest single effect on median latency.

None of the three is free: a fast path is not "the code with no cost," it is the code whose cost has been moved somewhere predictable and paid for on purpose, rather than somewhere the scheduler, allocator, or kernel wakeup path chooses for it.

## Pinning a Core

`sched_setaffinity` installs a CPU affinity mask for a thread; with a single bit set, the scheduler has nowhere else to place that thread and migration stops being possible rather than merely unlikely. Reached from standard C++, the call needs a native handle: `std::jthread::native_handle()` hands back the underlying `pthread_t`, which `pthread_setaffinity_np` then accepts directly. The standard library gives a thread cooperative cancellation through `jthread` and `stop_token`, but no portable affinity API of its own — every pinning call in C++, at every standard this chapter covers, goes through this same native-handle detour.

Validating the CPU index before pinning needs an accurate count of CPUs available to the process, and this is where a careless implementation quietly breaks under a container or an external affinity restriction. `sysconf(_SC_NPROCESSORS_ONLN)` reports CPUs online system-wide and ignores whatever affinity mask already constrains the calling process — the number this chapter's range check actually wants, since the CPU index being validated is an absolute index into the whole system's core list. A count that instead reflected the current affinity mask would reject a valid pin target the moment something upstream (a container's cpuset, an orchestrator's static CPU-manager policy, `taskset`) had already narrowed the mask — the same shape of bug as `hardware_concurrency()` reading a cgroup quota instead of the host's actual core count, reached through a different door.

Pinning is not free, and getting it wrong is worse than skipping it. A thread pinned to a single core that then blocks on a lock or waits on I/O has nowhere else to run once runnable again, so pinning a thread that is not actually CPU-bound just reproduces the bottleneck the scheduler's default migration would otherwise relieve. The workloads that benefit are the ones the scheduler actively hurts by moving: a tight polling loop, a hot path with a resident working set a migration would evict, or a pipeline stage whose pinned neighbors depend on this one holding steady timing. `isolcpus` configured at boot removes cores from the kernel's normal scheduling rotation entirely, so an unrelated process briefly scheduled onto one of them does not happen by default — pinning plus isolation give a latency-critical thread a core the rest of the system has agreed to leave alone.

<!-- DIAGRAM SPEC: Two horizontal lanes on a cream #fdfbf7 background, each showing one round trip through a server. Top lane labeled "unpinned, heap-allocating, blocking": a message icon arrives at a server box shown floating above a row of four small CPU icons with a dashed outline (meaning "could run on any of them"), an arrow labeled "heap alloc" loops out to a small heap icon and back, then a red #c0392b arrow labeled "blocking read -> sleep" loops down into a "kernel scheduler" box and back up labeled "wake (voluntary ctx switch)". Bottom lane labeled "pinned, buffer reuse, busy-poll": the server box sits fixed over one shaded blue #4a73b8 CPU icon (solid outline, the others greyed out), a short green #5a8870 arrow labeled "reused stack buffer" loops to a small fixed buffer icon and back with no heap icon present, and an orange #a06030 spin arrow loops directly on the server box labeled "busy-poll recv (EAGAIN) — never enters the scheduler". Caption beneath: "same round trip, same frame — the difference is who the thread has to ask for its CPU back." -->
{% include excalidraw.html name="19-fastpath-datapath" caption="Figure 19.1 — one round trip two ways: an unpinned, heap-allocating, blocking path against a pinned, buffer-reusing, busy-polling one" %}

## Zero-Allocation Hot Paths

The fix for allocator variance is structural: decide, before the loop starts, exactly how much memory a single iteration needs, allocate it once, and reuse it for the life of the connection. A fixed-size wire frame read into a stack array needs no allocation at all; a variable-size payload bounded by a known maximum can use a pre-sized buffer reused across iterations, tracking how much of it is live rather than resizing or allocating fresh per message. The allocator does its job well on average — the point is that "well on average" is the wrong property for a path whose purpose is a predictable worst case.

This generalizes past the obvious case of an inbound buffer. Any container growth on the hot path — a `std::vector` reallocating because capacity wasn't reserved up front, a `std::string` built incrementally instead of written into a fixed buffer — reintroduces the same variable cost less visibly. `reserve()` ahead of the loop, or a fixed-capacity container that cannot grow at all, closes that door at compile time rather than relying on every call site remembering not to trigger a reallocation.

## Busy-Poll vs Block

A blocking read puts a thread to sleep when no data is available and relies on the kernel to wake it once some arrives; that wakeup is a scheduler round trip, counted as a voluntary context switch, on every message a blocking loop receives. Busy-polling replaces the blocking call with a non-blocking one wrapped in a spin: the thread calls the non-blocking read, gets `EAGAIN` when nothing is ready, and calls it again immediately, burning its pinned core to stay ready the instant data lands. The payoff: the very next read after data arrives returns it with no wakeup latency, because there was never a sleep to wake up from.

The trade-off is blunt: busy-polling spends a whole core continuously, whether or not there is anything to do. It is the right choice for a dedicated thread with cores to spare and a latency requirement tight enough that a scheduler round trip — commonly a few microseconds on a contemporary Linux kernel, depending on the host and wakeup path — is unacceptable. It is the wrong choice for a general worker sharing a core with other work, where burning 100% of a core to shave microseconds off an occasional message loses more throughput than it saves latency. A hybrid is common in practice: spin for a short bounded window after the last message, then fall back to blocking, trading a little latency on the rare idle-to-busy transition for not permanently dedicating a core to a mostly idle path.

## Syscalls, Locks, and Branches on the Path

Once pinning, buffer reuse, and the busy-poll decision are settled, the remaining tail-latency sources are smaller but still real. A syscall is a mode transition whose cost, while far smaller than a scheduler sleep/wake round trip, is still non-zero and not fully predictable, since the kernel path it takes can itself be interrupted or delayed. A hot path should make as few syscalls per iteration as the protocol allows — batching reads or writes where the API permits it, and computing locally anything that doesn't strictly need a fresh syscall per message.

Locks are the more serious problem, not because mutex acquisition is expensive in the uncontended case — it is not — but because a lock introduces the possibility of blocking on another thread's schedule, which is precisely the kind of externally-imposed, unpredictable delay a fast path exists to eliminate. A single-producer/single-consumer handoff can usually avoid a lock entirely by construction, using two atomics as covered in [Lock-Free Data Structures]({{ '/docs/09-lock-free-data-structures/' | relative_url }}); where a lock is unavoidable, keeping it off the hot path's own thread — handing contended work to a separate thread that is not held to the same latency budget — is often more effective than trying to make the lock itself cheaper.

Branches matter for a subtler reason: a core predicts branches well when their outcome is consistent, and a mispredict costs a pipeline flush of several to a few tens of cycles depending on pipeline depth. A check that is almost always the same outcome predicts well and is close to free; a branch whose outcome varies message to message — dispatching on a message type with no dominant case — is a real, small per-message cost that compounds at high rates. Putting the common case first, or replacing an unpredictable branch with a branchless computation where the logic allows it, is worth reaching for only once pinning, allocation, and blocking behavior are already settled — applying it first optimizes a cost an order of magnitude smaller than the ones still sitting unaddressed.

## Kernel Bypass: When the Fast Path Leaves the Kernel Entirely

Every move so far still goes through the kernel's I/O stack — a `recv` call, however non-blocking, still crosses into the kernel to check for data. Kernel-bypass techniques remove that crossing by mapping a network interface's queues directly into userspace, so a process can poll a ring buffer for incoming packets without a syscall on the data path at all. This eliminates the per-packet kernel transition entirely, the next real tier of latency reduction beyond a busy-poll loop over a kernel socket, and it is why production low-latency trading and some high-frequency networking infrastructure uses it.

The cost is a large jump in operational complexity: the bypassed interface loses ordinary socket tooling and kernel firewall rules, and needs a driver model specific to the bypass framework in use. It also generally commits one or more CPU cores to continuous polling, compounding the busy-poll trade-off at the NIC level. This chapter stops at the boundary: pinning, buffer reuse, and busy-poll over a standard socket cover most latency-sensitive service code without committing to a specialized networking stack, and kernel bypass is the tier to reach for only once that standard path has been measured and found insufficient.

## Running in a container

A container changes what "pin a core" buys in two ways. The first: a narrowed `cpuset.cpus` shrinks the CPU count a correctly-written affinity call sees, while the CFS quota from `cpu.max` does not shrink that count at all — a process can be quota-limited to a fraction of a core's time while every core stays visible, so an affinity-based range check alone doesn't reveal whether the process will get sustained access to the core it pins itself to.

The second is specific to orchestration: under Kubernetes, a pod's threads remain free to migrate across every CPU in its cgroup regardless of in-process `sched_setaffinity` calls, unless the node's CPU manager has been told to treat this pod's cores as exclusive. The `static` CPU Manager policy, requested through Guaranteed-QoS resource requests, is what actually reserves whole cores for a pod — without it, a pin to "CPU 3" targets a number the orchestrator is still free to let other pods' threads run on, reintroducing the noisy-neighbor jitter pinning is meant to remove. A correct deployment needs the orchestrator-level exclusivity and the in-process pin together; either alone is incomplete.

## Standards: C++20 / C++23 / C++26

The three fast-path moves — pinning, buffer reuse, busy-poll — are platform mechanisms with no standard-library equivalent at any of these revisions, reached through `native_handle()` plus POSIX calls identically across C++20, C++23, and C++26. What changes is the vocabulary available for the surrounding code: how a per-message handler is type-erased without allocating, and, prospectively, how a hot-path operation might eventually be expressed against a scheduler abstraction.

C++20's `std::atomic<bool>` `wait`/`notify` pair is relevant mainly as a contrast: it blocks efficiently on a futex without a condition variable's mutex pairing, but it's still a blocking wait with a kernel wakeup — not a substitute for busy-polling, where the wakeup latency itself is the cost being eliminated. C++23 adds `std::move_only_function` (declared in `<functional>`, not `<memory>`) as a type-erased callable that drops `std::function`'s copy-constructibility requirement; a per-message handler owning a move-only resource — a unique buffer, a non-duplicable handle — no longer needs a `shared_ptr` workaround just to satisfy copyability, keeping the handler closer to a zero-overhead abstraction on the hot path. C++26's `std::execution` (senders/receivers) is proposed and experimental, with no shipping compiler implementation as of this writing; it defines schedulers abstractly enough that an affinity-aware scheduler could in principle express "run this on a pinned core" as a composable sender, but no such scheduler is standardized today, and native-handle-plus-POSIX remains the only portable way to pin a thread.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// jthread::native_handle() is the only portable-from-C++ path to the
// POSIX affinity call; the standard has no affinity API of its own.
void pin_to_cpu(std::jthread& t, int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    ::pthread_setaffinity_np(t.native_handle(), sizeof(set), &set);
}

// atomic wait/notify: an efficient blocking wait, NOT a busy-poll
// substitute — still a kernel wakeup, just without a condvar's mutex.
std::atomic<bool> data_ready{false};
void waiting_consumer() {
    data_ready.wait(false);   // parks on a futex until notified
    process_message();
}
```

```cpp
// C++23
// std::move_only_function (<functional>) type-erases a per-message
// handler without requiring it to be copy-constructible, so a handler
// that owns a move-only resource needs no shared_ptr workaround.
std::move_only_function<void(std::span<const std::byte>)> on_message;

void install_handler(std::unique_ptr<Codec> codec) {
    on_message = [codec = std::move(codec)](std::span<const std::byte> frame) {
        codec->decode(frame);
    };
}
```

```cpp
// C++26 (proposed, experimental: std::execution has no shipping compiler
// implementation as of this writing)
void run_on_pinned_core(int cpu) {
    namespace ex = std::execution;
    auto sched = get_affinity_scheduler(cpu);  // hypothetical, not standardized
    ex::sync_wait(ex::schedule(sched) | ex::then([] { hot_path_iteration(); }));
    // The pin itself is still, today, a native_handle() + POSIX call under
    // whatever scheduler ends up implementing this.
}
```

## What we learned

Three moves remove three specific sources of tail latency — pinning removes migration jitter, buffer reuse removes allocator variance, busy-polling removes the scheduler sleep/wake round trip — and each has a real cost: a core that cannot be reclaimed for busy-polling, a thread that cannot flee a noisy neighbor once pinned. Past those three, keeping syscalls, locks, and unpredictable branches off the path closes smaller but measurable gaps, and kernel bypass is the next tier beyond all of it, trading more operational complexity for removing the kernel crossing itself. A CPU count can lie about what a container grants through more than one door — a quota that caps time without shrinking the visible core count, an orchestrator that hasn't been told to make a pin exclusive — and the fix is the same in both cases: ask the kernel or the orchestrator the specific question being asked, not a count never designed to answer it.

[Mechanical Sympathy]({{ '/docs/20-mechanical-sympathy/' | relative_url }}) picks up where buffer reuse leaves off: once a hot path allocates nothing and touches a fixed set of memory on every iteration, the next question is whether that memory's own layout is quietly serializing the threads that share it.
