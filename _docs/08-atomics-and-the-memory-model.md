---
title: "Atomics and the Memory Model"
order: 8
layout: tutorial
sectionid: docs
part: shared-state-and-synchronization
description: "std::atomic, the C++ memory model's ordering options, fences, and the real performance cost of stricter ordering."
duration: "16 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/26-atomics-and-lock-free.md | anchor books: Williams ch5, Grimm -->

## What we'll cover

- What `std::atomic<T>` guarantees beyond ordinary variable access (indivisibility), and what it does not guarantee on its own: ordering.
- The `memory_order` options (`relaxed`, `acquire`, `release`, `acq_rel`, `seq_cst`), each with a minimal example that depends on exactly that ordering and no more.
- Standalone fences, and the narrow set of cases where a fence is the right tool instead of an ordering argument on the atomic operation itself.
- The measured cost difference between relaxed and sequentially consistent ordering on the same workload, and why x86's memory model hides most of it.

Every coordination primitive in the previous chapter is, underneath, built from two things: an atomic operation and a chosen ordering. This chapter is those two things directly. The running example is a single-producer/single-consumer ring buffer — two threads, one producer writing a `tail` counter and one consumer writing a `head` counter, moving values between them with no mutex and no futex, only two atomics and a precise claim about what each thread is allowed to assume the other has seen.

## std::atomic and the Memory Model

`std::atomic<T>` guarantees that a given read or write of `T` happens as one indivisible step: no other thread ever observes a partially written value. On most architectures this is only interesting for types wider than the machine can move in one instruction, or for types without a native atomic instruction at all — on x86-64, a plain `uint64_t` load or store is already atomic in practice, but it is not atomic *by contract*, and the compiler is free to split, reorder, or cache it across calls in ways that would corrupt a concurrently accessed value even though no single instruction tears. `std::atomic` makes indivisibility a guarantee the compiler must preserve rather than an accident of current codegen.

Indivisibility is necessary but not sufficient for a correct hand-off between threads. Consider a producer that writes a value into a slot and then writes a counter signaling the slot is ready:

```cpp
buf[t % cap] = value;      // step 1: write the data
tail.store(t + 1);         // step 2: signal it's ready
```

Even if both `buf[...]` and `tail` are atomic, nothing about program order guarantees the consumer, spinning on `tail`, sees step 1's write before it sees step 2's. Both the compiler and the CPU are free to reorder independent memory operations as long as the reordering is invisible to the thread that performed them — and a thread can never observe its own reordering, by definition. The reordering becomes visible only to a *different* thread watching from another core, which is exactly the situation here. A naive ring built on plain `uint64_t` counters exhibits this as a torn hand-off: the consumer reads `tail`'s new value but the slot it reads still holds stale bytes, and the corruption is intermittent, present on exactly the interleavings nobody's test happened to hit.

What closes that gap is not atomicity but **ordering** — the second, separate guarantee each atomic operation can carry as an argument.

## memory_order: relaxed, acquire, release, seq_cst

Each atomic operation in C++ takes an optional `std::memory_order` argument (default `seq_cst`) that states how much ordering that specific operation provides relative to other memory operations around it.

**Release** on a store says: every ordinary write this thread performed before this store becomes visible to any thread that later *acquires* the value this store produced.

**Acquire** on a load says: every ordinary write the releasing thread performed before its release is now visible to this thread, as of this load.

Paired, release and acquire form a *happens-before* edge between two specific threads at one specific synchronization point — nothing more, nothing less. Applied to the ring buffer:

```cpp
// Producer (writes tail, only reads head)
buf[t % cap] = value;
tail.store(t + 1, std::memory_order_release);   // publishes the slot write

// Consumer (writes head, only reads tail)
while (h == tail.load(std::memory_order_acquire)) { /* spin: empty */ }
auto v = buf[h % cap];                           // sees the published write
```

`tail.store(..., release)` publishes `buf[t % cap] = value`, which precedes it in program order. `tail.load(..., acquire)`, once it observes the new value, is guaranteed to also observe that slot write. The two threads never share a lock; they share exactly one happens-before edge, created once per hand-off.

**Relaxed** promises atomicity (the operation is still indivisible) and nothing about ordering relative to any other memory access. It is correct only when some other synchronization already supplies the ordering a given location needs; in the ring buffer, the slot values themselves (not the counters) can be written and read with `memory_order_relaxed`, because the `tail` release/acquire pair already establishes the edge that makes the slot write visible. This is not a general license: relaxed is a scalpel for a happens-before edge proved present by other means, never a default reached for because the ordering argument is inconvenient to reason about.

**acq_rel** combines both roles on a single read-modify-write operation such as `fetch_add` or `compare_exchange` — the operation acquires the prior value and releases its own write in the same instruction, which is what a lock-free counter increment that must also publish a side effect typically needs.

`compare_exchange_weak` and `compare_exchange_strong` take two separate ordering arguments, one for the success case and one for failure: `compare_exchange_weak(expected, desired, success_order, failure_order)`. The failure order can only be `relaxed`, `acquire`, or `seq_cst`, never `release` or `acq_rel` — a failed compare-and-swap performs no write, so there is nothing for it to release. A common mistake is specifying only one ordering argument and letting the failure order default (it degrades to a non-release version of whatever success order was given), then assuming the failure path got the same acquire semantics as success; for code that needs to observe fresh state specifically on CAS failure (the usual case in a retry loop that rereads `expected`), the failure order needs its own explicit `acquire`.

**Sequential consistency** (`seq_cst`, the default when no ordering is specified) is the strongest: every `seq_cst` operation in the program participates in one single global total order that every thread agrees on. It subsumes acquire/release (a `seq_cst` store is also a release, a `seq_cst` load is also an acquire) and additionally guarantees that if thread A sees thread B's `seq_cst` store before its own, no thread C can see the opposite order. That global-order guarantee is strictly more than the ring buffer needs: acquire/release on `tail` and `head` already makes the hand-off correct, because there are exactly two threads and exactly one edge each needs to observe.

{% include excalidraw.html name="08-memory-ordering" caption="Figure 8.1 — the same producer/consumer hand-off under three orderings: seq_cst's global total order, acquire/release's single happens-before edge, and relaxed's bare atomicity" %}
<!-- DIAGRAM SPEC: three stacked horizontal bands on cream #fdfbf7. Top band "seq_cst": a single thick blue #4a73b8 horizontal timeline spanning both a producer lane and consumer lane below it, labeled "one global total order — every seq_cst op on this line, agreed by all threads". Middle band "acquire/release": producer lane (blue box "buf[t]=v") then ("tail.store(Release)", green #5a8870 box) with one green arrow crossing down-right to consumer lane's ("tail.load(Acquire)", green box) then ("read buf[h]"), with a label "exactly one happens-before edge, this pair only". Bottom band "relaxed": producer and consumer lanes with orange #a06030 boxes and no connecting arrow at all between them, labeled "atomic, no ordering promise — correct here only because the release/acquire edge above already covers it". -->

## Fences

A standalone `std::atomic_thread_fence(order)` provides an ordering guarantee not tied to any specific atomic operation. It is needed when the ordering must apply to a group of plain (non-atomic) memory operations relative to an atomic one elsewhere, rather than to the atomic operation's own read or write.

A `std::atomic_thread_fence(std::memory_order_release)` placed before several non-atomic writes, followed by a single relaxed atomic store, makes that store's effective visibility behave as if it were a release — every write before the fence is ordered before the store, without paying the `release` tag on each individual write (there is nothing to tag; they aren't atomic). The mirrored pattern gives those reads the same guarantee an acquire load would have given a single read: a relaxed atomic load followed by `atomic_thread_fence(acquire)` before several non-atomic reads.

```cpp
// Publish several plain fields with one fence instead of per-field atomics.
config.timeout_ms = 500;
config.retries = 3;
std::atomic_thread_fence(std::memory_order_release);
ready.store(true, std::memory_order_relaxed);

// Reader side:
if (ready.load(std::memory_order_relaxed)) {
    std::atomic_thread_fence(std::memory_order_acquire);
    use(config.timeout_ms, config.retries);   // sees both fields
}
```

This pattern shows up most often at the boundary of a lock-free data structure built from a mix of atomic control fields and non-atomic payload, where tagging every payload field as atomic would be both slower and semantically wrong (atomics on composite types like a struct are often impossible anyway). Outside that boundary case, prefer the ordering argument directly on the atomic operation; a fence is a more general and more easily misused tool, and `atomic_thread_fence(seq_cst)` in particular is a common over-correction that buys a global ordering guarantee nothing in the code actually depends on.

## The Cost of Ordering

On x86-64's Total Store Order (TSO) model, the hardware already orders store-to-store and load-to-load within a core, which is almost exactly what acquire/release needs. The practical consequence: a release store and an acquire load compile to a plain `mov`, with no `lock` prefix and no fence instruction. Disassembling the ring buffer's producer confirms it — the release store to `tail` and the acquire load of `head` are ordinary moves:

```console
4017c4:	mov    (%rax),%rdx        ; head.load(acquire)
4017e8:	mov    %rsi,(%rax,%rdx,8) ; buf[t % cap] = value
4017f4:	mov    %rsi,(%rax)        ; tail.store(t + 1, release)
```

No `lock`, no `mfence`, anywhere in the function. Sequential consistency is where the cost shows up. A `seq_cst` store on x86-64 cannot be a plain `mov`, because a plain store does not prevent a later load on the same core from executing before the store becomes globally visible — exactly the reordering TSO otherwise permits and `seq_cst`'s total order forbids. The compiler closes that gap with a `lock`-prefixed instruction (commonly `xchg`, which is implicitly locked) or an explicit `mfence`, either of which drains the core's store buffer before any subsequent memory operation proceeds. That single instruction is the entire cost difference. On the identical one-slot ring buffer (the tightest possible contention, every push waiting on the previous pop) measured on an 11th-gen Intel host, acquire/release ordering sustains roughly 6.4M hand-offs/second against the same workload under `seq_cst` at roughly 5.5M/second, a measured difference of roughly 15% paid entirely at the publishing store, not the consuming load, because the load side of both orderings was already a plain `mov`.

<!-- EXAMPLE SPEC: examples/concurrency/08-atomics-and-the-memory-model/ builds the same one-slot producer/consumer hand-off three times — seq_cst, acquire/release, and (deliberately, as a negative case gated behind a --broken flag) plain non-atomic counters — and reports a correctness sum plus a throughput figure for each; verified by a Lua verify.lua asserting the seq_cst and acquire/release builds always produce the exact expected sum while the --broken build is permitted (and in practice observed) to diverge from it, built via lgtm-docker-stack. -->
The example at `examples/concurrency/08-atomics-and-the-memory-model/` builds all three orderings side by side and reports both correctness and throughput.

The lesson is not "always use relaxed" or "avoid seq_cst." It's that `seq_cst`'s global ordering is a real feature: a total order every thread agrees on is strictly easier to reason about than a web of pairwise happens-before edges, and on x86 it is close to free for loads and measurably non-free for stores under contention. Default to `seq_cst` (the type's own default) until profiling shows atomic-operation overhead on a specific hot path; weaken the ordering there, with a comment stating which other synchronization supplies the edge the weaker ordering assumes. Code that opens with `memory_order_relaxed` everywhere because it looked faster in a microbenchmark is optimizing a cost that, on this architecture, mostly isn't there for loads, while discarding the easiest-to-audit default for no measured benefit at the call sites that matter least.

## Running in a container

Ordering cost is a property of the CPU's cache-coherence protocol, not of any kernel resource a container namespaces, so CPU and memory cgroup limits don't change which instructions `seq_cst` compiles to. What a container does change is core placement: an unpinned ordering microbenchmark running under `docker run` without `--cpuset-cpus` can be scheduled onto sibling hyperthreads of the same physical core rather than separate physical cores, which inflates the apparent cost of both orderings (the two threads now contend for shared execution ports) without changing the relative gap between them. Running the producer/consumer pair pinned with `--cpuset-cpus=0,2` (adjacent physical cores, not hyperthread siblings of each other) against the same pair unpinned on the same container is the clearest way to separate "cost of the ordering" from "cost of core contention" — the ordering delta should hold steady across both runs, while absolute throughput drops noticeably when the host scheduler is left free to co-schedule the two threads on sibling SMT lanes.

## Standards: C++20 / C++23 / C++26

{% include codetabs.html langs="C++20|C++23|C++26" %}
```cpp
// C++20: std::atomic_ref<T> is new — it lets existing, non-atomic storage
// (a plain field in an object you don't control) be accessed atomically
// through a separate reference object, without changing the object's type.
int legacy_counter = 0;
std::atomic_ref<int> counter_ref(legacy_counter);
counter_ref.fetch_add(1, std::memory_order_relaxed);
```
```cpp
// C++23: std::atomic and std::atomic_ref gained freestanding wait()/notify()
// on more types, and atomic<T>::wait() avoids spurious wakeups in the way
// condition_variable (Chapter 7) does not — it only wakes on an actual
// notify_one()/notify_all() or an observed value change, which makes a plain
// atomic-flag loop a lighter substitute for a condition_variable + mutex
// when the only shared state is the flag itself.
std::atomic<bool> ready{false};
ready.wait(false);              // blocks until ready != false, no spurious wake
ready.notify_all();
```
```cpp
// C++26: memory_order itself is unchanged; the standard's lock-free story
// moves instead to reclamation (std::hazard_pointer, std::rcu), covered in
// Chapter 9 and explicitly labeled experimental there — no shipping
// compiler currently implements them.
std::atomic<int> state{0};
state.store(1, std::memory_order_release);
```

`memory_order_consume` is formally part of the standard since C++11 but every major implementation (libstdc++, libc++, MSVC STL) has treated it as a synonym for `memory_order_acquire` for years, because the dependency-tracking optimization `consume` was meant to enable proved too fragile to implement reliably across optimizing compilers. Treat `consume` as deprecated in practice; this chapter and this book use `acquire` wherever a weaker-than-seq_cst load ordering is called for.

## What we learned

- `std::atomic<T>` guarantees indivisibility, meaning no thread ever observes a torn read or write — a necessary but separate guarantee from ordering; a hand-off between threads needs both.
- `memory_order` is a spectrum: `seq_cst` (one global total order) is strictly stronger than `acquire`/`release` (one happens-before edge per pair), which is stronger than `relaxed` (atomicity only, no ordering promise of its own).
- A standalone `atomic_thread_fence` extends an ordering guarantee to a group of non-atomic operations around an atomic one; it's the right tool at the boundary of a lock-free structure's control fields and payload, not a default substitute for ordering the atomic operation directly.
- On x86-64 TSO, acquire/release and relaxed both compile to a plain `mov`; `seq_cst`'s extra guarantee costs a locked instruction on the store side, measured here at roughly 15% throughput under the tightest possible contention — real, but not a reason to default away from `seq_cst` without profiling first.

Next, [Lock-Free Data Structures]({{ '/docs/09-lock-free-data-structures/' | relative_url }}): the same orderings put to work in ring buffers, the ABA problem, and the reclamation schemes that let a structure's nodes be freed safely while other threads might still be reading them.
