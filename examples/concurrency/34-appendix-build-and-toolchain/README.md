# concurrency/34-appendix-build-and-toolchain — the build harness, against its own reference program

Compendium reference:
[Doc 34 — Appendix: Build and Toolchain](../../../_docs/34-appendix-build-and-toolchain.md)

The runnable companion to the appendix. The appendix describes this
book's *entire* build and verification toolchain: five CMake presets
(`clang-debug`, `clang-asan`, `clang-tsan`, `clang-release`,
`gcc-parity`), a pinned Conan lockfile workflow, the `verify.lua` harness
convention every other example in this book already uses, and a
GCC-versus-clang parity requirement. That's a lot of matrix for one
container to run — so this example is **a reference slice, not the full
matrix**: a real, achievable subset of the same shapes, run against one
small program, with every check tied to an actual observable result
rather than asserted on faith.

## What it demonstrates

[`src/shared_counter.cpp`](src/shared_counter.cpp) is the appendix's
tiny reference program: four threads increment a shared counter. Two
paths:

- **(default)** — `std::atomic<uint64_t>::fetch_add`. Race-free by
  construction; `final_count` equals the expected total exactly, on
  every compiler, every run.
- **`--inject-race`** — a plain, non-atomic `uint64_t` incremented with
  an unsynchronized read-modify-write instead. A data race,
  reachable only behind this flag (off by default).

[`CMakePresets.json`](CMakePresets.json) ships the full five-preset
shape the appendix describes (schema version 3 and `CMAKE_CXX_STANDARD
20`, adapted from the appendix's own `version 6` / C++23 example to this
project's cmake-3.23-minimum, C++20-everywhere convention). It's a real,
usable preset file — `cmake --preset clang-tsan` works against this
directory on a host with clang and CMake ≥ 3.21 — but [the
Containerfile](Containerfile) does **not** invoke it directly inside the
container build, for a concrete reason explained below.

### Why the container build doesn't just run all five presets

Every other example in this book builds with gcc inside a UBI10
container (see [20-mechanical-sympathy](../20-mechanical-sympathy/) and
every sibling example) — clang is not part of this project's established
container toolchain, and this UBI10 image may or may not carry a clang
package or a working ThreadSanitizer runtime at all. Rather than make
the whole image build fail when it doesn't, [the
Containerfile](Containerfile) builds a representative slice with each
leg's availability checked explicitly:

| Leg | Compiler | Built | What happens if unavailable |
|---|---|---|---|
| `gcc` (the `gcc-parity` shape) | g++ | **Always** | n/a — this is the one hard requirement |
| `clang-release` | clang++ | Best-effort | Placeholder binary, `verify.lua` reports a SOFT skip |
| `clang-tsan` | clang++ `-fsanitize=thread` | Best-effort | Placeholder binary, `verify.lua` reports a SOFT skip |

Whichever legs can't build still leave *something* runnable at the
expected binary path (a tiny shell script that prints `UNAVAILABLE` and
exits 3) so the image always finishes building — `verify.lua` tells a
real absence apart from a real result by checking for that marker, never
by a missing file breaking the container build itself.

This example also generates `conan.lock` from
[`conanfile.txt`](conanfile.txt) (`fmt/10.2.1`, the same dependency
20-mechanical-sympathy establishes) at image-build time and ships it into
the runtime image, demonstrating the lockfile workflow end to end rather
than only describing it.

## Verification: verify.lua

Same Lua 5.4 assertion-harness convention as every other example in this
project. [`verify.lua`](verify.lua) checks:

1. **The gcc build's expected output (hard).** `final_count` must equal
   `expected` exactly on the safe path — the one unconditional
   requirement of this example.
2. **The `--inject-race` path is reachable (hard).** It must run to
   completion without crashing. Its count is *not* asserted equal to
   expected — losing updates is the accepted symptom of an unguarded
   race, not a bug in this path.
3. **gcc-vs-clang output parity (soft, real when clang is available).**
   If the clang leg built successfully, its non-racy output must be
   byte-identical to gcc's. If clang wasn't available when this image was
   built, this check reports a clearly-labeled SOFT skip rather than a
   failure.
4. **The injected race is flagged only in the TSan build (soft if TSan
   can't run here; a real, hard check once it can).** If the TSan leg is
   a real, runnable binary, `verify.lua` asserts the safe path produces
   *no* ThreadSanitizer warning and the `--inject-race` path *does*. If
   the leg is a placeholder, or ThreadSanitizer's own runtime fails to
   initialize in this minimal container (a real possibility independent
   of the UBI10 image's clang availability — TSan's shadow-memory mapping
   can fail under some sandboxed/seccomp container runtimes), this is a
   SOFT skip, not a failure.
5. **`conan.lock` pins the exact requested fmt version (hard, when the
   lockfile is present).** A direct string check against
   `conanfile.txt`'s `[requires]`, not an assumption about what Conan
   resolved.

`verify.lua` exits 0 on pass (with or without a SOFT-skip note) and
non-zero on any hard failure.

## Running it

```bash
./demo.sh              # build + run all available legs + verify.lua
./demo.sh --clean      # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-34-appendix-build-and-toolchain.sh`](../../../scripts/test-concurrency-demo-34-appendix-build-and-toolchain.sh).

### Observed run (clang unavailable in the build image)

```
== verify.lua: 34-appendix-build-and-toolchain (reference build slice) ==
  gcc build, safe path: PASS (final_count=800000 == expected=800000, exact)
  gcc build, --inject-race path: PASS (reachable, ran to completion -- its count is not asserted equal to expected; lost updates are the expected symptom of an unguarded race, not a bug in this path)
  clang-release leg: SOFT SKIP (clang++ was not available when this image was built -- see README). This book's CI builds with gcc; the parity claim is demonstrated here only when the environment happens to provide clang too.
  clang-tsan leg: SOFT SKIP (clang++ and/or the ThreadSanitizer runtime were not available when this image was built -- see README)
  conan.lock: PASS (pins fmt/10.2.1, matching conanfile.txt's [requires])
RESULT: PASS
```

### Observed run (clang + TSan available)

```
== verify.lua: 34-appendix-build-and-toolchain (reference build slice) ==
  gcc build, safe path: PASS (final_count=800000 == expected=800000, exact)
  gcc build, --inject-race path: PASS (reachable, ran to completion -- its count is not asserted equal to expected; lost updates are the expected symptom of an unguarded race, not a bug in this path)
  gcc-vs-clang parity: PASS (byte-identical output on the safe path)
  clang-tsan leg: PASS (no warning on the safe path, ThreadSanitizer: data race reported only with --inject-race)
  conan.lock: PASS (pins fmt/10.2.1, matching conanfile.txt's [requires])
RESULT: PASS
```

Both runs are a `PASS` — this example is designed so that whichever
compilers and sanitizer runtimes a given build host happens to provide,
the result is always accurately reported, never a silent
skip disguised as success.

## Layout

```
34-appendix-build-and-toolchain/
├── src/shared_counter.cpp   4 threads, atomic counter, --inject-race deliberately races a plain counter
├── CMakePresets.json        the appendix's full 5-preset reference shape (clang-debug/asan/tsan/release + gcc-parity)
├── conanfile.txt            [requires] fmt/10.2.1 — demonstrates the lockfile workflow
├── CMakeLists.txt           C++20, find_package(fmt), -O2, target shared_counter
├── Containerfile            UBI 10 builder (gcc required, clang best-effort) → ubi-minimal + lua runtime
├── verify.lua               Lua 5.4 assertion harness (gcc build hard, clang/TSan legs soft-if-unavailable)
├── demo.sh                  the driver (docker build + docker run)
└── README.md                this file
```

## What this slice leaves out

This example does not attempt `clang-debug` or `clang-asan` inside the
container (the appendix's full five-preset matrix is the reference
documentation, not every example's own CI burden), and it does not
attempt to run a from-scratch `conan lock create` reproducibility check
across two separate image builds. Both are real parts of the appendix's
description of the toolchain as a whole; this directory's job is to prove
the shapes that matter most concretely — a real build producing its
expected output, a real parity comparison when two compilers are both
available, and a real race caught by a real sanitizer when the runtime
supports it — without requiring every example in the book to also carry
a five-way build matrix.
