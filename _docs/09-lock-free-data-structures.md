---
title: "Lock-Free Data Structures"
order: 9
layout: tutorial
sectionid: docs
part: shared-state-and-synchronization
description: "Single- and multi-producer/consumer ring buffers, the ABA problem, hazard pointers, RCU, and C++26's standardized reclamation support."
duration: "16 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/26-atomics-and-lock-free.md (lock-free portion) | anchor books: Williams ch7, Son -->

## What we'll cover

- Build a single-producer/single-consumer (SPSC) ring buffer, then identify exactly what breaks when it's generalized toward multi-producer/multi-consumer (MPMC).
- Explain the ABA problem concretely on a compare-and-swap-based stack, and why SPSC's design sidesteps it structurally rather than by careful coding.
- Cover hazard pointers and RCU (read-copy-update) as the two dominant strategies for reclaiming memory a lock-free structure's nodes occupy, and the trade-off between them.
- Preview C++26's `std::hazard_pointer` and `std::rcu`, labeled experimental, against the hand-rolled versions they standardize.

This chapter assumes [Chapter 8]({{ '/docs/08-atomics-and-the-memory-model/' | relative_url }})'s vocabulary without re-deriving it: `std::atomic`, the `memory_order` options, and what acquire/release actually establishes between two threads. What's new here is structure: what a lock-free *data structure*, as opposed to a single atomic hand-off, has to additionally solve, specifically the question of when it's safe to free a node that a concurrent reader might still be dereferencing.

## SPSC and MPMC Ring Buffers

A lock, as covered in [Chapter 6]({{ '/docs/06-mutual-exclusion-and-locking/' | relative_url }}), is a promise that exactly one thread runs a critical section at a time — correct, general, and never free. A lock-free ring buffer drops that promise entirely for the one shape of problem where it's possible to do so safely with almost no machinery: a single producer and a single consumer moving values through a bounded buffer.

The structure is two monotonically increasing counters, `tail` (items pushed) and `head` (items popped), and a backing array. The physical slot for logical position `p` is `buf[p % capacity]`; occupancy is `tail - head`; the ring is full when `tail - head == capacity` and empty when `head == tail`. The property that makes this safe without a lock is **one writer per counter**: the producer writes `tail` and only reads `head`; the consumer writes `head` and only reads `tail`. No location is ever written by two threads, so there's no write-write race for anything to arbitrate.

```cpp
// Producer: push values 0..items-1.
std::uint64_t t = 0;
for (std::uint64_t i = 0; i < items; ++i) {
    while (t - head.load(std::memory_order_acquire) == capacity) {
        // spin: ring full
    }
    buf[t % capacity] = i;
    ++t;
    tail.store(t, std::memory_order_release);
}

// Consumer, concurrently:
std::uint64_t h = 0;
std::uint64_t sum = 0;
for (std::uint64_t i = 0; i < items; ++i) {
    while (h == tail.load(std::memory_order_acquire)) {
        // spin: ring empty
    }
    sum += buf[h % capacity];
    ++h;
    head.store(h, std::memory_order_release);
}
```

The release store on `tail` publishes the slot write that precedes it, exactly as in Chapter 8's producer/consumer example; this is that example turned into a persistent, reusable structure rather than a single hand-off.

<!-- EXAMPLE SPEC: examples/concurrency/09-lock-free-data-structures/ implements the SPSC ring above with a --pad on|off flag controlling whether head and tail share a cache line, and a --capacity flag down to 1 (maximum contention); it pushes a known range of values and sums them on the consumer side; verified by a Lua verify.lua asserting the summed total always matches the closed-form expected sum (0+1+...+N-1) across both --pad settings and several capacities including 1, built via lgtm-docker-stack with taskset-pinned variants for the false-sharing comparison. -->
The example at `examples/concurrency/09-lock-free-data-structures/` builds this ring with a `--pad` flag for the cache-line experiment in the container section below.

Moving from SPSC to MPMC (multiple producers, multiple consumers) breaks the one-writer-per-counter property at its root: `tail` now has multiple writers, each needing to claim a distinct slot before writing it, and `head` likewise. A single `tail.store()` no longer suffices, because two producers racing to increment `tail` could both read the same old value and compute the same slot. The standard fix is a compare-and-swap loop — each producer reads the current `tail`, computes `tail + 1`, and attempts `compare_exchange_weak(tail, tail + 1)`, retrying on failure. That reintroduces exactly the hazard SPSC avoided by construction: a value read, acted on later, and compared against a location that may have changed in between.

## The ABA Problem

ABA is the name for what goes wrong when a compare-and-swap succeeds against a value that is numerically identical to what was read earlier but is not, semantically, the same state. The canonical case is a lock-free stack implemented as a singly linked list with an atomic `head` pointer, popped with CAS:

```cpp
Node* old_head = head.load();
Node* new_head;
do {
    if (!old_head) return std::nullopt;
    new_head = old_head->next;     // read before the CAS
} while (!head.compare_exchange_weak(old_head, new_head));
```

Suppose thread T1 reads `old_head = A` and `new_head = A->next`, then is preempted before the `compare_exchange_weak`. While T1 is suspended, thread T2 pops `A`, pops the node after it, frees `A`, pushes a freshly allocated node that happens to land at the same address as the freed `A` (a common allocator behavior — a just-freed block is often the next one handed out), and pushes it back onto the stack. When T1 resumes, `head` is once again `A`, numerically identical to what T1 read — so the CAS succeeds. But `A->next`, the `new_head` T1 computed before being preempted, points to a node T2 already popped and possibly freed; the stack is now corrupted, pointing into memory that may no longer even belong to the structure. The CAS did exactly what it was asked: it compared `head` against `old_head` and found them equal. The equality was real but the state it certified was not — the location went `A → B → A`, and nothing about a bare pointer comparison can distinguish the second `A` from the first.

A plain CAS has no way to detect this because it compares a value, not a history. Two mitigations are standard. A **tagged pointer** (or "ABA counter") pairs the pointer with a monotonically incrementing generation count in a single CAS-able word (using the double-width `compare_exchange` some platforms support, or stealing unused high bits on a 64-bit pointer), so that even if the pointer bits recur, the tag has advanced and the CAS fails. A **hazard pointer** or **RCU** scheme sidesteps the problem differently — not by detecting reuse, but by preventing the memory from being reused (or freed) at all while any thread might still be dereferencing it.

SPSC's ring buffer never faces this because its counters are monotonic for the life of the run and there is no CAS anywhere in it — each counter has exactly one writer that unconditionally stores the next value. No `tail` or `head` value ever recurs, so there is no reused value for a comparison to be fooled by. That's why SPSC is the structural foundation the rest of lock-free programming sits on: the moment a second writer is added to a shared location, CAS becomes necessary, and CAS reopens ABA and the reclamation problem that follows from it.

{% include excalidraw.html name="09-aba-problem" caption="Figure 9.1 — the ABA problem on a lock-free stack: T1 reads head=A and computes new_head=A->next, is preempted, T2 pops A and B and pushes a new node that reuses address A, and T1's CAS succeeds against a head value that is numerically A but semantically a different stack" %}
<!-- DIAGRAM SPEC: cream #fdfbf7 background, a timeline with two thread lanes, T1 (blue #4a73b8) and T2 (green #5a8870), against a shared "head pointer" box at the top. T1 lane: box "read head=A", box "compute new_head = A->next", then a red #c0392b dashed "PREEMPTED" bar. During the dashed bar, T2 lane runs three boxes in sequence: "pop A (head=B)", "pop B (head=C), free A", "push new node at reused address A (head=A)" — with an orange #a06030 annotation "allocator reuses freed address A". After the dashed bar, T1 lane resumes: box "CAS(head, A, new_head) — succeeds!" with a red arrow pointing back up to the shared head box labeled "numerically A, semantically a different stack" and a final red box "corruption: new_head points into memory T2 already freed/reused". -->

## Hazard Pointers and RCU

Both schemes solve the same problem by different means: a thread must never free a node another thread might still be dereferencing.

**Hazard pointers** work per-reader. Before dereferencing a shared pointer, a thread publishes that pointer into a well-known per-thread "hazard" slot other threads can inspect. A thread that wants to reclaim a node first scans every other thread's hazard slots; if the node's address appears in any of them, reclamation is deferred (the node goes onto a retire list and is rechecked later) rather than freed immediately. The cost is paid on every read — publishing to the hazard slot, typically with a `release` store, and the scan cost paid by whichever thread performs reclamation, proportional to the number of active readers. The benefit is that memory is reclaimed promptly once no hazard pointer references it, which bounds how much retired-but-unfreed memory can accumulate.

**RCU** (read-copy-update) moves the cost to the write side instead. A reader that wants to traverse a lock-free structure does so inside a read-side critical section (conceptually: "I might be looking at old data, and that's fine") with no per-read publication cost at all — on Linux, the userspace analog of this is as cheap as a compiler barrier. A writer that wants to remove a node does not free it immediately; it unlinks the node from the structure (so new readers never see it) and then waits for a **grace period** before reclaiming it — the guarantee that every reader active at the time of unlinking has since exited its read-side critical section. Old readers that started before the unlink may continue to see the old version for the duration of their traversal; that's the "read-copy" trade RCU makes explicitly, rather than blocking them.

The trade-off is a straight read-cost/write-cost swap. Hazard pointers pay on every read (a published pointer, a memory barrier) to keep reclamation prompt; RCU pays on every delete (tracking a grace period, which typically means waiting for a quiescent state across all participating threads) to keep reads essentially free. Workloads dominated by reads with infrequent structural mutation (a routing table, a configuration snapshot, a lookup cache on a hot path) favor RCU, since that's the access pattern it was designed to make nearly free. A structure updated and read at comparable rates, or with latency-sensitive deletes that can't tolerate an unbounded grace-period wait, favors hazard pointers' more predictable per-operation cost instead.

## C++26 hazard_ptr and rcu

C++26 is expected to standardize both strategies directly as `std::hazard_pointer` and `std::rcu`, removing the need to hand-roll either from `std::atomic` primitives in every project that needs lock-free reclamation.

<span class="status status--unverified">experimental — no shipping compiler currently implements either facility; the interface sketched below reflects the proposal shape (P2530 for hazard_pointer, P2545/P2545R4 for the rcu family) at the time of writing and may still change before (or if) it ships.</span>

```cpp
// C++26 (proposed, unimplemented in shipping compilers):
// hazard_pointer usage sketch — protect a node before dereferencing it.
std::hazard_pointer hp = std::make_hazard_pointer();
Node* node = hp.protect(shared_atomic_ptr);
if (node) {
    use(*node);   // safe: hp guarantees node isn't reclaimed while protected
}
// hp's destructor (or explicit reset_protection()) releases the guard.
```

```cpp
// C++26 (proposed, unimplemented in shipping compilers):
// rcu usage sketch — a read-side critical section and a writer's retire.
{
    std::rcu_domain& domain = std::rcu_default_domain();
    auto guard = std::rcu_read_lock(domain);   // read-side critical section
    Node* node = shared_atomic_ptr.load(std::memory_order_acquire);
    use(*node);
}  // guard destructor ends the read-side section

// Writer, elsewhere:
std::rcu_synchronize(domain);   // blocks until a grace period has elapsed
delete old_node;                // now provably safe to reclaim
```

Both map directly onto the hand-rolled patterns above: `std::hazard_pointer::protect` is the publish-to-a-well-known-slot step a hand-rolled hazard scheme implements with a plain `std::atomic<void*>` array and a scan function; `std::rcu_synchronize` is the grace-period wait a hand-rolled RCU implements with a reader-count or epoch scheme. Standardizing them mainly removes the substantial chance of a subtly wrong hand-rolled reclamation scheme, rather than introducing new algorithmic capability — a hazard pointer scan that misses a published slot due to an ordering bug, or an RCU grace-period wait that doesn't actually guarantee every prior reader has exited, is the kind of bug that standardization is meant to close off. Until a compiler ships these, the hand-rolled versions remain the only option in production code, and the trade-off analysis in the previous section applies equally to both.

## Running in a container

A ring buffer's throughput is a direct function of core placement, which a container affects through both cgroup CPU limits and the default scheduling domain. The clearest effect to reproduce is false sharing: if `head` and `tail` sit in the same 64-byte cache line (the default, unpadded layout), the consumer's store to `head` invalidates the producer's cached copy of the entire line, `tail` included, even though the producer never touches `head`; the line ping-pongs between whichever two cores the container scheduler happens to place the threads on. Padding each counter to its own cache line with `alignas(64)` removes the false-sharing path entirely, independent of core placement. Measuring the difference meaningfully requires pinning: `taskset -c 0,2 ./ring_bench --pad off` against `--pad on`, run inside a container with at least two CPUs available (`--cpus=2` or more, and `--cpuset-cpus=0,2` to control which physical cores are offered), isolates the cache-line effect from whatever the container's default CFS scheduling would otherwise introduce as noise. On a one-slot ring (the tightest possible hand-off, forcing lockstep between producer and consumer), expect padding to show a meaningfully higher throughput than the unpadded layout — false sharing on a ping-ponging cache line is expensive enough that eliminating it typically moves the needle by tens of percent, not a few — with `perf stat -e L1-dcache-load-misses` showing a clear split between the padded and unpadded runs once the runnable example (and the Chapter 20 benchmark) actually measures it on real hardware.

## Standards: C++20 / C++23 / C++26

{% include codetabs.html langs="C++20|C++23|C++26" %}
```cpp
// C++20: no standardized lock-free reclamation facility. Hazard pointers
// and RCU are hand-rolled on top of std::atomic, typically as a
// per-thread array of std::atomic<void*> (hazard pointers) or a manually
// tracked reader-epoch counter (RCU-style), both covered above.
std::atomic<void*> hazard_slots[MAX_THREADS];
```
```cpp
// C++23: std::atomic_ref and the wait()/notify() additions from Chapter 8
// make a hand-rolled hazard-pointer scan slightly cheaper to express (a
// scan loop can wait on a published-count atomic instead of spinning) but
// introduce no reclamation facility of their own.
std::atomic<int> active_readers{0};
active_readers.wait(0);   // no reclamation semantics, just a cheaper spin
```
```cpp
// C++26 (proposed, experimental — see the labeled section above):
// std::hazard_pointer and std::rcu standardize the two patterns directly.
std::hazard_pointer hp = std::make_hazard_pointer();
```

Beyond reclamation, C++20 introduced `std::atomic<std::shared_ptr<T>>` partial specializations, which give atomic load/store/compare_exchange on a `shared_ptr` without the lock-based emulation earlier standard libraries used internally — relevant to lock-free structures that hold `shared_ptr` nodes, though the reference-count increment/decrement itself is not the publication problem hazard pointers and RCU solve; it addresses ownership, not visibility. No change to this facility shipped in C++23, and C++26's reclamation additions are independent of it — a structure can combine `atomic<shared_ptr<T>>` for ownership with `hazard_pointer` for safe dereferencing, or use neither and manage raw nodes with manual reclamation.

## What we learned

- SPSC is safe without a lock because each counter has exactly one writer; moving to MPMC reintroduces compare-and-swap on both `head` and `tail`, which reopens the ABA problem SPSC's monotonic, single-writer counters sidestep structurally.
- ABA is a CAS comparing a value, not a history: a location that cycles `A → B → A` between a thread's read and its CAS makes the CAS succeed against state that is numerically identical but semantically stale, corrupting the structure despite a passing compare.
- Hazard pointers and RCU both solve safe reclamation (never freeing a node a concurrent reader might still dereference) but on opposite sides of the cost ledger: hazard pointers pay per read to keep reclamation prompt, RCU pays per delete (a grace-period wait) to keep reads nearly free.
- C++26's `std::hazard_pointer` and `std::rcu` standardize both patterns but ship in no current compiler; treat them as the eventual replacement for hand-rolled reclamation, not as something to depend on in code shipping today.

This closes the shared-state and synchronization sequence: locks ([Chapter 6]({{ '/docs/06-mutual-exclusion-and-locking/' | relative_url }})), coordination ([Chapter 7]({{ '/docs/07-coordination-primitives/' | relative_url }})), the memory model ([Chapter 8]({{ '/docs/08-atomics-and-the-memory-model/' | relative_url }})), and lock-free structures built on top of it. Next, **tasks, futures, and async** picks up composition: expressing work as values rather than threads.
