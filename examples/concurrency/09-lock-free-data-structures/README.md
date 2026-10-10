# concurrency/09-lock-free-data-structures — SPSC ring buffer

Compendium reference:
[Doc 9 — Lock-Free Data Structures](../../../_docs/09-lock-free-data-structures.md)

The runnable companion to compendium Doc 9. The one-line takeaway: **a
single-producer/single-consumer ring buffer is safe without a lock because
each counter has exactly one writer** — the moment a second writer needs to
touch `head` or `tail`, compare-and-swap (and the ABA problem it reopens)
becomes necessary, which is exactly where SPSC's guarantee stops applying.

## What it demonstrates

[`src/spsc_ring.cpp`](src/spsc_ring.cpp) runs one producer thread pushing
values `0..N-1` into a bounded ring buffer and one consumer thread popping
them, in order, on the other end — the same structure Doc 9 builds: `tail`
(items pushed) is written only by the producer and only read by the
consumer; `head` (items popped) is written only by the consumer and only
read by the producer. `tail.store` is `release` (publishing the slot
write), `tail.load`/`head.load` are `acquire`.

Two flags:

- `--pad on|off` — whether `head` and `tail` share a cache line (the
  default, unpadded layout) or each get their own
  `std::hardware_destructive_interference_size`-aligned line.
- `--capacity N` — the backing buffer's size, down to `1` for maximum
  contention (a single-slot ring, lockstep between producer and consumer).

The program prints one line in a `key=value` form that's trivial to parse:

```
mode=padded capacity=1024 pinned=true cpus=0/1 n=5000000 consumed=5000000 mismatches=0 sum=12499997500000 expected_sum=12499997500000 elapsed_ms=210.773 ops_per_sec=23721987
```

### Correctness is checked per item, not just by sum

The producer pushes value `i` at logical position `t == i`, so a correct
FIFO ring must hand the consumer back exactly `v == h` at logical position
`h`. The binary tracks this directly as `mismatches` — any loss,
duplication, or reordering increments it immediately, which is a stronger
check than the aggregate `sum` alone (a lost item and a duplicated item
could, in principle, cancel out in a sum but never in a per-position
comparison).

## Verification: verify.lua

This project's assertion harness is **Lua 5.4**, not bash asserts.
[`verify.lua`](verify.lua) runs inside the container and checks two things:

1. **Correctness is padding- and capacity-independent (hard assertion).**
   Every item pushed must be consumed exactly once, in order, across both
   `--pad` settings and capacities `{1, 2, 64, 1024}` (including `1`, the
   chapter's maximum-contention case). `mismatches` must be `0` and the
   summed total must match the closed-form `0+1+...+N-1` in every
   combination — this check is not scheduling-flaky (a ring-logic bug would
   reproduce every run), so one run per combination is sufficient.
2. **Padded throughput ≥ unpadded throughput (soft assertion).** If `head`
   and `tail` share a cache line, the consumer's store to `head` invalidates
   the producer's cached copy of the whole line — `tail` included — even
   though the producer never touches `head`. This check only warns below a
   5% noise floor rather than asserting a fixed percentage, for the same
   reason [Doc 20's false-sharing demo](../20-mechanical-sympathy/README.md)
   treats its own timing check as soft: core placement and host contention
   can mute the signal without making the padded layout wrong.

`verify.lua` exits 0 on pass (with or without the timing WARN) and
non-zero on any hard failure.

## No C++26 reclamation code here

The chapter previews `std::hazard_pointer` and `std::rcu` (C++26, proposed,
labeled experimental — no shipping compiler implements either) as the
eventual standardized replacement for hand-rolled hazard-pointer and RCU
schemes. Both are illustrative-only in the chapter text and have no runnable
example here: this demo is SPSC, which (per the chapter) never needs
reclamation at all, since its monotonic, single-writer counters never reuse
a value and there is no CAS anywhere in it.

## Running it

```bash
./demo.sh            # build + run spsc_ring (correctness sweep + timing) + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-09-lock-free-data-structures.sh`](../../../scripts/test-concurrency-demo-09-lock-free-data-structures.sh).

## Layout

```
09-lock-free-data-structures/
├── src/spsc_ring.cpp       SPSC ring, --pad on|off, --capacity N, prints key=value line
├── conanfile.txt           [requires] fmt/10.2.1
├── CMakeLists.txt          C++20, find_package(fmt), -O2, target spsc_ring
├── Containerfile           UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua              Lua 5.4 assertion harness (per-item correctness hard, timing soft)
├── demo.sh                 the driver (docker build + docker run)
└── README.md               this file
```

Follows the directory shape, `verify.lua` contract, `demo.sh` contract, and
CI-wrapper contract [Doc 20's example](../20-mechanical-sympathy/README.md)
establishes.
