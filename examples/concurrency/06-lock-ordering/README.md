# concurrency/06-lock-ordering — AB/BA deadlock, lock_guard vs. scoped_lock

Compendium reference:
[Doc 06 — Mutual Exclusion and Locking](../../../_docs/06-mutual-exclusion-and-locking.md)

The runnable companion to compendium Doc 06. The one-line takeaway:
**two threads that acquire the same two mutexes in opposite order will
deadlock with `std::lock_guard`, and cannot with `std::scoped_lock`** --
not "deadlock less often," but cannot, because `scoped_lock`'s internal
algorithm does not care what order its own argument list names.

## What it demonstrates

[`src/lock_ordering.cpp`](src/lock_ordering.cpp) has two mutexes, `a` and
`b`, and two threads that acquire them in opposing order, selected by
`--mode`:

- `--mode deadlock` — Thread 1 takes `a` then `b`; thread 2 takes `b` then
  `a`, both with `std::lock_guard`. A `std::latch(2)` forces the race
  deterministically: each thread reaches the latch only after it holds its
  *first* lock, and the latch does not release either thread until *both*
  have arrived — so by the time either thread reaches for its second lock,
  the other is guaranteed to already hold it. This is the textbook
  circular wait, made to happen on every run instead of depending on raw
  scheduling luck. **This mode never exits on its own** — that non-exit
  *is* the demonstration.
- `--mode fixed` — the same opposing order, repeated for a fixed number of
  iterations, using `std::scoped_lock(a, b)` / `std::scoped_lock(b, a)`
  instead. Always completes and exits 0.

## Verification: verify.lua

[`verify.lua`](verify.lua) checks two things, both **hard** assertions —
unlike chapter 5's timing comparison, a `std::latch`-forced deadlock has no
inherent scheduling noise to make soft:

1. **The deadlock build reliably hangs.** `verify.lua` runs it under an
   in-container `timeout` (default 3s, `--signal=KILL`) and asserts
   `timeout` had to kill it — if the process ever exits 0 on its own, the
   forced deadlock didn't reproduce, and that's a FAIL.
2. **The fixed build always completes correctly.** `verify.lua` runs it
   (also under a generous safety-net `timeout`, since nothing should ever
   make `verify.lua` itself hang) and asserts it exits 0 with
   `total_ops == 2 * iterations` — one worker per acquisition order, each
   doing `iterations` acquisitions.

As a bonus, **soft and purely informational**, `verify.lua` also starts a
fresh instance of the deadlock build, waits briefly, and reads
`/proc/<pid>/task/*/wchan` for every thread — the outside-the-process
evidence chapters 5 and 6 both point to that a deadlocked thread is parked
in the kernel's futex wait queue, not spinning or crashed. This never
affects PASS/FAIL: `wchan` readability depends on procfs details
(`kptr_restrict`, PID-namespace visibility) that aren't guaranteed to be
identical across every container runtime.

## Running it

```bash
./demo.sh            # build + run lock_ordering (both modes) + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-06-lock-ordering.sh`](../../../scripts/test-concurrency-demo-06-lock-ordering.sh).

## Layout

```
06-lock-ordering/
├── src/lock_ordering.cpp   --mode deadlock|fixed, latch-forced AB/BA deadlock vs. scoped_lock fix
├── conanfile.txt           [requires] fmt/10.2.1
├── CMakeLists.txt          C++20, find_package(fmt), -O2, target lock_ordering
├── Containerfile           UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua + full coreutils runtime
├── verify.lua              Lua 5.4 assertion harness (both hard: deadlock hangs, fixed exits 0 correctly)
├── demo.sh                 the driver (docker build + docker run)
└── README.md               this file
```

Follows the convention established in
[`../20-mechanical-sympathy/`](../20-mechanical-sympathy/README.md#convention-this-example-establishes).
