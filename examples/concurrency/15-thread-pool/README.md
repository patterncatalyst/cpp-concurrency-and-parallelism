# concurrency/15-thread-pool — single shared queue vs. work-stealing deques

Compendium reference:
[Doc 15 — Thread Pools and Work Scheduling](../../../_docs/15-thread-pools-and-work-scheduling.md)

The runnable companion to compendium Doc 15. The one-line takeaway:
**a single shared queue turns every worker into a competitor for one lock,
and `hardware_concurrency()` never knows about a container's CPU quota** —
both are failure modes that show up as a throughput ceiling, not an
obvious bug.

## What it demonstrates

[`src/pool_bench.cpp`](src/pool_bench.cpp) builds two pool designs and runs
the identical CPU-bound task mix (a fixed sum-of-squares loop) through
each:

- `SingleQueuePool` — one `mutex`+`condition_variable`-guarded deque every
  worker pops from. Simple and correct; every push and pop serializes
  through the same lock.
- `WorkStealingPool` — each worker owns a mutex-guarded deque of its own.
  The owner pushes/pops its own deque's **bottom** (LIFO — the freshest
  task is also the most cache-hot one); an idle worker steals from a busy
  neighbor's **top** (FIFO — the oldest queued task), so an owner and a
  thief only ever contend when a deque holds exactly one item. This is a
  teaching-grade mutex-per-deque implementation, not the lock-free
  Chase-Lev deque production pools use — the chapter is explicit that even
  a naive version keeps contention rare, because stealing only happens
  when a worker is starved.

```
kind=single   workers=2  tasks=6000 work_iters=4000 completed=6000 elapsed_ms=812.441 throughput_tasks_per_sec=7385.6 avg_queue_wait_us=203.117
kind=stealing workers=2  tasks=6000 work_iters=4000 completed=6000 elapsed_ms=798.902 throughput_tasks_per_sec=7510.3 avg_queue_wait_us=41.882
kind=single   workers=16 tasks=6000 work_iters=4000 completed=6000 elapsed_ms=301.774 throughput_tasks_per_sec=19882.1 avg_queue_wait_us=612.558
kind=stealing workers=16 tasks=6000 work_iters=4000 completed=6000 elapsed_ms=118.233 throughput_tasks_per_sec=50747.0 avg_queue_wait_us=22.904
```

[`src/cgroup_probe.cpp`](src/cgroup_probe.cpp) reads the cgroup CPU
quota — `cpu.max` under cgroup v2, falling back to
`cpu.cfs_quota_us`/`cpu.cfs_period_us` under v1 — and derives the
CPU-equivalent count the kernel will actually schedule this process onto
per period, printed alongside `hardware_concurrency()` for comparison:

```
source=cgroupv2 quota_us=200000 period_us=100000 cpu_equivalents=2 hardware_concurrency=64
```

Run without a `--cpus` limit (this demo's default), `cpu.max` reads `max`
and the probe correctly falls back to `hardware_concurrency()` — that
fallback is the expected, documented behavior for an unconstrained run,
not a bug.

Both binaries pull in `fmt` for output formatting only, the same role it
plays in `20-mechanical-sympathy`.

## Verification: verify.lua

[`verify.lua`](verify.lua) runs inside the container and checks:

1. **Correctness (hard).** Both pool kinds, at a low worker count and a
   high worker count, must complete every submitted task exactly once.
   This never depends on timing — it's "did the pool lose or duplicate
   work."
2. **Throughput shape (soft).** The work-stealing pool's throughput should
   sit close to the single-queue pool's at the low worker count and pull
   ahead once worker count passes the high count — the chapter's central
   claim. This needs the container to actually have enough real cores for
   the single queue's lock to become contended; too few cores (or a noisy
   shared host) prints a WARN rather than failing the run.
3. **cgroup probe (soft).** Reported for inspection. An unconstrained run
   falling back to `hardware_concurrency()` is the correct, expected
   outcome and prints WARN/INFO, never a failure. Setting
   `EXPECTED_CPU_EQUIVALENTS` (paired with manually running the image
   under `docker run --cpus=N`) turns the comparison into a checked, but
   still soft, assertion.

`verify.lua` exits 0 on pass (with or without a WARN) and non-zero only on
a correctness hard failure.

## Running it

```bash
./demo.sh            # build + run pool_bench/cgroup_probe + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-15-thread-pool.sh`](../../../scripts/test-concurrency-demo-15-thread-pool.sh).

To see `cgroup_probe` pick up a real quota, and to check it against a
known value, run the image directly under `--cpus`:

```bash
docker run --rm --cpus=2 -e EXPECTED_CPU_EQUIVALENTS=2 \
    cpp-tut/concurrency-15-thread-pool:latest
```

## Layout

```
15-thread-pool/
├── src/pool_bench.cpp      SingleQueuePool + WorkStealingPool, same task mix, throughput + queue-wait report
├── src/cgroup_probe.cpp    cpu.max / cpu.cfs_quota_us+period_us vs. hardware_concurrency()
├── conanfile.txt           [requires] fmt/10.2.1 — output formatting only
├── CMakeLists.txt          C++20, find_package(fmt), -O2, targets pool_bench + cgroup_probe
├── Containerfile           UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua              Lua 5.4 assertion harness (correctness hard; throughput shape + cgroup soft)
├── demo.sh                 the driver (docker build + docker run)
└── README.md               this file
```
