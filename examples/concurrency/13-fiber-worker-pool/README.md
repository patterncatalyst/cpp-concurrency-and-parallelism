# concurrency/13-fiber-worker-pool — fibers vs. threads, and the guard page

Compendium reference:
[Doc 13 — Fibers and Stackful Coroutines](../../../_docs/13-fibers-and-stackful-coroutines.md)

The runnable companion to compendium Doc 13. The chapter's central claim:
a fiber and an OS thread are the same *shape* of worker — something that
pulls work off a shared queue and processes it — at roughly two orders of
magnitude different memory cost per unit. This example builds that worker
loop once and runs it over both units of concurrency, plus a separate,
safely-contained demonstration of the guard page that turns a fiber stack
overflow into an immediate fault instead of silent corruption.

## What it demonstrates

[`src/fiber_worker_pool.cpp`](src/fiber_worker_pool.cpp) builds one
binary with two independent pieces:

### The worker pool (`pool --mode fiber|thread`)

One `worker_loop()` function, shared verbatim by both modes, pops
`std::uint64_t` work items off a `boost::fibers::buffered_channel` and
accumulates a count and a sum of squares into shared atomics:

- `--mode fiber` — N `boost::fibers::fiber` workers under Boost.Fiber's
  default `round_robin` scheduler, all cooperatively sharing this one OS
  thread.
- `--mode thread` — N `std::thread` workers, each an independent OS
  thread.

Both modes work against the *same* channel type and the *same* worker
function: `boost::fibers::buffered_channel` is explicitly safe to use from
a plain OS thread with no additional fibers running on it (every thread
has an implicit "main fiber" its blocking channel operations suspend),
which is what makes sharing one loop between the two concurrency models
possible at all.

### The guard page (`guard-page`)

`boost::context::protected_fixedsize_stack` maps one extra `PROT_NONE`
guard page beyond a fiber's requested stack. `recurse_until_guard_page()`
is a deliberately unbounded recursive function with a 4 KiB local per
call — on a 64 KiB stack, a handful of calls walks straight into the guard
page and faults immediately (`SIGSEGV`) rather than silently corrupting
whatever memory happened to sit past the mapping. This runs in a `fork()`ed
child (so the crash never takes down the demo process) under a 5-second
parent-side `alarm()` (so the demo always terminates even if, on some
kernel/arch, the fault doesn't fire the way expected).

The program prints `key=value` lines:

```
mode=fiber workers=8 items=100000 processed=100000 sum=333338333350000 elapsed_ms=12.345 rss_kb=9876
mode=thread workers=8 items=100000 processed=100000 sum=333338333350000 elapsed_ms=18.901 rss_kb=46512
guard_page_signaled=true guard_page_signal=11 guard_page_timed_out=false
```

## Verification: verify.lua

Lua 5.4, run inside the container, same contract as every sibling demo:

1. **Fiber-pool correctness (hard).** `processed == items` exactly, and
   the aggregate matches `verify.lua`'s own independently-computed closed
   form for the sum of squares (`N(N+1)(2N+1)/6`) — not merely an echo of
   whatever the C++ program itself claims the expected value is.
2. **Thread-pool correctness (hard).** The identical two checks for
   `--mode thread`, so both halves of the chapter's "same shape, two
   units of concurrency" claim are verified, not just one.
3. **Guard page (hard).** `protected_fixedsize_stack` must turn the
   overflow into a signal-terminated child, within the program's own
   5-second bound. This is deterministic kernel/MMU behavior (a guard page
   either faults or it doesn't), not a timing measurement, so it's a hard
   assertion like the two above rather than a soft one.
4. **RSS comparison (soft).** Peak RSS (`VmHWM` from `/proc/self/status`)
   for the fiber run vs. the thread run is reported, never asserted
   against a fixed ratio — exactly how much lower a given run's fiber-pool
   RSS comes in depends on allocator behavior and the container's own
   memory accounting, which the chapter's point doesn't require this one
   demo to reproduce precisely on every host to still be true in general.

## Running it

```bash
./demo.sh            # build + run fiber_worker_pool (both modes + guard-page) + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-13-fiber-worker-pool.sh`](../../../scripts/test-concurrency-demo-13-fiber-worker-pool.sh).

## Layout

```
13-fiber-worker-pool/
├── src/fiber_worker_pool.cpp   worker_loop() over a buffered_channel (fiber/thread modes) + guard-page demo
├── conanfile.txt               [requires] boost/1.84.0 (fiber+context only), fmt/10.2.1
├── CMakeLists.txt              C++20, find_package(Boost COMPONENTS fiber context), -O2
├── Containerfile                UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua                  Lua 5.4 assertion harness (pool + guard-page hard, RSS soft)
├── demo.sh                     the driver (docker build + docker run)
└── README.md                   this file
```

## Boost dependency notes

- **Static, not shared** (`boost/*:shared=False`). This sidesteps the
  runtime-lib-staging pattern `../01-execution-models/Containerfile` needs
  (there, oneTBB's Conan recipe requires its `hwloc` dependency to be
  shared) — the binary built here has no Conan-managed `.so` for the
  runtime stage to copy in at all.
- **Only `fiber` and `context` enabled** (plus `system`/`exception`, left
  at their defaults); every other Boost library this conanfile's recipe
  knows how to build (`regex`, `filesystem`, `iostreams`, `json`, `log`,
  `python`, `mpi`, …) is explicitly disabled via `without_*` options, so
  the dependency build compiles only what this example links against
  instead of Boost's much larger default set.

## Scope note

Compendium Doc 13's `<!-- EXAMPLE SPEC -->` also sketches running the
comparison once unconstrained and once under a `docker run --memory` cap,
to show the fiber pool sustaining a higher worker count under an identical
limit, and a side-by-side contrast against `fixedsize_stack` (no guard
page) "silently continuing" past an overflow. This example keeps the
guard-page demonstration to the deterministic, always-terminating
`protected_fixedsize_stack` case only: deliberately running
`fixedsize_stack` past its end is undefined behavior (an overrun
into whatever memory happens to be mapped next), not something this demo
can safely or deterministically reproduce for an assertion — the chapter
text's contrast between the two allocators is conceptual, not something
every runnable demo needs to trigger live.
