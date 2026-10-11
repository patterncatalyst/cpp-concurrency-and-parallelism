# concurrency/01-execution-models — the four execution models, counted

Compendium reference:
[Doc 1 — Concurrency vs Parallelism](../../../_docs/01-concurrency-vs-parallelism.md)

The runnable companion to compendium Doc 1. The one-line takeaway:
**concurrency (structure) and parallelism (execution) are independent
axes**, so crossing them produces four real execution models, not two, and
the only reliable way to tell them apart is to count what actually happened
rather than time how long it took.

## What it demonstrates

[`src/execution_models.cpp`](src/execution_models.cpp) runs the same
instrumented `process()` workload under all four models from the chapter and
prints three counted observables per model instead of a duration:

- **`distinct_cpus`** — popcount of the union of every `sched_getcpu()`
  reading taken during the run (a vDSO read, no syscall — Chapter 3 explains
  why that matters).
- **`max_inflight`** — high-water mark of a start/finish counter, recorded
  with the chapter's compare-exchange loop (`bump_max_inflight`) so the
  observation itself never serializes the very tasks it's watching.
- **`interleaves`** — count of tasks whose own two ticket draws, from one
  shared atomic counter around a work window, were *not* consecutive — proof
  some other task's sample point landed between them.

The four models:

| model | threads | pinning | what it proves |
| --- | --- | --- | --- |
| `sequential` | none | main thread pinned to 1 CPU | baseline: neither concurrent nor parallel |
| `concurrent_pinned` | 256 `jthread`s | every worker self-pins to the *same* CPU | structure without parallelism |
| `parallel` | none visible | `std::execution::par` | parallelism without visible structure |
| `both` | `2×hardware_concurrency()` `jthread`s | unpinned | oversubscribed: real shape of a loaded thread pool |

The program prints one `num_available_cpus=` line, then one `model=...` line
per model, all in a `key=value` form trivial to parse:

```
num_available_cpus=8
model=sequential distinct_cpus=1 max_inflight=1 interleaves=0
model=concurrent_pinned distinct_cpus=1 max_inflight=37 interleaves=241
model=parallel distinct_cpus=6 max_inflight=6 interleaves=199
model=both distinct_cpus=7 max_inflight=15 interleaves=203
```

This is the project's **first example to need oneTBB**. GCC's libstdc++
implements the C++17 parallel execution policies
(`std::execution::par`, the `parallel` model here) on top of a
PSTL-over-TBB backend: code that calls it fails to *link*, not just to run
in parallel, without `-ltbb`. `conanfile.txt` pulls `onetbb/2021.10.0` for
exactly that reason — nothing else in this example needs an external
dependency.

### Why main() restores its own affinity between models

The `sequential` model pins the process's one and only thread to a single
CPU so a lightly-loaded host can't migrate it mid-run and manufacture a
false "touched two CPUs" reading. `main()` restores the original affinity
mask immediately afterward, before running any other model — a new thread
inherits the affinity of the thread that creates it, and `std::execution::par`
typically creates its worker pool lazily on first use. Leaving the main
thread pinned down past the sequential model would risk silently confining
that pool (and the unpinned `jthread`s in `both`) to the same single CPU,
which would make `parallel` and `both` structurally unable to show
`distinct_cpus>1` through no fault of their own code.

## Verification: verify.lua

[`verify.lua`](verify.lua) runs inside the container and checks, per trial
(default 3 trials):

1. **`sequential` (hard, every trial).** `distinct_cpus==1`,
   `interleaves==0`, and `max_inflight==1`. All three are environment-
   independent: there is exactly one thread in the whole process while this
   model runs, and the program pins it itself.
2. **`concurrent_pinned` (hard, every trial).** `distinct_cpus==1` (every
   worker self-pins to the same cpu id) and `max_inflight>1` (many
   `jthread`s overlap while pinned to that one CPU — a periodic
   `std::this_thread::yield()` inside the work window gives the scheduler
   real chances to interleave them).
3. **`parallel`/`both` (conditionally hard).** `distinct_cpus>1` is only
   physically achievable when the container's own cpuset offers 2+ CPUs.
   When it does (`num_available_cpus>=2`), the harness requires the signal
   to show up in at least one of several trials — a **hard** failure if it
   never does. When the cpuset offers only one CPU, the check becomes a
   **soft** WARN instead of a failure, the same pattern
   `20-mechanical-sympathy`'s timing check uses for a signal the environment
   can mute without the fix being wrong.

`verify.lua` exits 0 on pass (with or without the `parallel`/`both` WARN)
and non-zero on any hard failure.

## Running it

```bash
./demo.sh            # build + run execution_models + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-01-execution-models.sh`](../../../scripts/test-concurrency-demo-01-execution-models.sh).

To see the gap a CPU-limited container creates, per the chapter's "Running
in a container" section, run the image with `--cpus=2` or `--cpus=1`
directly and compare `distinct_cpus` for `parallel`/`both` against an
unconstrained run:

```bash
docker run --rm --cpus=1 cpp-tut/concurrency-01-execution-models:latest
```

## Layout

```
01-execution-models/
├── src/execution_models.cpp   four execution models, instrumented with counted observables
├── conanfile.txt              [requires] onetbb/2021.10.0 — needed for std::execution::par to link
├── CMakeLists.txt             C++20, find_package(TBB), -O2, target execution_models
├── Containerfile               UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua                  Lua 5.4 assertion harness (sequential/concurrent_pinned hard, parallel/both conditionally hard)
├── demo.sh                     the driver (docker build + docker run)
└── README.md                   this file
```
