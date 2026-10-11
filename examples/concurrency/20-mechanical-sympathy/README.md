# concurrency/20-mechanical-sympathy — false sharing vs. cache-line padding

Compendium reference:
[Doc 20 — Mechanical Sympathy](../../../_docs/20-mechanical-sympathy.md)

The runnable companion to compendium Doc 20. The one-line takeaway:
**two threads that touch completely disjoint data can still serialize on
each other** if that data shares a 64-byte cache line, because the
cache-coherence protocol invalidates whole lines, not the individual bytes
a program actually reads or writes.

## What it demonstrates

[`src/false_sharing.cpp`](src/false_sharing.cpp) runs two threads, each
`fetch_add`-ing its own `std::atomic<uint64_t>` counter N times, pinned to
separate CPUs (`pthread_setaffinity_np`, using whatever two CPU ids are in
the process's own cpuset — so it pins correctly even under a container CPU
limit). A `--pad on|off` flag selects the struct layout:

- `--pad off` — `UnpaddedCounters`: the two atomics sit next to each other
  with no spacing hint, so on essentially any real compiler/ABI they share
  one cache line. Every increment on one core invalidates the other core's
  cached copy of that line, even though the two threads never touch each
  other's bytes.
- `--pad on` — `PaddedCounters`: each atomic is
  `alignas(std::hardware_destructive_interference_size)`, forcing it onto
  its own line. The two cores stop paying coherence traffic for data they
  never share.

The program prints one line in a `key=value` form that's trivial to parse:

```
mode=padded pinned=true cpus=0/1 n=20000000 count_a=20000000 count_b=20000000 elapsed_ms=77.519
```

This is the project's **first example to use Conan** (`fmt`, for output
formatting only) — it establishes the `conanfile.txt` +
`CMakeDeps`/`CMakeToolchain` pattern before later examples pull in
anything heavier.

## Verification: verify.lua

This project's assertion harness is **Lua 5.4**, not bash asserts.
[`verify.lua`](verify.lua) runs inside the container (which ships both the
binary and a `lua` interpreter) and checks two things:

1. **Correctness is padding-independent (hard assertion).** Both counters
   must equal `N` exactly in both `--pad on` and `--pad off`, in every
   trial. False sharing is a *performance* bug, never a correctness bug —
   any mismatch here is a FAIL.
2. **False sharing is real (soft assertion).** The padded run's average
   elapsed time, over several trials, should be measurably lower than the
   unpadded run's. If the margin is within a noise floor (default: 5%),
   `verify.lua` prints a WARN and still passes — see below for why.

`verify.lua` exits 0 on pass (with or without the timing WARN) and
non-zero on any hard failure, printing a readable trial-by-trial summary
either way.

### Why the timing check is soft

False sharing's *cost* depends on the two hot threads actually landing on
separate physical cores with real cache-coherence traffic between them. A
container only controls which cores are *available* (its cpuset); it
doesn't guarantee the scheduler keeps two pinned threads pinned under host
contention, and a busy shared host or SMT-sibling placement can mute (but
never reverse the existence of) the effect. The fix — `alignas` on the hot
fields — is correct regardless; the demo's job is to show the signal when
the environment allows it and say so clearly when it can't, rather than
assert a margin it can't actually guarantee on someone else's CI runner.

In practice, on this environment, the effect was large and consistent
across trials: ~75× (not noise) — see the observed run below.

## Running it

```bash
./demo.sh            # build + run false_sharing (both modes) + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-20-mechanical-sympathy.sh`](../../../scripts/test-concurrency-demo-20-mechanical-sympathy.sh).

### Observed run

```
== verify.lua: 20-mechanical-sympathy (false sharing) -- N=20000000, trials=3 ==
  [unpadded trial 1] count_a=20000000 count_b=20000000 elapsed_ms=511.797
  [unpadded trial 2] count_a=20000000 count_b=20000000 elapsed_ms=515.444
  [unpadded trial 3] count_a=20000000 count_b=20000000 elapsed_ms=511.133
  [padded   trial 1] count_a=20000000 count_b=20000000 elapsed_ms=77.519
  [padded   trial 2] count_a=20000000 count_b=20000000 elapsed_ms=77.473
  [padded   trial 3] count_a=20000000 count_b=20000000 elapsed_ms=78.247
  correctness: PASS (both modes produced exact counts in every trial)
  avg elapsed_ms: unpadded=512.791 padded=77.746 (padded is 84.8% faster)
  timing: PASS (padded averaged 84.8% faster, clearing the 5.0% noise floor)
RESULT: PASS
```

Padding here isn't a marginal win — the unpadded run is roughly 6.6×
slower, because every increment on either thread bounces the shared line
between the two cores' caches.

## Layout

```
20-mechanical-sympathy/
├── src/false_sharing.cpp   two pinned threads, --pad on|off, prints key=value line
├── conanfile.txt           [requires] fmt/10.2.1 — this project's first Conan dep
├── CMakeLists.txt          C++20, find_package(fmt), -O2, target false_sharing
├── Containerfile           UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua              Lua 5.4 assertion harness (correctness hard, timing soft)
├── demo.sh                 the driver (docker build + docker run)
└── README.md               this file
```

## Convention this example establishes

This is the reference example every other demo in this tutorial copies:

- **Directory shape**: `src/`, `conanfile.txt` (or `conanfile.py` for
  heavier dependency graphs), `CMakeLists.txt`, `Containerfile`,
  `verify.lua`, `demo.sh`, `README.md` — one demo per chapter, built and
  verified standalone.
- **verify.lua contract**: plain Lua 5.4, no required arguments, reads
  `env` vars for overrides, prints a readable summary, exits 0 on pass
  (WARN allowed inside a pass for soft/noise-prone assertions) and
  non-zero on any hard failure. Runs inside the container, against the
  binary that same image built.
- **demo.sh contract**: `set -euo pipefail`; sources
  `scripts/lib/_helpers.sh` for logging/presentation helpers; `--clean`
  removes the image; `DEMO_NO_PAUSE=1` skips presenter pauses; builds the
  image, runs the container (whose default `CMD` runs `verify.lua`), and
  propagates the container's exit code as its own.
- **CI wrapper contract**: `scripts/test-<family>-demo-<NN>-<slug>.sh`
  sources the same helpers, runs `demo.sh` non-interactively
  (`DEMO_NO_PAUSE=1`), and asserts exit 0 — it does not re-implement any
  assertion logic itself.
