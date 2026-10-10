# concurrency/07-coordination-primitives — a barrier-phased worker pool

Compendium reference:
[Doc 07 — Coordination Primitives](../../../_docs/07-coordination-primitives.md)

The runnable companion to compendium Doc 07. The one-line takeaway:
**`std::barrier`'s completion function is the natural place to merge
per-thread partial results between phases**, because the standard
guarantees it runs exactly once per phase, after every participant has
arrived and before any is released.

## What it demonstrates

[`src/barrier_workers.cpp`](src/barrier_workers.cpp) runs a fixed pool of
`workers` threads through `phases` barrier-synchronized rounds. In each
phase, every worker writes a deterministic value into its own slot — worker
`id`'s contribution in phase `p` (both zero-indexed) is `(p+1)*(id+1)` — and
calls `arrive_and_wait()`. Because no two workers ever write the same slot,
and the barrier itself establishes the happens-before relationship between
every worker's write and the completion function's read, the merge needs no
extra lock. The completion function sums the slots into a running total and
prints one line recording that phase's result before the barrier resets and
releases everyone into the next phase:

```
phase=0 completion merged_sum=10 running_total=10
phase=1 completion merged_sum=20 running_total=30
phase=2 completion merged_sum=30 running_total=60
phase=3 completion merged_sum=40 running_total=100
phase=4 completion merged_sum=50 running_total=150
workers=4 phases=5 final_total=150
```

The expected final total has a closed form — `(phases*(phases+1)/2) *
(workers*(workers+1)/2)` — that `verify.lua` recomputes independently
rather than hard-coding a magic number.

## Verification: verify.lua

This example has no inherent timing noise to make soft — a barrier's
completion-function contract is a standard guarantee, not a scheduling
race — so both of [`verify.lua`](verify.lua)'s checks are **hard**
assertions:

1. **Exactly-once-per-phase completion.** Every phase number from `0` to
   `phases - 1` must appear in exactly one `completion` line — never zero
   (a hung phase) and never more than once (a broken barrier or a race in
   this program).
2. **The final merged total matches the closed-form expected sum.**

`verify.lua` exits 0 only if both hold for every phase.

## Running it

```bash
./demo.sh            # build + run barrier_workers + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-07-coordination-primitives.sh`](../../../scripts/test-concurrency-demo-07-coordination-primitives.sh).

## Layout

```
07-coordination-primitives/
├── src/barrier_workers.cpp   -w WORKERS -p PHASES, barrier-phased pool with a merging completion function
├── conanfile.txt             [requires] fmt/10.2.1
├── CMakeLists.txt            C++20, find_package(fmt), -O2, target barrier_workers
├── Containerfile             UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua                Lua 5.4 assertion harness (both hard: completion count, closed-form total)
├── demo.sh                   the driver (docker build + docker run)
└── README.md                 this file
```

Follows the convention established in
[`../20-mechanical-sympathy/`](../20-mechanical-sympathy/README.md#convention-this-example-establishes).
