# concurrency/05-futex-cost — uncontended vs. contended mutex cost

Compendium reference:
[Doc 05 — Shared State and the Futex](../../../_docs/05-shared-state-and-the-futex.md)

The runnable companion to compendium Doc 05. The one-line takeaway: **an
uncontended lock is a single atomic instruction that never leaves user
space; a contended one crosses into the kernel, and that crossing costs
orders of magnitude more.**

## What it demonstrates

[`src/futex_cost.cpp`](src/futex_cost.cpp) performs the same fixed number
(`N`, default 200,000) of counter increments three ways, selected by
`--mode`:

- `baseline` — one thread, a plain non-atomic counter, no mutex at all. The
  floor every other mode is measured against.
- `uncontended` — one thread, the same loop, now wrapped in
  `std::lock_guard<std::mutex>` per iteration. Nothing else is running, so
  the compare-and-swap that acquires the lock never loses.
- `contended` — the same `N` increments split evenly (default 8 threads)
  across worker threads sharing one mutex, so the compare-and-swap
  genuinely fails often enough to park threads in the kernel.

The program prints one `key=value` line:

```
mode=contended threads=8 n=200000 count=200000 elapsed_ms=41.207
```

## Verification: verify.lua

[`verify.lua`](verify.lua) checks two things:

1. **Correctness is contention-independent (hard assertion).** The final
   `count` must equal `N` exactly in all three modes. Contention is a
   *performance* bug, never a correctness bug — any mismatch is a FAIL.
2. **The futex story (soft assertions).** `verify.lua` runs each mode a
   second time under `strace -f -e trace=futex` (from *outside* the
   binary) and counts `futex(` occurrences in the trace:
   - `futex(uncontended) == futex(baseline)` — an uncontended lock never
     reaches the kernel.
   - `futex(contended) > futex(uncontended) * 100` — contention is what
     crosses into the kernel, by orders of magnitude.

   Both are WARN-not-FAIL. Futex counts under contention are
   scheduling-dependent (chapter 5 is explicit about this), and `strace`
   itself depends on `ptrace`, which some container runtimes restrict or
   omit entirely (see the chapter's "Running in a container" section). If
   `strace` isn't on `PATH`, or it runs but produces no parseable output
   (ptrace denied), `verify.lua` falls back to a behavioral/timing
   comparison — CPU-time-weighted per-operation cost — rather than
   hard-failing on a missing or restricted tool.

`verify.lua` exits 0 whenever correctness holds, regardless of how the
futex/behavioral comparison came out, and non-zero on any correctness
failure.

### Why the syscall-count check is soft

Two independent sources of noise apply here, not one:

- **Scheduling.** The contended run's futex count depends on how often the
  compare-and-swap actually loses, which depends on thread placement, host
  load, and (per chapter 5) cgroup CPU quotas that stretch critical
  sections. A quiet host can show a smaller gap than a busy one without the
  underlying mechanism changing.
- **Tool availability.** `strace` requires `ptrace`, which a hardened
  container runtime, a restrictive seccomp profile, or
  `securityContext.allowPrivilegeEscalation: false` can all block. The
  futex mechanism itself is unaffected; only the ability to *observe* it
  from outside the process is.

## Running it

```bash
./demo.sh            # build + run futex_cost (all three modes) + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-05-futex-cost.sh`](../../../scripts/test-concurrency-demo-05-futex-cost.sh).

## Layout

```
05-futex-cost/
├── src/futex_cost.cpp   --mode baseline|uncontended|contended, prints key=value line
├── conanfile.txt        [requires] fmt/10.2.1
├── CMakeLists.txt       C++20, find_package(fmt), -O2, target futex_cost
├── Containerfile        UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua + strace (best-effort) runtime
├── verify.lua           Lua 5.4 assertion harness (correctness hard, futex/timing soft)
├── demo.sh              the driver (docker build + docker run)
└── README.md            this file
```

Follows the convention established in
[`../20-mechanical-sympathy/`](../20-mechanical-sympathy/README.md#convention-this-example-establishes).
