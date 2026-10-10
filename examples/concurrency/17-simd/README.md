# concurrency/17-simd — scalar vs std::experimental::simd, AoS vs SoA

Compendium reference:
[Doc 17 — SIMD and Data Parallelism](../../../_docs/17-simd-and-data-parallelism.md)

The runnable companion to compendium Doc 17. The one-line takeaway: **SIMD
parallelizes across data inside one thread, and data layout decides whether
vectorization is even available** — the same arithmetic, applied to an
array-of-structs layout versus a struct-of-arrays layout, gets a completely
different chance at being vectorized, before a single compiler flag or
explicit vector type enters the picture.

## What it demonstrates

[`src/simd_particles.cpp`](src/simd_particles.cpp) generates one
pseudo-random set of particles (fixed seed, so it's identical on every run)
and applies the same kinematic recurrence — `pos += vel * dt`, repeated for
several steps — three ways:

- **`aos_scalar`** — array-of-structs (`struct Particle { float x,y,z,vx,vy,vz; }`)
  updated with a plain scalar loop. Updating `x` strides past the other five
  fields per particle; the layout the chapter says defeats vectorization
  outright.
- **`soa_scalar`** — struct-of-arrays (one contiguous `std::vector<float>`
  per field) updated with a plain scalar loop. Same arithmetic, contiguous
  access, no explicit vector type.
- **`soa_simd`** — struct-of-arrays updated with explicit
  `std::experimental::simd<float>` (`stdx::native_simd<float>`) — libstdc++'s
  Parallelism TS v2 implementation, and per the chapter the **production-usable**
  portable vector type today. This is deliberately **not** `std::simd`: that
  name is a proposed C++26 feature with no shipping mainstream standard
  library support as of this writing, so code written against it wouldn't
  compile on the gcc 14 / clang toolchains this project targets.

This example is compiled **without** `-march=native` or any explicit
`-march` target beyond the compiler's default x86-64 baseline (see
[`CMakeLists.txt`](CMakeLists.txt)) — directly applying the chapter's own
container-portability warning: a binary built against one machine's CPU
features is a trap for any container that might run on different hardware.
That choice has a second, deliberate payoff here: without `-mavx2`/`-mfma`,
neither the scalar path nor the `std::experimental::simd` path can fuse a
multiply-add into a hardware FMA instruction the other lacks, so the three
variants perform the **exact same sequence** of single-precision multiply-
then-add operations per particle per step — just batched differently (one
lane at a time vs. several at once). The final positions are expected to be
**bit-identical**, not merely close, which is what lets this example assert
correctness with an exact hash instead of a floating-point tolerance.

The program prints one header line and one `key=value` line per variant:

```
simd_width=4 n=2000000 steps=50 dt=0.01
layout=aos_scalar time_ms=312.456 hash=89abcdef01234567
layout=soa_scalar time_ms=198.234 hash=89abcdef01234567
layout=soa_simd   time_ms=61.789  hash=89abcdef01234567
```

## Verification: verify.lua

This project's assertion harness is **Lua 5.4**, run inside the container.
[`verify.lua`](verify.lua) checks two things, across several trials:

1. **Correctness is layout- and vectorization-independent (hard
   assertion).** `aos_scalar`, `soa_scalar`, and `soa_simd` must all hash
   their final positions identically, every trial — and the hash must
   reproduce across trials too, since the input is generated from a fixed
   seed. Any mismatch is a FAIL.
2. **`soa_simd` is faster than `soa_scalar` is reported as a soft signal.**
   Same layout, same arithmetic — only the explicit vectorization differs.
   If `soa_simd`'s average time doesn't clear a 5% noise floor over
   `soa_scalar`'s, or if the build/CPU combination reports a `simd_width`
   of 1 (meaning `std::experimental::simd` found no real vector lanes to
   use), `verify.lua` prints a WARN and still passes. Correctness (checked
   above) is unaffected either way, and **no specific speedup ratio is ever
   asserted** — only the sign.

`verify.lua` exits 0 on pass (with or without the speed WARN) and non-zero
on any hard failure.

## Running it

```bash
./demo.sh            # build + run simd_particles + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-17-simd.sh`](../../../scripts/test-concurrency-demo-17-simd.sh).

## Layout

```
17-simd/
├── src/simd_particles.cpp   aos_scalar / soa_scalar / soa_simd updates, prints key=value lines
├── conanfile.txt            [requires] fmt/10.2.1 — output formatting only
├── CMakeLists.txt           C++20, find_package(fmt), -O2 (no -march), target simd_particles
├── Containerfile            UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua               Lua 5.4 assertion harness (correctness hard, speed soft)
├── demo.sh                  the driver (docker build + docker run)
└── README.md                this file
```
