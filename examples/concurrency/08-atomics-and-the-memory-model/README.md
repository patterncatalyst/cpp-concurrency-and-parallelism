# concurrency/08-atomics-and-the-memory-model — one-slot hand-off under three orderings

Compendium reference:
[Doc 8 — Atomics and the Memory Model](../../../_docs/08-atomics-and-the-memory-model.md)

The runnable companion to compendium Doc 8. The one-line takeaway:
**atomicity and ordering are two separate guarantees** — a hand-off between
threads needs both, and the difference between `seq_cst`, `acquire`/
`release`, and no ordering at all is the difference between "always
correct," "correct because of exactly one happens-before edge," and
"broken."

## What it demonstrates

[`src/ring_handoff.cpp`](src/ring_handoff.cpp) runs one producer thread and
one consumer thread moving values `0..N-1` through a single-slot hand-off —
the tightest possible contention, every push waiting on the previous pop. A
`--mode` flag selects how `head` and `tail` are synchronized:

- `--mode seqcst` — `std::atomic<uint64_t>` counters, every operation at the
  type's default ordering (sequential consistency): one global total order
  every thread agrees on.
- `--mode acqrel` — the same atomics, but the producer's `tail.store` is
  `release` / the consumer's `tail.load` is `acquire` (publishing and
  observing the slot write), and symmetrically the consumer's `head.store`
  is `release` / the producer's `head.load` is `acquire` (publishing and
  observing that the slot is free again). This is the chapter's minimal
  happens-before pairing — nothing stronger than the hand-off needs.
- `--mode broken` — **plain `uint64_t` counters, no `std::atomic`, no
  `volatile`.** The deliberately-broken negative case described below.

The program prints one line in a `key=value` form that's trivial to parse:

```
mode=seqcst n=2000000 completed=true consumed=2000000 sum=1999999000000 expected_sum=1999999000000 stalled=false elapsed_ms=312.418 ops_per_sec=6401968
```

## The `--mode broken` negative case

A busy-wait loop reading an ordinary (non-atomic, non-volatile) shared
variable gives the compiler no reason to believe that variable can change
*inside the loop* — nothing in the loop's own visible code writes it. At
`-O2`, loop-invariant code motion is free to load the variable once outside
the loop, cache it in a register, and spin on that cached copy forever, even
while a different thread keeps writing the real memory location. That's
exactly the gap the chapter opens with: atomicity alone (which `--mode
broken` doesn't even have here) is not ordering, and ordering is not
something a plain variable carries at all.

Each spin wait is bounded by `kMaxSpins` (20,000,000 iterations of a tight
compare-and-increment — milliseconds of wall time, not a hang), so a stalled
hand-off reports `stalled=true` and a short `consumed` count instead of
wedging the process. The point is to observe the divergence safely, never to
actually deadlock a CI runner.

### Why the broken case is deterministic, not flaky

Unlike a classic scheduling-dependent data race (where the bad interleaving
might or might not occur on a given run), this bug is a **code-generation
decision baked into the compiled binary**: whether the optimizer hoists the
read of `tail` out of the consumer's loop is decided once, at compile time,
for that build. Every execution of the same binary behaves identically — on
the environment this example was authored against, that means `--mode
broken` stalls on essentially the first iteration (`consumed=0`,
`stalled=true`), because `head` and `tail` both start at `0` and the
consumer's very first loop condition (`h == tail`) is true from the moment
the cached read happens. `verify.lua` asserts the run does **not** cleanly
complete with the correct sum — a real, observable, non-flaky check, not a
simulated failure.

## Verification: verify.lua

This project's assertion harness is **Lua 5.4**, not bash asserts.
[`verify.lua`](verify.lua) runs inside the container and checks three
things:

1. **Correctness, `--mode seqcst` and `--mode acqrel` (hard assertion).**
   Both orderings are sufficient for a correct one-slot hand-off; every
   trial must complete with the exact closed-form sum `0+1+...+N-1`. The
   chapter is explicit that both are correct — any mismatch here is a FAIL.
2. **The broken case actually misbehaves (hard assertion).** `--mode
   broken` must *not* cleanly complete with the correct sum. This is a real
   assertion tied to the program's own output (`completed`, `sum` vs.
   `expected_sum`), not an assumption — see above for why it reproduces
   every run.
3. **`seq_cst` vs. acquire/release timing margin (soft assertion).** The
   chapter's measured gap is "commonly on the order of 10-20%" on real
   hardware, paid almost entirely at `seq_cst`'s locked publishing store.
   This check only warns below a 5% noise floor rather than asserting any
   fixed percentage, because core placement, SMT-sibling scheduling, and
   host contention can mute (never reverse) that signal without making
   either ordering wrong.

`verify.lua` exits 0 on pass (with or without the timing WARN) and
non-zero on any hard failure.

## ThreadSanitizer

This example does **not** build a ThreadSanitizer variant. Chapter 28
("Sanitizers and Dynamic Analysis") owns that mechanism end to end with its
own dedicated demo (`examples/concurrency/28-sanitizers/`, not yet built in
this repo) — reusing a racy counter under `-fsanitize=thread` and
`valgrind --tool=helgrind`, with its own `verify.lua` asserting the tool
flags the race. Building a second, narrower TSan variant here would
duplicate that chapter's job rather than this one's. `--mode broken`
demonstrates the memory-model violation a different way — a deterministic
compiler-optimization stall that needs no sanitizer runtime to observe —
which is sufficient for what this chapter is teaching.

## Running it

```bash
./demo.sh            # build + run ring_handoff (all three modes) + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-08-atomics-and-the-memory-model.sh`](../../../scripts/test-concurrency-demo-08-atomics-and-the-memory-model.sh).

## Layout

```
08-atomics-and-the-memory-model/
├── src/ring_handoff.cpp    one-slot hand-off, --mode seqcst|acqrel|broken, prints key=value line
├── conanfile.txt           [requires] fmt/10.2.1
├── CMakeLists.txt          C++20, find_package(fmt), -O2, target ring_handoff
├── Containerfile           UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua              Lua 5.4 assertion harness (seqcst/acqrel correctness hard, broken-misbehaves hard, timing soft)
├── demo.sh                 the driver (docker build + docker run)
└── README.md               this file
```

Follows the directory shape, `verify.lua` contract, `demo.sh` contract, and
CI-wrapper contract [Doc 20's example](../20-mechanical-sympathy/README.md)
establishes.
