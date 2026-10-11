---
title: "Appendix: Build and Toolchain"
order: 34
layout: tutorial
sectionid: docs
part: appendix
description: "The project's build and verification toolchain: clang and gdb, CMake presets, Conan lockfiles, the Lua verify.lua harness, and GCC/clang parity checks."
duration: "15 min"
---

<!-- PROVENANCE: NEW (mirrors the cpp-statelessness build appendix) | anchor books: none (build/toolchain reference) -->

## What we'll cover

- Document the clang and gdb toolchain versions this book's examples are built and verified against.
- Document the CMake presets used to configure each example consistently.
- Document the Conan lockfiles that pin third-party dependency versions across the book.
- Document the Lua verify.lua harness that checks an example actually produces its observable effect, and the GCC-versus-clang parity checks that run alongside it.
- Note the editor assumption: every example is a plain CMake project that opens in any editor, with JetBrains CLion as the preferred one.

Every runnable example in this book shares one build and verification toolchain, and this appendix is the reference for it: which compiler and debugger versions it targets, how CMake is configured so every example builds the same way, how Conan pins the handful of third-party dependencies a lock-free ring or an OTel exporter needs, and how the Lua harness that gates every chapter's claims actually works. Nothing here is new material — it is the scaffolding every earlier chapter's code samples assumed was already in place.

## Toolchain: clang and gdb

This book's examples build primarily with clang and are debugged primarily with gdb — a deliberate pairing, not an accident of whichever tools happened to be installed. Clang's diagnostics for template and concept errors (relevant throughout the coroutine and `std::execution` chapters), its mature sanitizer integration, and its close tracking of recent standard-library paper implementations in libc++ make it the more informative compiler to develop against day to day. gdb remains the debugger of choice regardless of which compiler produced the binary, because its DWARF handling, multi-threaded backtrace support, and remote-debugging story are the most mature on Linux, and [Debugging Real Races and Deadlocks]({{ '/docs/27-debugging-real-races-and-deadlocks/' | relative_url }}) builds directly on gdb's per-thread inspection.

The pinned baseline is **clang 18 with libc++**, which carries the C++23 feature set this book relies on most heavily (`std::expected`, `std::move_only_function`, `std::generator` in partial form) without the gaps earlier clang releases have in those areas, paired with **gdb 14 or later**, which added or stabilized the pretty-printers for `std::jthread`, `std::atomic`, and coroutine-frame inspection that make stepping through this book's examples tractable rather than a raw-memory exercise. Installing both from a standard Fedora or Ubuntu package set is sufficient; nothing in this book depends on a from-source compiler build. Where a specific chapter needs a newer feature than clang 18 ships (`std::flat_map`, for instance, which libc++ does not yet provide as of this writing), the chapter calls it out explicitly rather than silently assuming a toolchain upgrade, and a fallback (typically a sorted `std::vector` or an equivalent third-party container) is shown alongside it.

GDB's `.gdbinit` for this project loads libc++'s own pretty-printers where available and adds a small set of project-local ones for the lock-free ring's sequence counters, so that `print ring.published` shows a decoded sequence number rather than a raw atomic's internal representation. The printers live alongside each example under `tools/gdb-printers/` and are loaded automatically by `demo.sh`'s debug target rather than requiring a manual `source` command per session.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, left-to-right pipeline of five boxes connected by arrows. Box 1 (blue #4a73b8) "source + conanfile.txt/conan.lock". Arrow labeled "conan install --lockfile=conan.lock" into Box 2 (orange #a06030) "CMake + Ninja, 5 presets: clang-debug / clang-asan / clang-tsan / clang-release / gcc-parity". Arrow fans out into two parallel boxes: Box 3a (green #5a8870) "clang-release binary" and Box 3b (green #5a8870) "gcc-parity binary", with a double-headed red #c0392b arrow between them labeled "PARITY CHECK: identical verify.lua pass count required". Both 3a and 3b feed into Box 4 (blue) "lua verify.lua -- checks.expect_equal / checks.expect_match against real observable output". Box 4 feeds into Box 5 (orange) "PASS N / FAIL 0 (or SKIP for an unreachable optional backend)". A small gdb icon sits beside Box 3a labeled "attached directly to the RelWithDebInfo binary when a number looks wrong -- never a stripped Release build". -->
{% include excalidraw.html name="34-toolchain-pipeline" caption="Figure 34.1 — one source tree, a pinned Conan lockfile, five CMake presets including a GCC parity leg, and one Lua harness gating every binary against the same observable-effect checks" %}

## Editors and IDEs

Every example is a plain CMake project with a Conan-generated toolchain file, so it opens in any editor without project-specific setup. The presets enable `CMAKE_EXPORT_COMPILE_COMMANDS`, which writes a `compile_commands.json` that a clangd-based language server (VS Code, Neovim, Emacs, or Vim) reads to resolve the exact include paths and flags each translation unit was compiled with, so completion and diagnostics match the real build rather than an approximation of it.

The preferred editor for this book is **JetBrains CLion**. It opens a `CMakeLists.txt` directly as a project, reads the `CMakePresets.json` this appendix defines so the clang-debug, clang-asan, clang-tsan, and clang-release profiles appear as selectable build configurations, picks up the Conan toolchain file for dependency resolution, and drives gdb and the sanitizers through its run configurations — the same tools the command-line workflow uses, behind a graphical front end. Nothing in the book requires CLion: the examples build, run, and debug identically from the shell. The only assumption is that you can open and edit a CMake project in whatever editor you prefer.

## CMake Presets and Conan Lockfiles

Every example shares one `CMakePresets.json` shape, configured so a reader never has to remember a project-specific sequence of flags to reproduce a build:

```json
{
  "version": 6,
  "configurePresets": [
    {
      "name": "clang-debug",
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/clang-debug",
      "cacheVariables": {
        "CMAKE_CXX_COMPILER": "clang++",
        "CMAKE_BUILD_TYPE": "Debug",
        "CMAKE_CXX_STANDARD": "23",
        "CMAKE_EXPORT_COMPILE_COMMANDS": "ON"
      }
    },
    {
      "name": "clang-asan",
      "inherits": "clang-debug",
      "binaryDir": "${sourceDir}/build/clang-asan",
      "cacheVariables": {
        "CMAKE_CXX_FLAGS": "-fsanitize=address,undefined -fno-omit-frame-pointer",
        "CMAKE_EXE_LINKER_FLAGS": "-fsanitize=address,undefined"
      }
    },
    {
      "name": "clang-tsan",
      "inherits": "clang-debug",
      "binaryDir": "${sourceDir}/build/clang-tsan",
      "cacheVariables": {
        "CMAKE_CXX_FLAGS": "-fsanitize=thread -fno-omit-frame-pointer"
      }
    },
    {
      "name": "clang-release",
      "inherits": "clang-debug",
      "binaryDir": "${sourceDir}/build/clang-release",
      "cacheVariables": {
        "CMAKE_BUILD_TYPE": "RelWithDebInfo",
        "CMAKE_CXX_FLAGS": "-O2 -fno-omit-frame-pointer"
      }
    },
    {
      "name": "gcc-parity",
      "inherits": "clang-release",
      "binaryDir": "${sourceDir}/build/gcc-parity",
      "cacheVariables": { "CMAKE_CXX_COMPILER": "g++" }
    }
  ]
}
```

Four presets cover the day-to-day cases a chapter's examples need: `clang-debug` for ordinary iteration with symbols and no optimization, `clang-asan` and `clang-tsan` as single-sanitizer builds rather than a combined one (AddressSanitizer and ThreadSanitizer cannot be linked into the same binary, and [Sanitizers and Dynamic Analysis]({{ '/docs/28-sanitizers-and-dynamic-analysis/' | relative_url }}) covers running each separately as its own pass), and `clang-release` as `RelWithDebInfo` rather than a stripped `Release` — every example keeps debug symbols even in its fastest build, because a benchmark that cannot be attached to with gdb when its numbers look wrong is a benchmark nobody can trust. `gcc-parity` inherits the release configuration and swaps only the compiler, which is the seed the parity checks below build on.

`CMAKE_BUILD_TYPE` deserves a direct statement of what each value actually changes, since the four values are easy to use inconsistently across examples: `Debug` disables optimization and keeps full symbols, meant for stepping through logic; `Release` optimizes fully and strips most debug information, meant for a shipped binary where debugging is not a goal; `RelWithDebInfo` optimizes at `-O2` while retaining symbols, which is the right default for *measuring* this book's examples, since an unoptimized Debug build's timings have no relationship to production behavior and a stripped Release build cannot be profiled with gdb when a number looks wrong; `MinSizeRel` does not appear in this book's presets at all, since none of these examples optimize for binary size.

Where an example needs a third-party dependency (the OTel exporter in [Observing Concurrency]({{ '/docs/29-observing-concurrency/' | relative_url }}), Boost.Asio in the gRPC and REST chapters), a `conanfile.txt` pins exact versions and a committed `conan.lock` pins the full resolved dependency graph, transitive versions included:

```ini
# conanfile.txt
[requires]
opentelemetry-cpp/1.16.0
grpc/1.65.0
boost/1.85.0

[generators]
CMakeDeps
CMakeToolchain

[layout]
cmake_layout
```

```bash
conan lock create conanfile.txt --lockfile-out=conan.lock
conan install conanfile.txt --lockfile=conan.lock --build=missing \
    -s compiler=clang -s compiler.libcxx=libc++ -s compiler.cppstd=23
cmake --preset clang-release
cmake --build --preset clang-release
```

The committed lockfile is what makes a build from this repository reproducible months after a dependency ships a new minor version with a behavioral change nobody asked for: `conan install --lockfile=conan.lock` resolves to the exact graph that was tested, not whatever ConanCenter currently considers compatible with the version ranges in `conanfile.txt`. Bumping a dependency is a deliberate act: regenerate the lockfile, rebuild every example that touches it, and commit the new lockfile alongside the change that prompted the bump, rather than something that happens silently between one `conan install` and the next.

## The Lua verify.lua Harness

Every example in this book ships a `verify.lua`, and the discipline it enforces is the one this book repeats in every chapter's closing section: a demo is not "working" because it built and exited zero, it is working only when it produced the specific observable effect the chapter claims. `verify.lua` runs the built example (sometimes multiple configurations of it, as in Chapter 32's progressive `--cpus`/`--cpuset-cpus` sweep), captures its output or queries its side effects directly, and asserts against that evidence with a small, consistent API:

```lua
-- verify.lua (excerpt, from the ring-buffer example in Chapter 21)
local checks = require("checks")

local published, consumed = run_example("ring-demo", {"--events=10000"})

checks.expect_equal(tostring(consumed), tostring(published),
  "every published event was consumed exactly once -- no event lost, " ..
  "none double-delivered across the ring hand-off")

local occupancy = read_metric("ring_occupancy_max")
checks.expect_match(tostring(occupancy <= 1024), "true",
  "ring occupancy never exceeded its configured capacity -- back-pressure " ..
  "engaged rather than the ring silently growing")

print(checks.summary())  -- "PASS N / FAIL 0" or the first failing assertion
```

`checks.expect_equal` and `checks.expect_match` are the two primitives nearly every example's assertions reduce to — exact equality for counts and totals that must match precisely (every ingested order appears in published output exactly once, in order, as [the end-to-end pipeline chapter]({{ '/docs/33-ingest-match-publish/' | relative_url }}) asserts), and pattern matching for conditions expressed as a boolean or a range (a latency figure present in the output, a thread-id count equal to exactly one for a single-writer stage). Each assertion carries a message that states not just what was checked but why it matters, so a failing run's output reads as a diagnosis rather than a bare `assert failed` with a line number. `checks.summary()` prints the aggregate `PASS N / FAIL 0` line that every example's CI step and every chapter's "Running in a container" callout look for.

The harness is invoked uniformly: `REPO_ROOT=$(pwd) lua verify.lua` from inside an example's directory, with `demo.sh` wiring this into its own `verify` subcommand so a reader never needs to remember the raw invocation. Where an assertion depends on an optional backend (the OTel collector in the pipeline chapter's span-count check, for instance), the harness prints an informational `SKIP` rather than a `FAIL` when that backend is unreachable, following the same pattern [Concurrency in Containers]({{ '/docs/32-concurrency-in-containers/' | relative_url }})'s cgroup-probe example uses for a cgroup v1 host: a missing optional dependency degrades the check, it does not fail the whole example.

## GCC vs clang Parity

Every example that builds with clang also builds, as a second CI step, with GCC against the `gcc-parity` preset, and `verify.lua` runs unmodified against both resulting binaries. The point of the parity check is not stylistic compiler-agnosticism for its own sake — it is that a lock-free algorithm's correctness should not depend on which compiler's code generation happened to produce a working binary. A race that a particular compiler's instruction scheduling or register allocation happens not to expose is still a race; running the identical source under two independently-developed optimizers and code generators is one of the cheapest ways to flush out an ordering assumption that one compiler's output quietly tolerated.

Parity failures fall into three recognizable shapes. The first is a standard-library gap — `std::flat_map` on libc++ as of this writing, noted earlier, which the parity build works around with a feature-test-macro-guarded fallback rather than failing the GCC leg outright. The second is a warning-level mismatch: GCC and clang disagree at the margins about which patterns trigger `-Wall`/`-Wextra`, and a project that treats warnings as errors (`-Werror`, applied uniformly across both presets in this book) occasionally needs a narrowly-scoped suppression on one compiler that the other never needed. The third, rarest, and most informative shape is a sanitizer or behavioral difference under identical source and identical standard compliance, exactly the race-exposed-by-one-compiler case above, and when the parity run surfaces one, the fix is to the source's synchronization, never to the test.

```bash
# Run both legs and compare verify.lua results directly.
cmake --preset clang-release && cmake --build --preset clang-release
cmake --preset gcc-parity    && cmake --build --preset gcc-parity

(cd build/clang-release && REPO_ROOT=$(pwd)/../.. lua ../../verify.lua)
(cd build/gcc-parity    && REPO_ROOT=$(pwd)/../.. lua ../../verify.lua)
```

Both legs are expected to report an identical `PASS N / FAIL 0` count; a difference in the pass count between the two compilers for the same source is treated as a defect in the example, not a quirk to document and move past.

## Running in a container

The multi-stage container pattern used across this book's examples separates the build toolchain from the runtime image: a build stage installs clang, CMake, Ninja, and Conan, resolves the lockfile, and compiles every preset that a given example needs, while the runtime stage carries only the resulting binary, its dynamically linked runtime libraries, and `lua` itself where `verify.lua` is meant to run inside the container rather than against a host-side binary. Running the full verification sweep inside the container image is the strongest reproducibility claim this book makes about any example: `docker build` resolves the exact same Conan lockfile and clang version on any host, and `docker run <image> lua verify.lua` either reports the same `PASS N / FAIL 0` every time or the image itself is the thing that has drifted, not the host running it. The GCC parity leg builds as a second stage in the same Containerfile, sharing the Conan cache layer with the clang stage so the two builds do not each pay the full dependency-resolution cost independently.

## Standards: C++20 / C++23 / C++26

The build-configuration side of this appendix is standards-neutral (CMake presets and Conan lockfiles work the same regardless of which C++ standard a given example targets), but the feature-detection code every example's build uses to confirm its toolchain actually supports what a chapter assumes changes shape across the three standards this book covers, from a raw macro check to a typed result to, on the furthest horizon, a reflection-based query.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20: a bare feature-test macro check, compiled into every example's
// startup path to fail fast with a readable message rather than a wall
// of template-instantiation errors deep in a header.
#if !defined(__cpp_lib_atomic_wait)
#error "This example requires atomic wait/notify (P1135, C++20)."
#endif
```

```cpp
// C++23: std::expected (header <expected>) used by the example harness
// itself to report which optional features its own build was compiled
// with, so verify.lua can read a structured capability report instead
// of grepping compiler-specific preprocessor output.
#include <expected>

struct BuildCaps { bool has_flat_map; bool has_generator; };

std::expected<BuildCaps, std::string> detect_build_caps() {
#if defined(__cpp_lib_flat_map) && defined(__cpp_lib_generator)
    return BuildCaps{true, true};
#elif defined(__cpp_lib_flat_map)
    return BuildCaps{true, false};
#else
    return std::unexpected("libc++ as configured lacks std::flat_map");
#endif
}
```

```cpp
// C++26 (proposed, experimental -- static reflection (P2996) ships in no
// shipping compiler as of this writing): a hypothetical capability query
// that enumerates available standard-library features via reflection
// rather than a hand-maintained list of feature-test macros.
template <typename Lib>
consteval auto enumerate_features() {
    return std::meta::members_of(^Lib);  // illustrative, not yet implementable
}
```

The C++20 macro guard is what every example in this book actually ships today, and its value is concrete: it turns a missing feature into one readable error line instead of a cascade of unrelated template errors from deep inside a header. `std::expected` is a real, usable improvement for the harness's own internal bookkeeping, reporting which optional capabilities a given build has in a form `verify.lua` can inspect structurally rather than scraping compiler output, and several of this book's later examples use exactly this shape internally. The reflection-based sketch is included to be transparent about where build-time capability detection is heading, not because it changes anything an example does today: P2996 has no shipping implementation, the syntax shown is illustrative rather than something a reader can compile, and nothing in this appendix depends on it arriving on any particular schedule.

## What we learned

- This book's examples build primarily with clang 18 (libc++, C++23) and debug primarily with gdb 14 or later, a pairing chosen for diagnostic quality and mature multi-threaded debugging support rather than either tool being mandatory in any absolute sense.
- A shared set of CMake presets (`clang-debug`, `clang-asan`, `clang-tsan`, `clang-release`, `gcc-parity`) gives every example the same reproducible configuration surface; `RelWithDebInfo`, not stripped `Release`, is the build type used for every measurement in this book, because an unmeasurable binary cannot be debugged when its numbers look wrong.
- Conan 2.x with a committed `conan.lock` pins the full transitive dependency graph for examples that need third-party libraries; bumping a pinned version is a deliberate, tested, re-committed act, never an implicit side effect of a fresh `conan install`.
- `verify.lua`'s `checks.expect_equal`/`checks.expect_match` API is how every chapter's claims are gated against a real observable effect rather than a successful exit code, with a `SKIP` (not a `FAIL`) for assertions that depend on an optional, unreachable backend.
- Every example builds and verifies under both clang and GCC; a parity failure between the two compilers on identical source is treated as a defect in the example's synchronization, not a quirk to be documented and left alone.
- Feature-availability checks move from a C++20 preprocessor guard to a C++23 `std::expected`-based structured capability report inside the harness itself, with a C++26 reflection-based version sketched only to show direction — it has no shipping implementation and nothing in this book depends on it.

<!-- EXAMPLE SPEC: examples/concurrency/34-appendix-build-and-toolchain/ is a reference slice rather than a service: a minimal CMakeLists.txt and CMakePresets.json exercising all five presets (clang-debug, clang-asan, clang-tsan, clang-release, gcc-parity) against one tiny shared-counter program with a deliberately-injected, sanitizer-catchable data race behind a --inject-race flag (off by default); a conanfile.txt + conan.lock pinning a single small dependency (fmt) to demonstrate the lockfile workflow end to end; and the project's gdb pretty-printer script plus its checks.lua verify API, used directly rather than reimplemented per example. Verified by a Lua verify.lua that asserts (1) all five presets configure and build successfully, (2) the clang-tsan build reports a detected race only when --inject-race is passed and reports none otherwise, (3) the clang-release and gcc-parity builds of the non-racy path produce byte-identical program output, and (4) conan install --lockfile=conan.lock resolves to the exact pinned fmt version recorded in the lockfile. Built and verified inside the project's multi-stage Containerfile as described in "Running in a container" above. -->
The example at `examples/concurrency/34-appendix-build-and-toolchain/` is this appendix's own worked reference: every preset, the lockfile workflow, and the GCC/clang parity check, run against one small program rather than scattered across every other example in the book.
