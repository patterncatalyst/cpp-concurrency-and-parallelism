# concurrency/02-machine-underneath — cache-hierarchy latency probe

Compendium reference:
[Doc 02 — The Machine Underneath](../../../_docs/02-the-machine-underneath.md)

The runnable companion to compendium Doc 02's cache-hierarchy claims. The
one-line takeaway: **the cost of a memory access depends entirely on how
big the data you're touching is relative to each cache level** — not on
anything in the source code that looks like contention, a lock, or an
atomic.

## What it demonstrates

[`src/cache_latency.cpp`](src/cache_latency.cpp) is a single-threaded
pointer-chase benchmark. It builds a random single-cycle permutation over
an array of cache-line-sized (64-byte) nodes, then times how long it
takes, on average, to walk one link of that cycle — for five working-set
sizes chosen to step through the cache hierarchy Doc 02's Figure 2.1
describes:

| step | label  | size    | typically lands in         |
|-----:|--------|---------|-----------------------------|
| 1    | L1     | 8 KiB   | L1 data cache               |
| 2    | L2     | 128 KiB | L2                          |
| 3    | L2/L3  | 2 MiB   | L2 or the L2/L3 boundary    |
| 4    | L3     | 32 MiB  | a large shared L3           |
| 5    | DRAM   | 256 MiB | past any realistic L3       |

Each step is roughly 16x the last. Real cache sizes vary across machines,
so "typically lands in" is only a label — the actual hard claim this
example checks is about the *ordering* of the measured latency across
these five sizes, not about any one of them landing in a specific cache
level.

The chase order is a random permutation, not a sequential or strided
walk. That matters: a hardware prefetcher is built to predict a
sequential or strided access pattern, and would quietly turn this into a
bandwidth benchmark instead of a latency one. A random, single-cycle
permutation makes every load's address depend on the *value* of the
previous load — the next address genuinely cannot be known until the
current one completes — so there's nothing for the prefetcher to act on.

The program prints one line per step in a `key=value` form:

```
step=1 label=L1 size_kib=8 nodes=128 trials=3 accesses=2000000 ns_per_access=1.342 chase_sink=91823
step=2 label=L2 size_kib=128 nodes=2048 trials=3 accesses=2000000 ns_per_access=2.611 chase_sink=4127
step=3 label=L2/L3 size_kib=2048 nodes=32768 trials=3 accesses=2000000 ns_per_access=5.204 chase_sink=81044
step=4 label=L3 size_kib=32768 nodes=524288 trials=3 accesses=2000000 ns_per_access=12.887 chase_sink=301552
step=5 label=DRAM size_kib=262144 nodes=4194304 trials=3 accesses=4194304 ns_per_access=94.213 chase_sink=1882011
```

`ns_per_access` is the **minimum** over several internal trials (3 by
default), not the mean — the standard way to suppress scheduler-noise
outliers in a microbenchmark like this one. `chase_sink` is the final
node index the chase landed on; it's printed, not discarded, purely so
the compiler can't prove the chase's result is unused and delete the
whole loop.

This is the project's **second example to use Conan** (`fmt`, for output
formatting only), following the `conanfile.txt` + `CMakeDeps`/
`CMakeToolchain` pattern `20-mechanical-sympathy` establishes.

## NUMA is Doc 16's demo, not this one

Doc 02 also introduces NUMA topology (local vs. remote memory nodes), but
this example deliberately stops at the cache hierarchy. A real NUMA
comparison needs a real second memory node and real exclusive core
isolation — neither of which a container reliably gives you: a container
runtime can restrict *which* node's memory a container may allocate from
(`--cpuset-mems`), but it doesn't fabricate a second physical node where
none exists, and a busy shared host can mute or invert a local-vs-remote
timing comparison in ways that would make this example's own assertions
unreliable.

The NUMA local-vs-remote comparison lives in
[Doc 16 — NUMA Affinity and Data Locality](../../../_docs/16-numa-affinity-and-data-locality.md)
and its runnable companion,
`examples/concurrency/16-numa-affinity-and-data-locality/`, which runs in
the KVM lab (see the `lgtm-systems-programming` skill) specifically
because it needs that real topology and isolation to produce a trustworthy
result.

## Verification: verify.lua

This project's assertion harness is **Lua 5.4**, not bash asserts.
[`verify.lua`](verify.lua) runs inside the container (which ships both the
binary and a `lua` interpreter) and checks:

1. **All five steps parse, in increasing size order (hard).** A missing
   or unparseable step line means the demo itself is broken.
2. **Latency is monotonically non-decreasing across the cache-size steps
   (hard).** A bigger working set can only match or lose to a smaller
   one — once a step no longer fits in a given cache level, the hit rate
   against that level can only get worse as the working set keeps
   growing, never better. A measured decrease here would mean either a
   bug in this harness or a genuinely surprising hardware/virtualization
   condition, so it's treated as a hard failure rather than averaged away.
3. **The exact ns/access values and the DRAM/L1 ratio are
   SOFT/informational.** They depend on the host's real cache sizes and
   clock, which this harness has no way to know in advance, so they're
   printed for a human to read rather than checked against a hard-coded
   number.

`verify.lua` exits 0 on pass and non-zero on any hard failure, printing a
readable step-by-step summary either way.

## Running it

```bash
./demo.sh            # build + run cache_latency + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-02-machine-underneath.sh`](../../../scripts/test-concurrency-demo-02-machine-underneath.sh).

## Layout

```
02-machine-underneath/
├── src/cache_latency.cpp   single-threaded pointer chase, 5 working-set sizes, prints key=value lines
├── conanfile.txt           [requires] fmt/10.2.1
├── CMakeLists.txt          C++20, find_package(fmt), -O2, target cache_latency
├── Containerfile           UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua              Lua 5.4 assertion harness (monotonicity hard, exact ns soft)
├── demo.sh                 the driver (docker build + docker run)
└── README.md               this file
```

This follows the directory shape, `verify.lua` contract, `demo.sh`
contract, and CI-wrapper contract that
[`20-mechanical-sympathy`](../20-mechanical-sympathy/README.md#convention-this-example-establishes)
establishes for the whole tutorial.
