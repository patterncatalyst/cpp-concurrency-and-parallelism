---
title: "SIMD and Data Parallelism"
order: 17
layout: tutorial
sectionid: docs
part: parallelism-and-throughput
description: "Vectorization fundamentals, what defeats autovectorization, the upcoming C++26 std::simd, and the data layout choices that make vectorization possible in the first place."
duration: "15 min"
---

<!-- PROVENANCE: NEW | anchor books: Lim, Brandt -->

## What we'll cover

- Cover the basics of SIMD vectorization: one instruction processing several data elements in a single cycle, and what makes that possible at the hardware level.
- Cover what defeats autovectorization — aliasing, data-dependent branches, non-contiguous access — and how to recognize each one at the source level.
- Cover data layout choices (array-of-structs versus struct-of-arrays) that determine whether vectorization is even available to the compiler.
- Introduce C++26's proposed `std::simd` as a portable vector type, and compare it against hand-written intrinsics and trusting the autovectorizer.

Every chapter before this one parallelized across threads — independent execution units, each doing its own work. SIMD parallelizes inside a single thread, across data: one instruction, one core, several values processed together. The two are complementary rather than competing — a thread pool divides work across cores, and each thread's share of that work can itself be vectorized — but SIMD has its own failure modes, almost all of which come down to the compiler being unable to prove something about the data that the programmer already knows to be true.

## Vectorization Basics

A scalar instruction operates on one value per register: `addss` adds one pair of single-precision floats. A vector instruction operates on several values packed into one wider register: `addps` with a 256-bit AVX2 register adds eight pairs of floats in the same instruction, because the register holds eight 32-bit lanes side by side and the ALU performs the same add across all eight simultaneously. This is Single Instruction, Multiple Data — one decoded instruction, dispatched once, producing eight results instead of one — and it's a meaningfully different kind of parallelism from running eight threads: no scheduling, no synchronization, no cache-coherence traffic between lanes, because all eight values live in one register on one core.

<!-- DIAGRAM SPEC: Top row: a scalar ALU (blue #4a73b8 box) taking one float input and producing one float output, labeled "addss: 1 lane, 1 cycle, 1 result." Below it, a wider box representing a 256-bit AVX2 register divided into eight equal cream #fdfbf7 cells each holding a small float icon, feeding into a vector ALU (green #5a8870 box) producing eight output cells in the same layout, labeled "addps: 8 lanes, 1 cycle, 8 results." An orange #a06030 bracket beneath both spans the same horizontal width, labeled "same decode and dispatch cost either way." -->
{% include excalidraw.html name="17-simd-lanes" caption="Figure 17.1 — a scalar add processes one lane; a vector add processes as many lanes as fit in the register, for roughly the same per-instruction cost" %}

The width available depends on the CPU: SSE registers are 128 bits (four floats per register), AVX2 doubles that to 256 bits (eight floats), and AVX-512, where present, doubles it again to 512 bits. None of this is portable — code compiled for AVX2 won't run on a CPU that lacks it, and code compiled only for the oldest common baseline leaves throughput on the table everywhere newer. This tension — write once against the narrowest common denominator, or compile multiple versions and dispatch at runtime on detected CPU features — is unavoidable with any approach to SIMD, hand-written or compiler-generated, and resurfaces in the container section below: the flags a container image is built with determine which CPUs the resulting binary can even run on.

Not every operation vectorizes equally well. A loop that adds two arrays element-wise is the ideal case — every lane does the identical, independent operation. A loop with a data-dependent branch, or a reduction where each iteration depends on the previous one's accumulated result, is harder, sometimes impossible, to express as lane-parallel work without restructuring the algorithm. The next two sections cover which shapes the compiler can vectorize on its own, and which need help.

## What Defeats Autovectorization

A modern optimizing compiler autovectorizes a surprising amount of ordinary-looking code without being asked — a tight loop doing the same arithmetic across a contiguous array is squarely in its wheelhouse, and `-O2` or `-O3` with the right target architecture flag turns it into vector instructions with no source change at all. Three source-level patterns reliably stop this from happening, and all three stop it for the same underlying reason: the compiler cannot prove the transformation preserves the program's observable behavior, so it declines to make it, silently, with no diagnostic unless explicitly requested (`-fopt-info-vec-missed` on GCC, `-Rpass-missed=loop-vectorize` on Clang).

Pointer aliasing is the most common. Given `void add(float* a, float* b, float* out, int n) { for (int i = 0; i < n; ++i) out[i] = a[i] + b[i]; }`, the compiler cannot assume `out` doesn't overlap `a` or `b` — if it did, vectorizing into chunks of eight could read values already overwritten through an aliased `out` pointer earlier in the same chunk, changing the result. The language permits this aliasing, so the compiler assumes it might be happening and falls back to a scalar loop, or emits a runtime check that takes a vectorized path only when the pointers provably don't overlap. The `restrict` keyword (C) or its C++ spelling (`__restrict` on GCC/Clang/MSVC) is a promise from the programmer that the pointers don't alias — a promise the compiler trusts without verifying, so a `restrict`-qualified function called with overlapping pointers anyway is undefined behavior, not a slow path.

Data-dependent branches inside the loop body are the second blocker. `if (a[i] > threshold) out[i] = f(a[i]); else out[i] = g(a[i]);` picks a different computation per lane, and a vectorized version would have to execute *both* branches for *every* lane and select the correct result with a mask — which the compiler sometimes does (exactly how masked SIMD operations work), but only when both branches are cheap enough that computing both unconditionally still wins, and only when neither has a side effect that would be wrong to perform speculatively on lanes that didn't take it. A branch guarding a rare, expensive operation is a case the compiler usually declines to vectorize at all, since computing the expensive branch unconditionally on every lane costs more than it saves.

Non-contiguous or indirect access is the third. `out[i] = a[index[i]]` — a gather — reads from scattered addresses determined by another array's contents; `out[index[i]] = a[i]` — a scatter — writes the same way. Neither loads or stores a contiguous run into a vector register the way a straight traversal does. AVX2 and AVX-512 have dedicated gather instructions, and AVX-512 adds scatter, but both carry a real throughput cost relative to a contiguous load — often several times slower per element — so a compiler weighing a gather-heavy loop frequently emits a scalar one instead. The practical fix, where the access pattern allows it, is sorting or bucketing data so related accesses become contiguous before the hot loop runs.

## Data Layout for SIMD

None of the autovectorization fixes above matter if the data isn't laid out to be vectorized in the first place, and layout is usually a decision made long before the hot loop is written — in the struct definition. An array-of-structs (AoS) layout — `struct Particle { float x, y, z, mass; }; std::vector<Particle> particles;` — stores one particle's four fields contiguously, then the next particle's four fields, and so on. Computing `x += vx * dt` across every particle means reading one `x` field, skipping three unrelated fields, reading the next `x` field, skipping three more — a stride-16-bytes-read-4-bytes access pattern that defeats a SIMD load outright, because a vector load wants eight or sixteen *consecutive* same-field values, not one value separated by gaps of unrelated data.

A struct-of-arrays (SoA) layout — `struct ParticleSoA { std::vector<float> x, y, z, mass; };` — stores every particle's `x` contiguously in one array, every `y` contiguously in another, and so on. The same update loop now reads a long contiguous run of `x` values, a long contiguous run of `vx` values, and writes a long contiguous run back — exactly the shape a vector load, a vector multiply-add, and a vector store want, and exactly the shape the compiler can autovectorize without any gather or scatter at all.

<!-- DIAGRAM SPEC: Two side-by-side memory-layout strips. Left strip labeled "Array of Structs (AoS)": a repeating pattern of four small colored cells (x blue #4a73b8, y green #5a8870, z orange #a06030, mass red #c0392b) grouped tightly per particle, repeated for three particles, with a dashed selection box drawn around just the three blue (x) cells showing they are scattered across the strip with gaps. Right strip labeled "Struct of Arrays (SoA)": four separate contiguous runs, one per field (a solid run of blue cells, then a solid run of green, then orange, then red), with a solid selection box around the entire blue run showing it as one unbroken contiguous read. Caption beneath: "a vector load wants the boxed region contiguous — SoA gives it for free; AoS never does." -->
{% include excalidraw.html name="17-aos-vs-soa" caption="Figure 17.2 — AoS scatters one field's values across gaps of unrelated fields; SoA packs each field contiguously, which is what a vector load actually needs" %}

SoA is not free of cost elsewhere. Code operating on one whole particle at a time — printing it, serializing it, passing it to a function wanting an aggregate — is more natural against AoS, and becomes four separate lookups against SoA. The usual resolution is to keep SoA as the storage layout for anything running through a hot, vectorizable loop, and tolerate the extra indirection for the rare whole-entity operations. A hybrid, array-of-structs-of-arrays, groups a small fixed number of entities (matching a SIMD width) into one struct whose fields are themselves short arrays — contiguous same-field access within each group, AoS-like access across groups — a reasonable middle ground when neither pure layout fits the full workload.

## Autovectorization vs Intrinsics vs Portable SIMD

Three ways to get vectorized code exist today, trading off portability, control, and maintenance cost differently. Trusting the autovectorizer — ordinary scalar-looking loops, restrict-qualified pointers where aliasing is the blocker, the right `-march` target — costs nothing in code complexity and is the right default for most code, since the vectorizer handles width-selection and instruction choice, and the same source recompiles correctly for a different target. Its limit is that it only produces what it can *prove* correct; a loop shape it can't fully analyze gets a silent scalar fallback unless the build explicitly asks for vectorization diagnostics.

Hand-written intrinsics — `_mm256_add_ps`, `_mm256_loadu_ps`, and the rest of the Intel/AMD set, or ARM NEON's equivalents — give full, explicit control over which instructions run and in what order, at the cost of code tied to one instruction-set extension and register width. Intrinsics are the right tool when the autovectorizer provably can't produce what's needed — a gather-heavy kernel where manual lane shuffling beats the compiler's gather selection, a reduction needing a specific horizontal-sum sequence, an instruction mix that's been profiled and must stay fixed across compiler versions. They are also the least portable: a codebase with SSE, AVX2, and AVX-512 variants of one kernel, dispatched at runtime by detected features, is maintaining three implementations of one function.

A portable SIMD type sits between the two: write the vector-width-agnostic operations once, and let the library map them onto the target's actual width — `simd + simd` compiles down to `addps` on AVX2 and a scalar-equivalent fallback where nothing matches, with no separate source per architecture. This is the gap `std::simd` is meant to close.

## C++26 std::simd

`std::simd` — proposed via P1928, accepted into the C++26 working draft — standardizes a fixed-size or native-width vector type (`std::simd<float>`, or `std::simd<float, std::simd_abi::fixed_size<8>>` for an explicit width) with overloaded arithmetic operators, load/store operations, and mask types for conditional lanes, built on experience from the Parallelism TS v2's `std::experimental::simd`, which several standard library implementations (notably libstdc++'s GCC implementation, under `<experimental/simd>`) have shipped for years as a technical specification rather than a standard feature. The intent is exactly the portability gap above: write `std::simd<float> v = a + b * c;` once, and get `addps`/`mulps` sequences on an AVX2 target, the equivalent NEON sequences on ARM, and a correct (if unvectorized) fallback anywhere neither applies, all from the same source.

As of this writing, `std::simd` as a standard-library feature named in the `std` namespace is not shipping in a mainstream compiler's standard library — it is implemented, where available at all, under the experimental Parallelism TS header (`<experimental/simd>`, `std::experimental::simd`), which is the stable, usable predecessor to reach for in production code today. Code written against the eventual `std::simd` API shape should expect the namespace and header to change once an implementation actually ships the accepted standard feature; the experimental header is not a drop-in migration target by name, even though the API surface the proposal describes is close to it by design.

## Running in a container

SIMD's defining constraint for a container build is that a vectorized binary is CPU-feature-dependent in a way a scalar binary simply isn't: a binary compiled with `-march=native` on the build host, or with `-march=x86-64-v3` (the AVX2-and-friends baseline) targeting a specific feature level, will refuse to run — or worse, run and immediately hit an illegal-instruction fault — on any deployment target whose CPU lacks the instructions the compiler assumed were present. `-march=native` is a trap specifically in containerized CI/CD: the build machine's CPU features get baked into the binary, and the same image, run unmodified on a different fleet of machines (a different cloud instance family, a different generation of the same vendor's hardware), can crash immediately on startup with no application-level error, just a SIGILL. The safe default is an explicit, conservative `-march` target — the oldest microarchitecture level the deployment fleet is guaranteed to have — with `-march=native` reserved for build pipelines that are also the exact deployment target, which is rare outside of on-premises, single-fleet deployments.

The base image matters for the same reason from the other direction: `/proc/cpuinfo` inside a container reports the host's real CPU features (there is no virtualization of instruction-set support the way there can be of core count or memory), so a container's runtime behavior depends on which physical machine it lands on, unless the orchestrator's scheduling constraints pin it to a known feature level. Runtime dispatch — compiling multiple versions of a hot kernel at different feature levels and selecting among them via `__builtin_cpu_supports` or an equivalent CPU-feature-detection call at startup — removes the fleet-heterogeneity risk entirely, at the cost of larger binaries and more code paths to verify, and is the standard answer for any binary distributed to run on hardware the build pipeline doesn't fully control.

<!-- EXAMPLE SPEC: provision a KVM guest via lgtm-systems-programming with a known, fixed vCPU feature set (AVX2 confirmed present via /proc/cpuinfo and cpuid) to get reproducible timing; build the same elementwise-add kernel three ways — a restrict-qualified scalar loop relying on autovectorization, a hand-written AVX2 intrinsics version, and a std::experimental::simd version — against an AoS and an SoA layout of the same particle data, for four combinations total; report per-element cycles for each; verified by verify.lua asserting the SoA layout's autovectorized and simd-library variants both beat their AoS counterparts by a wide margin, and that a build compiled with -march=x86-64-v2 (pre-AVX2) on the same AVX2-capable guest falls back to scalar throughput, demonstrating the feature-level dependency directly rather than asserting it; run via the KVM lab rather than a container — a shared container host's CPU feature set and governor state aren't something this example should assume control over, and the comparison needs a fixed, known microarchitecture to be meaningful. Host NUMA layout and CPU governor settings must never be modified to run this example; only the disposable lab VM's configuration is touched. -->

## Standards: C++20 / C++23 / C++26

Nothing in the C++20 or C++23 standard itself names a SIMD type; both revisions reach vectorized code the same three ways described above — an autovectorized scalar loop, hand-written target-specific intrinsics, or the non-standard `std::experimental::simd` from the Parallelism TS v2, usable against either standard revision since it's a technical specification rather than a core-language feature gated by `__cplusplus`. The three blocks below show that progression concretely rather than a feature gated by the standard version: C++20 reaching for raw AVX2 intrinsics because no portable library option is assumed available, C++23 reaching for the by-then-mature `std::experimental::simd` once a codebase has decided to depend on the TS, and C++26 showing the target `std::simd` shape the proposal describes — labeled experimental because no mainstream standard library ships it under the `std` namespace as of this writing; `std::experimental::simd` remains the production-usable option until it does.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// Hand-written AVX2 intrinsics: full control, tied to one instruction set.
#include <immintrin.h>

void add(const float* __restrict a, const float* __restrict b,
         float* __restrict out, int n) {
    int i = 0;
    for (; i + 8 <= n; i += 8) {
        __m256 va = _mm256_loadu_ps(a + i);
        __m256 vb = _mm256_loadu_ps(b + i);
        _mm256_storeu_ps(out + i, _mm256_add_ps(va, vb));
    }
    for (; i < n; ++i) out[i] = a[i] + b[i];  // scalar remainder
}
```

```cpp
// C++23
// std::experimental::simd (Parallelism TS v2): portable across the ABI's
// native width, no per-architecture intrinsic calls in the caller's code.
#include <experimental/simd>
namespace stdx = std::experimental;

void add(const float* __restrict a, const float* __restrict b,
         float* __restrict out, int n) {
    using V = stdx::native_simd<float>;
    int width = V::size();
    int i = 0;
    for (; i + width <= n; i += width) {
        V va(a + i, stdx::element_aligned);
        V vb(b + i, stdx::element_aligned);
        (va + vb).copy_to(out + i, stdx::element_aligned);
    }
    for (; i < n; ++i) out[i] = a[i] + b[i];
}
```

```cpp
// C++26 (proposed; targets the accepted P1928 std::simd shape — not yet
// shipping under the std namespace in a mainstream standard library;
// use std::experimental::simd in production until it does)
#include <simd>  // target header; not yet available in mainstream libraries

void add(const float* __restrict a, const float* __restrict b,
         float* __restrict out, int n) {
    using V = std::simd<float>;
    int width = V::size();
    int i = 0;
    for (; i + width <= n; i += width) {
        V va(a + i, std::vector_aligned);
        V vb(b + i, std::vector_aligned);
        (va + vb).copy_to(out + i, std::vector_aligned);
    }
    for (; i < n; ++i) out[i] = a[i] + b[i];
}
```

## What we learned

A SIMD instruction trades one decoded instruction for several lanes of simultaneous work, inside a single core, with none of a thread's scheduling or coherence overhead — but only for code the compiler (or the programmer) can arrange into that lane-parallel shape. Aliasing, data-dependent branches around expensive work, and gather/scatter access patterns are the three things that most reliably block autovectorization, each for the same reason: the compiler can't prove the transformation is safe, so it declines rather than guesses. Struct-of-arrays layout turns a scattered, gap-filled access pattern into the contiguous run a vector load actually wants, and is usually a bigger lever on whether code vectorizes than any compiler flag. `std::experimental::simd` is the production-usable portable vector type today; `std::simd`, proposed and accepted for C++26, is the eventual standardized replacement, and should be treated as not-yet-shippable until a mainstream standard library actually ships it. Inside a container, the binary's CPU-feature assumptions — set by `-march` at build time — are as real a dependency as any linked library, and `-march=native` baked into a CI pipeline is a portability bug waiting for a fleet with older hardware to find it.
