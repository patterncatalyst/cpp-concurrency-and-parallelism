# concurrency/32-concurrency-in-containers — cgroup cpu.max vs. hardware_concurrency()

Compendium reference:
[Doc 32 — Concurrency in Containers](../../../_docs/32-concurrency-in-containers.md)

The runnable companion to compendium Doc 32. The one-line takeaway:
**`std::thread::hardware_concurrency()` tracks a cpuset restriction but
never a cgroup CPU quota** — a container given `--cpus=2` with no
accompanying `--cpuset-cpus` still reports the host's full core count,
because a time budget doesn't remove any core from the set a thread could
be scheduled onto; it only limits how much aggregate time the cgroup's
threads may spend.

## What it demonstrates

[`src/cgroup_probe.cpp`](src/cgroup_probe.cpp) builds one binary,
`cgroup_probe`, that:

1. Reads `/sys/fs/cgroup/cpu.max` (cgroup v2), folding every "no usable
   quota" case — the file missing entirely (cgroup v1, or no cgroups at
   all), unreadable, malformed, or the literal string `"max"` — into the
   same empty state, exactly as the chapter's `std::optional<double>`-
   returning `cgroup_cpu_quota()` does. **Every `/sys` read is guarded —
   the program never crashes on a missing or unexpected layout.**
2. Reads `std::thread::hardware_concurrency()` and, separately, the
   `sched_getaffinity`-derived cpuset-visible core count.
3. Derives a pool size: an orchestrator-supplied `CPU_LIMIT` env var wins
   outright; otherwise the tighter of the quota and the affinity count
   when a quota exists, else the affinity count (or
   `hardware_concurrency()` as a last resort).
4. Runs a small, fixed, CPU-bound **pool-bench** — each of `pool_size`
   worker threads does the same bounded amount of arithmetic — so the
   example demonstrates actually *using* the derived pool size, not just
   printing numbers.

The program prints one line in a `key=value` form that's trivial to
parse:

```
hardware_concurrency=16 affinity_count=16 quota=unlimited pool_size=16 bench_iters=2000000 pool_bench_ms=41.117
```

This is the project's second example to use Conan (`fmt`, for output
formatting only — the cgroup read, affinity query, and pool-bench are
pure standard library plus `<sched.h>`), following the
`conanfile.txt` + `CMakeDeps`/`CMakeToolchain` pattern
[20-mechanical-sympathy](../20-mechanical-sympathy/) establishes.

## Verification: verify.lua

Same Lua 5.4 assertion-harness convention as
[20-mechanical-sympathy](../20-mechanical-sympathy/):
[`verify.lua`](verify.lua) runs inside the container (which ships both
the binary and a `lua` interpreter) and checks:

1. **The binary runs and its output parses (hard).** A crash or an
   unparseable line means the `/sys/fs/cgroup` read or the pool-bench
   itself is broken — independent of which cgroup environment the
   container happens to be running under.
2. **Every reported number is sane (hard).** `hardware_concurrency`,
   `affinity_count`, and `pool_size` must each be positive integers;
   `pool_bench_ms` must be non-negative.
3. **The fallback/unlimited path (hard).** A plain `docker run` (no
   `--cpus`/`--cpuset-cpus`) always makes `cpu.max` read `"max"`.
   `verify.lua` asserts `quota=unlimited` **and** that `pool_size`
   actually equals `affinity_count` — i.e. the program took the
   no-quota fallback branch rather than silently mis-sizing the pool.
   This is the path every CI run exercises, and it's a hard assertion.
4. **The quota path (soft).** If — and only if — this container was
   started with a real CPU limit (`quota=` is a finite number, not
   `"unlimited"`), `verify.lua` checks that `pool_size` tracks
   `floor(min(quota, affinity_count))` and stays at or below
   `hardware_concurrency()`. This is the quota-vs-`hardware_concurrency()`
   distinction the chapter is actually about — but a default `docker run`
   never supplies a quota, so this check can only fire when a human (or a
   CI job configured to do so) deliberately starts the container with
   `--cpus=N`. It's therefore a **soft (WARN, not FAIL)** check, and
   mostly a no-op in an ordinary automated run.

`verify.lua` exits 0 on pass (with or without the quota-path WARN) and
non-zero on any hard failure, printing a readable summary either way.

### Seeing the quota path

Under the default, unconstrained container the fallback path is all
there is to see. To watch the actual quota-vs-`hardware_concurrency()`
gap the chapter describes, run the image with a CPU limit directly:

```bash
# Build once, then run with a real quota (SOFT/manual — not part of CI):
docker build -t cpp-tut/concurrency-32-concurrency-in-containers:latest .
docker run --rm --cpus=1 cpp-tut/concurrency-32-concurrency-in-containers:latest

# Or via demo.sh's --cpus=N pass-through:
./demo.sh --cpus=1
```

On a multi-core host this makes `quota=1.00` while `hardware_concurrency`
stays at the host's full core count — `pool_size` follows the quota, not
`hardware_concurrency()`. `verify.lua`'s quota-path check then reports
`PASS` for that branch too, instead of being skipped. The project's CI
wrapper (below) only ever exercises the default, unconstrained path —
running with `--cpus=N` is a manual exercise for a reader on their own
machine, not an automated gate.

## Running it

```bash
./demo.sh              # build + run cgroup_probe + verify.lua (fallback path)
./demo.sh --cpus=1     # same, but with a real cgroup quota (see above)
./demo.sh --clean      # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-32-concurrency-in-containers.sh`](../../../scripts/test-concurrency-demo-32-concurrency-in-containers.sh)
(runs the default, unconstrained path only — the hard assertions above).

### Observed run

```
== verify.lua: 32-concurrency-in-containers (cgroup-probe + pool-bench) ==
  raw output: hardware_concurrency=16 affinity_count=16 quota=unlimited pool_size=16 bench_iters=2000000 pool_bench_ms=41.117
  hardware_concurrency: PASS (16)
  affinity_count: PASS (16)
  pool_size: PASS (16)
  pool_bench_ms: PASS (41.117 ms, pool_size=16 workers completed)
  quota: unlimited (expected under a plain `docker run` with no --cpus)
  fallback path: PASS (no quota -- pool_size=16 matches affinity_count)
RESULT: PASS
```

## Layout

```
32-concurrency-in-containers/
├── src/cgroup_probe.cpp   reads cpu.max + hardware_concurrency(), sizes + runs a pool-bench
├── conanfile.txt          [requires] fmt/10.2.1 — output formatting only
├── CMakeLists.txt         C++20, find_package(fmt), -O2, target cgroup_probe
├── Containerfile          UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua             Lua 5.4 assertion harness (fallback path hard, quota path soft)
├── demo.sh                the driver (docker build + docker run, --cpus=N pass-through)
└── README.md              this file
```

## Why the quota check is soft

A cgroup CPU quota is a property of how the *container itself* is
started (`docker run --cpus=N`, a Kubernetes `resources.limits.cpu`),
not something this example's own build or runtime can manufacture from
inside the image. The fallback path (no quota at all) is the only
configuration a default, unconstrained `docker run` and this project's CI
wrapper can reach, so it's the one this example holds to a hard
assertion. The quota path is real and checked — `verify.lua` does not
skip it silently — but it can only be exercised by whoever launches the
container, which is why it's documented here as something to try
manually rather than wired into the non-interactive CI gate.
