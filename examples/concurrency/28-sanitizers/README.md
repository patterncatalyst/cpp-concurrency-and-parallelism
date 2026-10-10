# concurrency/28-sanitizers — one race, two detectors; one real use-after-free

Compendium reference:
[Doc 28 — Sanitizers and Dynamic Analysis](../../../_docs/28-sanitizers-and-dynamic-analysis.md)

The runnable companion to compendium Doc 28. Two things it demonstrates:

- **The same bug, caught by two independent algorithms.** `racy_counter`
  (the identical shape chapter 27 builds, reused here so this example
  stays standalone) is checked under **ThreadSanitizer** (compile-time
  instrumentation, per-thread vector clocks) AND under **Valgrind
  Helgrind** (binary re-translation, a lockset-and-happens-before hybrid)
  — two structurally different detectors that have to agree on the exact
  same source line for the same reason: the bug is real, not an artifact
  of either tool's own model.
- **A real heap-use-after-free, caught by AddressSanitizer.**
  `detached_uaf` spawns a detached thread, frees a buffer on the main
  thread, and has the detached thread read through the now-dangling
  pointer — a bug born from concurrent lifetime management, even though
  ASan itself has no model of threads at all.

## What it demonstrates

### `racy_counter` — ThreadSanitizer vs. Helgrind

[`src/racy_counter.cpp`](src/racy_counter.cpp) is built **twice**: once
plain (the binary Helgrind runs against — Valgrind needs no rebuild or
compiler cooperation, just debug symbols to name a source line) and once
with `-fsanitize=thread`. Both builds run `--mode racy` (a bare,
non-atomic `++counter` from two `std::jthread`s) and `--mode fixed` (the
same shape against a `std::atomic<int>`).

```
racy_counter --mode racy|fixed [-n ITERATIONS]
```

### `detached_uaf` — AddressSanitizer

[`src/detached_uaf.cpp`](src/detached_uaf.cpp) models exactly the
scenario the chapter calls out as concurrency's distinct contribution to
memory-safety bugs: `--mode uaf` hands a **raw** pointer to a detached
worker thread, then frees the buffer on the main thread; the worker sleeps
briefly (so the free genuinely happens first) and then reads through the
now-dangling pointer. `--mode fixed` hands the worker a
`std::shared_ptr<int[]>` **by value** instead — its own copy keeps the
allocation's reference count above zero for as long as it's running, so
there's no free to race against at all.

```
detached_uaf --mode uaf|fixed
```

A detached thread doesn't keep the process alive on its own, so both modes
have `main` sleep briefly after handing off the buffer — long enough for
the worker to actually run before the process exits.

## Verification: verify.lua

[`verify.lua`](verify.lua) runs inside the container (which ships the
binaries, Valgrind, and a `lua` interpreter) and checks, in order:

1. **TSan reports the race (hard, when the leg built and TSan can run).**
   `racy_counter_tsan --mode racy` must print `ThreadSanitizer: data race`
   naming `increment()` in `racy_counter.cpp`. `--mode fixed` must be
   clean.
2. **Helgrind reports the SAME race (hard, when Valgrind starts).**
   `valgrind --tool=helgrind` against the plain build's `--mode racy` must
   print `Possible data race` naming the same `increment()` /
   `racy_counter.cpp` location, with `--error-exitcode=99` confirming
   Helgrind itself flagged it (not some unrelated nonzero exit). `--mode
   fixed` must be clean (exit 0).
3. **Cross-tool agreement**, reported once both legs above actually ran:
   two independent detection algorithms, one real bug, same source line.
4. **The plain `detached_uaf` build runs informationally only** — no
   assertion either way, because a use-after-free into memory the
   allocator hasn't yet reused for anything else can read back
   plausible-looking garbage with no visible symptom, the same "absence of
   a symptom is not absence of the defect" trap chapter 27 makes about a
   racy counter's printed total.
5. **ASan reports the use-after-free (hard, when the leg built and ASan
   can run).** `detached_uaf_asan --mode uaf` must print
   `heap-use-after-free` naming both the `allocated by thread` and `freed
   by thread` call stacks, and must never reach its own
   `completed-without-asan-catching-it` print — proof ASan actually halted
   the process rather than the bug happening not to matter this run.
   `--mode fixed` (the `shared_ptr` version) must exit 0 clean.

### Why some checks are SOFT, not hard

- **TSan/ASan leg unavailable or fails to initialize.** This UBI10 image's
  `libtsan`/`libasan` packages may not be present on every repo set/arch,
  and each sanitizer's shadow-memory reservation can fail to initialize
  under a restrictive container memory policy — independent of whether the
  underlying bug exists. A missing build or a `FATAL:` runtime-init
  message is reported as a **SOFT SKIP** with a clear WARN.
- **Valgrind fails to start.** Valgrind re-implements CPU execution in
  userspace; a sandboxed container runtime whose own syscall-emulation
  layer wasn't built with a second full CPU emulator running on top of it
  (the doc's `gVisor`-style example) can trip Valgrind at startup. A
  detected startup failure is a SOFT SKIP, not a failure.

At least one of TSan/Helgrind's race report and the ASan use-after-free
report are HARD whenever the environment lets the respective tool run at
all, per this project's convention: a soft skip documents a real
environment limit, it never silently waves through a broken demo.

## Running it

```bash
./demo.sh            # build + run (TSan + Helgrind + ASan checks) + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-28-sanitizers.sh`](../../../scripts/test-concurrency-demo-28-sanitizers.sh).

## Layout

```
28-sanitizers/
├── src/racy_counter.cpp   shared non-atomic int vs. atomic<int> (same shape as ch27)
├── src/detached_uaf.cpp   raw-pointer UAF from a detached thread vs. shared_ptr fix
├── conanfile.txt          [requires] fmt/10.2.1
├── CMakeLists.txt         C++20, Release + -g -fno-omit-frame-pointer, never stripped
├── Containerfile          UBI 10 full image (builder AND runtime) + valgrind/lua
├── verify.lua             Lua 5.4 harness: TSan + Helgrind cross-checks, ASan assertions
├── demo.sh                the driver (docker build + docker run)
└── README.md              this file
```

### Why the runtime image is full `ubi10/ubi`, not `ubi-minimal`

Same reasoning as
[27-debugging-races-deadlocks](../27-debugging-races-deadlocks/#why-the-runtime-image-is-full-ubi10ubi-not-ubi-minimal):
Valgrind needs a real userspace beyond `microdnf`'s minimal package set,
and Helgrind/ASan both need the target binaries' debug symbols intact to
name a source line — nothing in this directory is ever stripped. Unlike
chapter 27's image, this one does **not** install `gdb`: this chapter's
`verify.lua` never attaches a debugger, so shipping one would be
unused tooling with no corresponding check.
