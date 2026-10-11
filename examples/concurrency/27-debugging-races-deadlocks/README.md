# concurrency/27-debugging-races-deadlocks — a real data race and a real AB/BA deadlock

Compendium reference:
[Doc 27 — Debugging Real Races and Deadlocks](../../../_docs/27-debugging-real-races-and-deadlocks.md)

The runnable companion to compendium Doc 27. Two small, deliberately broken
programs, each made to fail **every run** rather than occasionally:

- **`racy_counter`** — two `std::jthread`s increment a shared, non-atomic
  `int` with no synchronization. A plain run can print the correct total on
  one invocation and a corrupted one on the next; ThreadSanitizer is what
  actually proves the defect, independent of what any single run prints.
- **`ab_ba_deadlock`** — two `Account`s, two threads acquiring their
  mutexes in opposite order, forced into an AB/BA deadlock on every
  single run by a `std::latch`. `gdb -p <pid>` attaches to the live,
  permanently-hung process and reads the lock cycle straight off both
  threads' backtraces.

## What it demonstrates

### `racy_counter` — a real data race, caught by ThreadSanitizer

[`src/racy_counter.cpp`](src/racy_counter.cpp) is one source file compiled
**twice** by this demo's `Containerfile`: once plain, once with
`-fsanitize=thread`. The program itself doesn't know which build it is —
`--mode racy` runs two `std::jthread`s each calling a `noinline
increment(int&)` on a shared counter in a tight loop with no lock, no
atomic, and no other synchronization; `--mode fixed` does the identical
loop against a `std::atomic<int>&` instead.

```
racy_counter --mode racy|fixed [-n ITERATIONS]
```

```
mode=racy n=100000 counter=142857 expected=200000
```

A non-atomic `++counter` is a load, an add, and a store; with no
happens-before edge between the two threads, the C++ object model defines
this as a data race — undefined behavior, full stop, regardless of whether
`counter` happens to equal `expected` on a given run. The TSan build's job
is to prove that, not to wait for a wrong number to show up.

### `ab_ba_deadlock` — a real AB/BA deadlock, caught live by gdb

[`src/ab_ba_deadlock.cpp`](src/ab_ba_deadlock.cpp) models two `Account`s,
each with its own `std::mutex`. `run_transfer(from, to, ...)` locks
`from.mutex` then `to.mutex` — one thread calls it as
`run_transfer(account_b, account_a, ...)`, the other as
`run_transfer(account_a, account_b, ...)`, the textbook AB/BA shape.

```
ab_ba_deadlock --mode deadlock             # forces the deadlock; hangs forever
ab_ba_deadlock --mode fixed [-n ITERATIONS] # std::scoped_lock fix; always completes
```

Left to scheduling luck, AB/BA deadlocks only when both threads happen to
reach their *second* lock while the other already holds its first — a
window narrow enough to miss most runs on an idle machine. A
`std::latch(2)` closes that gap on purpose: both threads count down
immediately after acquiring their first lock and wait on the latch before
attempting their second, so neither can proceed until **both** already
hold their first. That turns "sometimes deadlocks" into "deadlocks on
every single run."

`run_transfer` is marked `__attribute__((noinline))` specifically so it
always shows up as its own frame in a gdb backtrace — the "Account-level
acquisition function" blocked in both threads, not an inlined fragment of
`main`.

## Verification: verify.lua

[`verify.lua`](verify.lua) runs inside the container (which ships the
binaries, `gdb`, and a `lua` interpreter) and checks, in order:

1. **TSan reports the race (hard, when the leg built and TSan can run).**
   `racy_counter_tsan --mode racy` must print `ThreadSanitizer: data race`
   naming `racy_counter.cpp`. `--mode fixed` must exit 0 with no report.
2. **The deadlock never resolves on its own (hard).** `ab_ba_deadlock
   --mode deadlock`, run under `timeout --signal=KILL`, must be killed —
   it never exits by itself.
3. **gdb reads the lock cycle live (hard, when gdb can attach).** A
   second, backgrounded instance of the same deadlock gets `gdb -p <pid>
   --batch -ex 'thread apply all bt'` attached to it. The combined
   backtrace must name `run_transfer` at least twice (both worker
   threads), show at least one thread parked in a mutex-lock/futex call,
   and report both `Thread 2` and `Thread 3` — the cycle, read directly
   off gdb's live inspection of the hung process, not inferred from
   source.
4. **The fixed build always completes (hard).** `ab_ba_deadlock --mode
   fixed` exits 0 with `total_ops` matching `2 * iterations`.

### Why some checks are SOFT, not hard

- **TSan leg unavailable or fails to initialize.** This UBI10 image's
  `libtsan` package may not be present on every repo set/arch, and
  ThreadSanitizer's shadow-memory reservation can fail to initialize under
  a restrictive container memory policy — a real, documented limitation
  (see `_docs/27-debugging-real-races-and-deadlocks.md`'s "Running in a
  container" section) independent of whether the race itself exists. If
  the TSan build wasn't produced, or its runtime prints `FATAL:
  ThreadSanitizer`, verify.lua reports a **SOFT SKIP** with a clear WARN
  rather than failing the whole demo.
- **gdb cannot attach.** If the container wasn't run with
  `--cap-add=SYS_PTRACE` (this demo's own `demo.sh` always adds it — see
  below), gdb's `ptrace: Operation not permitted` is an environment/
  capability problem, not a defect in the program being debugged, and is
  reported as a SOFT SKIP.

Both the deadlock-never-exits check (#2) and at least one of the
sanitizer/debugger paths (#1's TSan report when it can run, #3's gdb
attach) are HARD whenever the environment allows them to run at all — per
this project's convention, a soft skip documents an environment limit, it
never silently waves through a broken demo.

## Running in a container: why gdb needs extra flags

`gdb -p <pid>` attaching to an **already-running** process needs
`ptrace(2)` permission, which Docker withdraws by default (a default
container typically grants `CAP_SYS_PTRACE` only for tracing a process's
own children — enough for `gdb --batch -ex run` launching a target itself,
not enough for attaching to one started separately). [`demo.sh`](demo.sh)
runs this image with:

```bash
docker run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined "$IMG"
```

- `--cap-add=SYS_PTRACE` grants the capability the kernel checks first;
  without it the attach is refused outright.
- `--security-opt seccomp=unconfined` removes Docker's default seccomp
  filter as a second, broader belt-and-suspenders measure — some seccomp
  profiles only conditionally allow `ptrace(2)` even with the capability
  present, and this demo's entire purpose is debugging a live process
  inside its own container, so the extra permission is proportionate. A
  scoped custom seccomp profile allowlisting exactly `ptrace` is the
  better-practiced middle ground for a production debugging image; this
  demo takes the simpler, broader flag so it behaves the same way across
  hosts and Docker versions.

Neither flag reaches outside the container: `verify.lua` attaches to a
process it itself just started, in its own pid namespace.

TSan needs no `ptrace` at all — its instrumentation runs inside the traced
process itself, compiled in. What it does need is address space for its
shadow-memory bookkeeping, which an aggressive host/container memory
policy can reject; see the SOFT-skip behavior above.

## Running it

```bash
./demo.sh            # build + run (TSan + gdb checks) + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-27-debugging-races-deadlocks.sh`](../../../scripts/test-concurrency-demo-27-debugging-races-deadlocks.sh).

## Layout

```
27-debugging-races-deadlocks/
├── src/racy_counter.cpp      shared non-atomic int vs. atomic<int>, --mode racy|fixed
├── src/ab_ba_deadlock.cpp    Account AB/BA deadlock (latch-forced) vs. scoped_lock fix
├── conanfile.txt             [requires] fmt/10.2.1
├── CMakeLists.txt            C++20, Release + -g -fno-omit-frame-pointer, never stripped
├── Containerfile             UBI 10 full image (builder AND runtime) + gdb/lua
├── verify.lua                Lua 5.4 harness: TSan report assertions + live gdb attach
├── demo.sh                   the driver (docker build + docker run --cap-add=SYS_PTRACE ...)
└── README.md                 this file
```

### Why the runtime image is full `ubi10/ubi`, not `ubi-minimal`

Every other example in this project (starting with
[20-mechanical-sympathy](../20-mechanical-sympathy/)) ships its runtime
stage on `ubi10/ubi-minimal` and strips its binary. This demo does
neither: `gdb` needs a real debugger-capable userspace well beyond
`microdnf`'s minimal package set provides, and both `gdb` and
ThreadSanitizer need the target binaries' debug symbols intact to name a
frame or a source line at all — stripping here would defeat the entire
point of the chapter.
