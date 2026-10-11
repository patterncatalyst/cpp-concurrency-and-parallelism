---
title: "Mechanical Sympathy"
order: 20
layout: tutorial
sectionid: docs
part: low-latency-and-high-throughput
description: "False sharing and the cache line, alignas and hardware_destructive_interference_size, struct layout, per-thread counters versus a single hot atomic, and the cache-line discipline that keeps hot data from fighting over a line."
duration: "15 min"
---

<!-- PROVENANCE: NEW | anchor books: Son, Lim -->

## What we'll cover

- Demonstrate false sharing: two unrelated atomics on the same cache line silently serializing two threads.
- Cover `alignas` and `std::hardware_destructive_interference_size` as the standard tools for cache-line padding.
- Cover struct layout choices that determine whether hot fields end up on the same or different cache lines.
- Show why a counter sharded per thread and summed on read beats a single atomic every thread contends on.
- Establish a cache-line discipline for designing shared data structures under contention.

[The Low-Latency Fast Path]({{ '/docs/19-the-low-latency-fast-path/' | relative_url }}) ended on a hot path that allocates nothing and touches a fixed set of memory on every iteration. That memory's own layout now matters as much as whether it's allocated at all: two threads can each own a variable no other thread ever writes, hold no lock, and still serialize on every access, because the hardware's cache-coherence protocol tracks ownership at the granularity of a cache line, not a variable. Mechanical sympathy is writing data layouts that cooperate with that granularity instead of fighting it.

## False Sharing

A CPU cache does not move individual bytes or words between cores; it moves fixed-size blocks, almost universally 64 bytes on current x86-64 and most current ARM server parts, called cache lines. The coherence protocol that keeps every core's view of memory consistent operates on whole lines: when one core writes to any byte within a line, every other core's cached copy of that entire line is invalidated, regardless of whether the write touched a byte the other core actually cares about. **False sharing** is the resulting performance failure: two variables that are logically unrelated, never read or written by the same thread, end up placed by the compiler or allocator within the same 64-byte line, and every write by either thread evicts the other thread's cached copy of the whole line.

The shape is easy to construct by accident and easy to demonstrate on purpose. Two `std::atomic<std::uint64_t>` counters declared adjacently in a struct, each incremented in a tight loop by its own dedicated thread, sit eight bytes apart — well within a single 64-byte line — with nothing logically connecting them. Each thread's `fetch_add` is uncontended in the sense that matters to the programmer (no other thread ever touches that counter's value), and yet each `fetch_add` invalidates the line the other thread just cached, forcing a fresh fetch over the coherence fabric on the other thread's very next access. The two threads behave, from a cache-traffic perspective, exactly as if they were incrementing the same atomic under contention, despite sharing no data at all.

```cpp
struct Counters {
    std::atomic<std::uint64_t> a{0};  // written only by thread A
    std::atomic<std::uint64_t> b{0};  // written only by thread B
};
// sizeof(Counters) is 16 bytes: both land in the same 64-byte cache line.
```

The cost is not subtle once measured: two independent counters sharing a line routinely run at a small fraction of the throughput the same two counters achieve once separated onto their own lines, because every increment on either side now forces a cache-coherence round trip that pure computation never would have needed. The fix is equally simple to state and easy to get wrong in practice without a standard tool for it, which is exactly what the next section provides.

<!-- DIAGRAM SPEC: Title "False sharing and the fix". Cream #fdfbf7 background. Top half "Shared line (false sharing)": one long 64-byte cache-line box with two adjacent cells, cell a (blue #4a73b8) labeled "atomic a — thread A" and cell b (green #5a8870) labeled "atomic b — thread B", both inside the same line box. Thread A icon on the left with a write arrow into cell a; thread B icon on the right with a write arrow into cell b. A red #c0392b bidirectional "invalidate / re-fetch (coherence traffic)" arrow between the two core caches, labeled "every write evicts the other core's whole line". Bottom half "Padded (no false sharing)": two separate 64-byte line boxes, each holding one atomic plus an orange #a06030 "padding to alignas(hardware_destructive_interference_size)" fill; thread A writes only its line, thread B only its, no red coherence arrow between them. Caption the contrast "same correctness, no cross-core eviction". -->
{% include excalidraw.html name="20-false-sharing" caption="Figure 20.1 — two atomics on one cache line force coherence traffic on every write; padding each onto its own line removes it" %}

<!-- EXAMPLE SPEC: examples/concurrency/20-mechanical-sympathy/ runs the Counters struct above two ways behind a --pad on|off flag: unpadded, both atomics share a line; padded, each gets its own alignas(std::hardware_destructive_interference_size) line. Two pinned threads (taskset-driven) each fetch_add their own counter N million times; the program reports elapsed time and the final counts. Verified by a Lua verify.lua asserting both counts always equal N exactly regardless of padding (correctness is unaffected) while the padded run's elapsed time is measurably lower than the unpadded run's across repeated trials; a perf stat invocation reports L1-dcache-load-misses or equivalent coherence-traffic counters for an optional deeper comparison. Built via lgtm-docker-stack, with taskset pinning the two threads to separate physical cores so the comparison isolates cache-line placement from scheduler noise. -->

## alignas and hardware_destructive_interference_size

Padding a struct by hand with a fixed byte count (`char pad[56];` after an 8-byte field, guessing at a 64-byte line) works until it runs on hardware with a different line size, at which point the guess silently stops doing its job without failing to compile. `std::hardware_destructive_interference_size`, defined in `<new>`, is the standard library's answer: it reports the minimum offset between two objects that guarantees they cannot share a cache line on the target the program was compiled for, which a build can use as the alignment and spacing for data meant to avoid false sharing without hardcoding a line-size constant anywhere in application code.

```cpp
struct Counters {
    alignas(std::hardware_destructive_interference_size) std::atomic<std::uint64_t> a{0};
    alignas(std::hardware_destructive_interference_size) std::atomic<std::uint64_t> b{0};
};
// Each member now starts on its own line-sized boundary; a write to `a`
// cannot invalidate the line `b` lives on, and vice versa.
```

The companion constant, `std::hardware_constructive_interference_size`, answers the opposite question: the maximum recommended size of a contiguous region to pack *together* so that data read and written as a unit by the same thread stays within one line rather than spilling across two, which would otherwise turn a single logical access into two separate cache-line fetches. The two constants are frequently, though not universally, the same numeric value on a given target; using the named constant for the intent actually meant (separate lines versus one shared line) documents which goal the code is pursuing even when the two happen to resolve identically.

A portability caveat matters here: because the "correct" interference-size value is platform-dependent and a library is free to report a conservative, build-time-fixed value rather than probing the actual running hardware, code compiled with one value and linked against a library compiled with a different one can silently violate the layout guarantee across a shared-library boundary. This is the reason some toolchains gate the feature behind a diagnostic by default — GCC, for instance, has at points warned on first use of `hardware_destructive_interference_size` specifically because of this ABI sensitivity. The constant is still the right tool; the caveat is to keep the types that use it inside a single compiled unit's ABI boundary (an internal library and its only consumer, built together, rather than a value baked into a widely distributed shared library's public layout) wherever that boundary could realistically move between builds.

## Struct Layout for Cache Lines

False sharing is not limited to a pair of top-level variables; it shows up just as readily inside a single struct whose fields are read and written by different threads at different rates. A struct mixing a hot field — updated every iteration of a tight loop, read constantly by another thread — with cold fields that change rarely but happen to sit on the same cache line will still serialize the hot access against whatever the cold field's writer is doing, purely because the layout put them on the same line.

The fix is to design layout around *who writes what*, not around what reads naturally together semantically. Grouping fields by writer, and padding between groups owned by different threads, is the general version of the two-counter example above: a struct with one thread's hot counter, a padding gap sized to `hardware_destructive_interference_size`, then another thread's hot counter, then (if present) shared read-mostly configuration fields that nobody writes on the hot path at all and that can safely share a line with each other, since none of their readers are paying a false-sharing cost for data nobody is contending to write.

```cpp
struct alignas(64) ShardedState {
    // Hot, writer-owned fields: one cache line each.
    alignas(std::hardware_destructive_interference_size) std::atomic<std::uint64_t> produced{0};
    alignas(std::hardware_destructive_interference_size) std::atomic<std::uint64_t> consumed{0};
    // Cold, read-mostly configuration: fine to share a line — nobody is
    // writing it on the hot path, so there is no coherence traffic to avoid.
    std::uint32_t capacity;
    bool          draining;
};
```

Field reordering alone, without explicit padding, can sometimes achieve the same separation when a compiler's default layout already happens to place two hot fields more than a line apart because of other members between them — but relying on default layout to produce the right spacing is fragile against any future edit to the struct, including one made by someone who has never read this chapter. Explicit `alignas` on the fields that matter states the requirement directly in the type, so it survives edits that change unrelated fields around it.

## Per-Thread Counters: Avoiding the Hot Atomic Altogether

Padding separates independent atomics so they stop false-sharing with each other, but it does nothing for the case where multiple threads need to update the *same* logical counter — a total request count, an aggregate byte counter — because every thread is still contending on one real atomic location, and no amount of padding changes that the cache line backing that one atomic bounces between every writer's core on every update. The throughput ceiling here is not false sharing; it is true sharing, and the fix is architectural rather than a layout tweak.

The standard pattern is to give each thread its own, padded counter — a true local variable each thread alone writes — and compute the aggregate only when it's actually needed, by summing across the per-thread shards. This turns N threads contending on one hot atomic into N threads each writing a plain, uncontended (non-atomic, even) local variable, with the summation cost paid once per read rather than once per write, which is the right trade whenever writes vastly outnumber reads — a request counter incremented millions of times a second and read once a second for a metrics scrape is the textbook case.

```cpp
struct alignas(std::hardware_destructive_interference_size) PaddedCounter {
    std::uint64_t value{0};  // written only by the owning thread — plain, not atomic
};

class ShardedCounter {
public:
    explicit ShardedCounter(std::size_t num_threads) : shards_(num_threads) {}

    void increment(std::size_t thread_index) {
        ++shards_[thread_index].value;  // no atomic, no cross-thread contention
    }

    std::uint64_t total() const {
        std::uint64_t sum = 0;
        for (const auto& s : shards_) sum += s.value;  // read path, infrequent
        return sum;
    }

private:
    std::vector<PaddedCounter> shards_;
};
```

A single hot atomic every thread contends on is never faster than this shape once contention is real; it is only simpler to write. The crossover point — where contention is light enough that one atomic outperforms the bookkeeping of sharding — is worth confirming with [the benchmark methodology from Chapter 18]({{ '/docs/18-benchmarking-without-deception/' | relative_url }}) rather than assumed, since the shard count itself (too few shards and contention returns; too many and the summation cost on read grows for no benefit) is a tuning parameter, not a fixed answer.

## Cache-Line Discipline in Practice

A short, concrete checklist covers most of what the sections above argue for individually: identify every piece of data more than one thread writes, and for each one, name which thread (or which small group) actually owns the write; pad every independently-written hot field to its own cache line with `alignas(std::hardware_destructive_interference_size)`, rather than guessing at a byte count; keep cold, read-mostly fields grouped separately from hot, write-heavy ones, since sharing a line among reads-only or rarely-written data costs nothing; and replace a single counter every thread contends on with a per-thread shard summed on read whenever writes dominate reads by a wide enough margin to make the summation cost at read time clearly cheaper than the coherence cost paid on every write. None of this is free to apply blindly — padding every field to 64 bytes bloats a structure that fits comfortably in cache otherwise, and sharding a counter nobody reads under contention in the first place adds complexity with no measurable benefit — so the discipline is to apply each move where contention is real and demonstrated, not everywhere a shared field exists.

## Running in a container

False sharing is a property of the physical cache-coherence protocol between cores, not of any resource a container namespaces, so neither a CPU quota nor a cpuset changes which bytes share a cache line or how many cycles an invalidation costs — a padded struct is exactly as effective inside a tightly quota-limited container as on bare metal, because the hardware enforcing cache-line granularity has no visibility into cgroups at all. What a container does change is *which cores* the threads touching that struct actually land on, and that interacts with the false-sharing fix in one specific way worth being precise about: a `cpuset` that places two threads of a false-sharing pair on sibling hyperthreads of the same physical core, rather than on two separate physical cores, changes the absolute cost of the invalidation traffic (sibling SMT lanes share more of the cache hierarchy and typically see a smaller penalty) without changing the *fact* that unpadded data still contends and padded data still doesn't — the relative benefit of padding holds regardless of which cores the cpuset happens to offer.

NUMA placement is the dimension that compounds with cache-line discipline rather than merely coexisting with it, as [NUMA, Affinity, and Data Locality]({{ '/docs/16-numa-affinity-and-data-locality/' | relative_url }}) covers in depth: a cache line bounced between two cores on the same NUMA node pays only the local coherence cost, while the identical false-sharing pattern between cores on different nodes pays that coherence cost plus the cross-node interconnect latency, because invalidating a remote core's cached copy of a line is itself a message that has to cross the same interconnect a remote memory read would. A container or orchestrator that places a false-sharing pair's two threads on different NUMA nodes — through an unconstrained `cpuset.mems`, or simply by not asking for node-local placement — multiplies an already-expensive bug by the remote-access penalty on top of it; padding fixes the coherence cost either way, but padding and NUMA-local placement together are what eliminate both halves of the compounded cost at once.

## Standards: C++20 / C++23 / C++26

`std::hardware_destructive_interference_size` and `std::hardware_constructive_interference_size` are C++17 facilities — this chapter's central tool predates the three-standard window this section otherwise tracks, and nothing in C++20, C++23, or C++26 changes what the two constants mean or how `alignas` consumes them. What does change across these three revisions is the vocabulary available for expressing a cache-conscious *layout* once the padding itself is in place.

C++20 adds nothing to the padding mechanism directly, but concepts make it practical to constrain a reusable padded-wrapper type so it only ever wraps something line-sized or smaller, catching a misuse (wrapping something already larger than a cache line, which defeats the point) at compile time rather than leaving it to a comment. C++23's `std::mdspan` (`<mdspan>`) gives a non-owning, multidimensional view over contiguous storage with a pluggable layout policy, which is directly useful for mechanical sympathy: a struct-of-arrays layout for several threads' counters can be expressed as one block of storage viewed through an `mdspan` whose layout policy strides each thread's column to a cache-line-sized boundary, keeping the ergonomic indexing of a 2D view while enforcing the same per-thread line separation the hand-written `ShardedCounter` above does with a `std::vector` of padded structs. C++26's `std::simd` (`<experimental/simd>`-lineage, proposed for standardization, with no shipping compiler implementation as of this writing) matters here because SIMD throughput itself depends on cache-line-aligned loads and stores — a vector load that straddles a cache-line boundary costs more than one that doesn't — so the alignment discipline this chapter argues for single hot variables extends, once `std::simd` ships, to the buffers SIMD code streams through.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// A concept constrains a padded-wrapper template to types no larger than
// one cache line, catching a misuse (wrapping something already
// multi-line-sized, which defeats the point of padding) at compile time.
template <typename T>
concept FitsInOneLine = sizeof(T) <= std::hardware_destructive_interference_size;

template <FitsInOneLine T>
struct alignas(std::hardware_destructive_interference_size) LinePadded {
    T value{};
};

LinePadded<std::atomic<std::uint64_t>> produced;
LinePadded<std::atomic<std::uint64_t>> consumed;
```

```cpp
// C++23
// std::mdspan with a custom layout policy expresses a struct-of-arrays
// counter block where each thread's column starts on its own cache line,
// without hand-writing a std::vector<PaddedCounter>.
// Schematic: a complete layout policy also needs extents_type, an extents()
// accessor, and the is_always_unique/exhaustive/strided traits; those are
// omitted here to keep the striding idea legible.
struct LineStridedLayout {
    template <typename Extents>
    struct mapping {
        Extents exts;
        constexpr auto required_span_size() const {
            // Each "row" (one per thread) padded to a full cache line of
            // std::uint64_t entries, regardless of how few columns are used.
            constexpr std::size_t line_elems =
                std::hardware_destructive_interference_size / sizeof(std::uint64_t);
            return exts.extent(0) * line_elems;
        }
        constexpr std::size_t operator()(std::size_t thread, std::size_t col) const {
            constexpr std::size_t line_elems =
                std::hardware_destructive_interference_size / sizeof(std::uint64_t);
            return thread * line_elems + col;
        }
    };
};

std::vector<std::uint64_t> storage(num_threads * 8 /* line_elems */);
std::mdspan<std::uint64_t, std::dextents<std::size_t, 2>, LineStridedLayout>
    counters(storage.data(), num_threads, 1);
```

```cpp
// C++26 (proposed, experimental: std::simd has no shipping compiler
// implementation as of this writing)
// SIMD throughput depends on cache-line-aligned storage the same way a
// single hot atomic depends on not sharing a line with another writer.
alignas(std::hardware_destructive_interference_size) std::array<float, 16> lane_buffer;

void sum_lanes(std::experimental::simd<float>& acc) {
    // An aligned load avoids the extra cost of a load that straddles a
    // cache-line boundary — the vectorized analogue of this chapter's
    // scalar false-sharing argument.
    acc += std::experimental::simd<float>(lane_buffer.data(),
                                           std::experimental::vector_aligned);
}
```

## What we learned

False sharing is a true-looking bug with a false cause: two threads that share no data still serialize, because the cache-coherence protocol invalidates whole 64-byte lines, not the individual bytes a program actually touches. `alignas(std::hardware_destructive_interference_size)` is the portable fix — padding to a platform-reported line size rather than a guessed byte count — and `hardware_constructive_interference_size` names the opposite goal, packing data that belongs together onto one line on purpose. Struct layout should follow ownership (who writes this field) rather than semantics (what reads naturally together), and a single atomic every thread contends on should become a per-thread shard summed on read once writes dominate reads enough to make that trade worthwhile. None of this is affected by a container's CPU quota or cpuset in itself, since cache-line granularity is a hardware property no cgroup touches — but NUMA placement compounds directly with it, turning an already-expensive false-sharing bug into one that also pays a cross-node interconnect penalty on every invalidation.

This closes the low-latency and high-throughput part of the book: benchmarking that can be trusted, a fast path stripped to its essential costs, and data layouts that cooperate with the cache hierarchy underneath both. [Lock-Free Messaging and the Disruptor]({{ '/docs/21-lock-free-messaging-and-the-disruptor/' | relative_url }}) is where all three combine into a single structure built to move messages between threads at the lowest latency this book reaches.
