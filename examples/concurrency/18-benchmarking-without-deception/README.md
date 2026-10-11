# concurrency/18-benchmarking-without-deception — the chapter's own harness, checked against itself

Compendium reference:
[Doc 18 — Benchmarking Without Deception](../../../_docs/18-benchmarking-without-deception.md)

The runnable companion to compendium Doc 18. The one-line takeaway: **this
chapter's harness doesn't just describe warmup, coordinated omission, and
percentiles — it implements all three against a trivial, fixed workload so
every number it prints can be checked against a real invariant instead of
trusted on faith.**

## What it demonstrates

[`src/bench.cpp`](src/bench.cpp) runs one atomic `fetch_add` per iteration —
a workload deliberately too simple to have any behavior of its own, so
every result traces back to the harness, not the thing being measured.

Default (harness) mode:

1. Discards `--warmup` throwaway iterations, untimed.
2. Times `--iters` remaining iterations individually between two
   `steady_clock` reads, folding each iteration's `fetch_add` return value
   into a checksum the program reads back at the end — an observably used
   result the optimizer can't prove is dead code, and simultaneously a
   correctness check: a fixed iteration count has one unique, closed-form
   expected checksum.
3. Sorts the raw samples and reports `min`/`median`/`p99`/`max`.
4. Runs the coordinated-omission backfill over the same raw samples — for
   every sample exceeding the run's own median (used as the expected
   per-operation interval `E`), synthesizing the queued-behind samples a
   fixed-rate caller would actually have experienced — and reports
   `co_p99`/`co_n` alongside the raw figures.

```
mode=harness n=50000 warmup=5000 min_ns=21 median_ns=34 p99_ns=118 max_ns=40221 co_p99_ns=142 co_n=50644 checksum=1276287500 expected_checksum=1276287500 checksum_ok=true
```

`--naive` mode skips warmup entirely and times the whole `--iters` loop as
**one** wall-clock sample — no per-iteration samples exist, so no
percentile of any kind is computed or printed:

```
mode=naive n=50000 elapsed_ns=1842933 checksum=1249975000 expected_checksum=1249975000 checksum_ok=true
```

That absence — no `min_ns`, no `median_ns`, no `p99_ns`, no `co_p99_ns` —
is the methodology gap this chapter argues against, made
visible in the program's own output instead of only in prose.

`fmt` is pulled in for output formatting only, the same role it plays in
`20-mechanical-sympathy`.

## Verification: verify.lua

[`verify.lua`](verify.lua) runs inside the container and checks, all as
**hard** assertions — this example's claims are about its own bookkeeping,
never a specific nanosecond figure a host could make noisy:

1. **Percentile ordering.** `min_ns <= median_ns <= p99_ns <= max_ns`.
2. **Coordinated-omission invariant.** `co_p99_ns >= p99_ns` — true by
   construction of the backfill algorithm, the cheapest sanity check the
   chapter says a harness can run on itself.
3. **`co_n >= n`.** The backfill only ever adds synthetic samples, never
   removes raw ones.
4. **Checksum correctness**, in both modes: the accumulated checksum must
   equal the closed-form expected sum for that exact sequence of
   single-threaded `fetch_add` calls.
5. **`--naive` omits every percentile field** (`min_ns`, `median_ns`,
   `p99_ns`, `max_ns`, `co_p99_ns`) — their absence is a direct,
   checkable property of which code path ran.

`verify.lua` exits 0 on pass and non-zero on any failure.

## Running it

```bash
./demo.sh            # build + run bench (harness + --naive) + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-18-benchmarking-without-deception.sh`](../../../scripts/test-concurrency-demo-18-benchmarking-without-deception.sh).

Per the chapter's "Running in a container" section, compare a
`taskset`-pinned invocation against an unpinned one to see migration-
induced variance show up in `max_ns` (requires `taskset`, from
`util-linux`, on the *host* invoking `docker run` — it is intentionally
not installed in the minimal runtime image):

```bash
taskset -c 0 docker run --rm cpp-tut/concurrency-18-benchmarking-without-deception:latest \
    bench --iters 50000 --warmup 5000
docker run --rm cpp-tut/concurrency-18-benchmarking-without-deception:latest \
    bench --iters 50000 --warmup 5000
```

## Layout

```
18-benchmarking-without-deception/
├── src/bench.cpp   warmup + per-iteration timing + percentiles + coordinated-omission backfill + --naive
├── conanfile.txt   [requires] fmt/10.2.1 — output formatting only
├── CMakeLists.txt  C++20, find_package(fmt), -O2, target bench
├── Containerfile   UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua      Lua 5.4 assertion harness (all hard: invariants and checksums, never an absolute number)
├── demo.sh         the driver (docker build + docker run)
└── README.md       this file
```
