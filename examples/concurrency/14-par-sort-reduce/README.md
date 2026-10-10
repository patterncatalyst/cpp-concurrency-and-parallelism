# concurrency/14-par-sort-reduce — seq vs par vs par_unseq

Compendium reference:
[Doc 14 — Parallel Algorithms and Execution Policies](../../../_docs/14-parallel-algorithms-and-execution-policies.md)

The runnable companion to compendium Doc 14. The one-line takeaway: **the
execution policy changes how an algorithm's work gets scheduled, never what
the answer is** — `std::execution::seq`, `par`, and `par_unseq` applied to
the same sort or the same reduction over the same input must produce the
identical result, and any difference between them is a correctness bug
regardless of which policy ran faster.

## What it demonstrates

[`src/par_sort_reduce.cpp`](src/par_sort_reduce.cpp) generates one
pseudo-random `uint64_t` dataset (fixed seed, so it's identical on every
run) and then, once per execution policy (`seq`, `par`, `par_unseq`):

- **Sorts** a fresh copy of the dataset with `std::sort(policy, ...)`,
  timing it and hashing the sorted output (order-sensitive FNV-1a) instead
  of printing a multi-million-element array.
- **Reduces** the original dataset with
  `std::transform_reduce(policy, ..., std::plus<>(), mix)`, where `mix` runs
  a configurable number of rounds (`-w`) of deterministic splitmix64-style
  mixing per element — synthetic per-element work, so the comparison has
  something for `par`/`par_unseq` to actually amortize their dispatch
  overhead against, per the chapter's `N × w` vs. `c` crossover discussion.
  The combining operation is `std::plus<std::uint64_t>` — exactly
  associative and commutative under well-defined wraparound arithmetic — so
  the sum is bit-identical no matter what order partial sums from different
  threads combine in. (`std::reduce`/`transform_reduce` on *floating-point*
  data would not have this guarantee; the chapter calls that out explicitly,
  and this example sidesteps it by using an exact integer sum.)
- **Records which CPUs it ran on** during the reduce step, via the same
  `sched_getcpu()`-union technique sibling example `01-execution-models`
  uses: each invocation of the reduce's callable OR's its CPU id into a
  shared atomic bitmask, and `distinct_cpus` is the popcount of that mask
  once the algorithm returns.

This is the project's second example to depend on **oneTBB**, after
`01-execution-models`: GCC's libstdc++ implements `std::execution::par` (and
`par_unseq`) on a PSTL-over-TBB backend, so `std::sort(std::execution::par,
...)` and `std::transform_reduce(std::execution::par, ...)` fail to **link**
without it, independent of whether the policy is honored at runtime. The
`conanfile.txt` here is the project's known-good oneTBB recipe:

```
[options]
onetbb/*:shared=False
hwloc/*:shared=True
```

A plain `onetbb/2021.10.0` requirement without those exact options fails to
build — oneTBB's own Conan recipe requires its `hwloc` dependency built
shared.

The program prints one header line and one `key=value` line per policy:

```
num_available_cpus=4 n=2000000 w=30
policy=seq       sort_ms=123.456 sort_hash=89abcdef01234567 reduce_ms=45.678 reduce_sum=18446744071562067968 distinct_cpus=1
policy=par       sort_ms=45.678  sort_hash=89abcdef01234567 reduce_ms=12.345 reduce_sum=18446744071562067968 distinct_cpus=4
policy=par_unseq sort_ms=44.123  sort_hash=89abcdef01234567 reduce_ms=12.001 reduce_sum=18446744071562067968 distinct_cpus=3
```

## Verification: verify.lua

This project's assertion harness is **Lua 5.4**, run inside the container.
[`verify.lua`](verify.lua) checks two things, across several trials:

1. **Correctness is policy-independent (hard assertion).** `sort_hash` and
   `reduce_sum` must match exactly across `seq`/`par`/`par_unseq` within a
   trial, and across trials too (the dataset is generated from a fixed
   seed, so a correct, deterministic program reproduces the same hash/sum
   every run). Any mismatch is a FAIL — this is what the chapter calls the
   sharpest fact in this area: a parallel algorithm whose *result* depends
   on evaluation order needs an associative/commutative combining operation
   before parallelizing it is even meaningful, and this example is built so
   that requirement is met by construction (exact unsigned-integer sum), not
   by luck.
2. **`par` touches more than one CPU is reported as a soft signal.** The
   standard *permits* `std::execution::par` to run its callable from
   multiple threads; it does not *require* a parallel STL implementation to
   split any specific workload across more than one. If the container's own
   cpuset offers at least 2 CPUs (`num_available_cpus>=2`) and `par` never
   shows `distinct_cpus>1` across all trials, `verify.lua` prints a WARN and
   still passes — correctness (checked above) is unaffected either way. If
   the cpuset offers only 1 CPU, `distinct_cpus>1` isn't physically
   achievable regardless of the code, so that case is also a WARN, not a
   FAIL.

**No speedup ratio is ever asserted.** `sort_ms`/`reduce_ms` are printed for
context only — the chapter is explicit that a bare speedup number depends on
hardware and scheduler state this harness doesn't control, and asserting one
would make the test flaky for reasons that have nothing to do with whether
the code is correct.

`verify.lua` exits 0 on pass (with or without the CPU-usage WARN) and
non-zero on any hard failure.

## Running it

```bash
./demo.sh                 # build + run par_sort_reduce + verify.lua (--cpus=4)
./demo.sh --clean         # remove the image
DEMO_NO_PAUSE=1 ./demo.sh       # skip the presenter pause (CI / scripted)
DEMO_CPUS=2 ./demo.sh           # change the container's CPU allotment
```

This example runs in plain Docker with an explicit `--cpus` limit — never a
KVM lab, never a host-level CPU/NUMA/governor change. The assertions here
only need the *sign* of "did `par` use more than one CPU," not a
reproducible speedup number, so a container's own cpuset is sufficient and
the demo never has to touch anything about the host it runs on.

CI verification:
[`../../../scripts/test-concurrency-demo-14-par-sort-reduce.sh`](../../../scripts/test-concurrency-demo-14-par-sort-reduce.sh).

## Layout

```
14-par-sort-reduce/
├── src/par_sort_reduce.cpp   seq/par/par_unseq sort + transform_reduce, prints key=value lines
├── conanfile.txt             [requires] onetbb/2021.10.0, fmt/10.2.1 — known-good TBB options
├── CMakeLists.txt            C++20, find_package(TBB)+fmt, -O2, target par_sort_reduce
├── Containerfile             UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua                Lua 5.4 assertion harness (correctness hard, CPU usage soft)
├── demo.sh                   the driver (docker build + docker run --cpus)
└── README.md                 this file
```
