# concurrency/21-lock-free-messaging-and-the-disruptor — single-producer ring, journal + business-logic pipeline

Compendium reference:
[Doc 21 — Lock-Free Messaging and the Disruptor](../../../_docs/21-lock-free-messaging-and-the-disruptor.md)

The runnable companion to compendium Doc 21. The one-line takeaway: **a
sequence barrier expresses fan-out and staged dependencies with nothing
but atomic loads and comparisons** — no lock, no compare-and-swap, because
every mutable position in the system has exactly one writer.

## What it demonstrates

[`src/disruptor_ring.cpp`](src/disruptor_ring.cpp) builds the two-stage
pipeline Doc 21 describes on top of a fixed-capacity, pre-allocated ring:

- **One producer** claims and publishes slots in order. It is the sole
  writer of `published`, the highest slot index it has made visible.
- **A journal consumer** trails `published`. It is the sole writer of
  `journal_seq`, and nothing slows it down — under load it naturally
  batches, processing every newly published slot it finds in one pass
  instead of re-checking per event.
- **A business-logic consumer** trails `journal_seq`, not `published`
  directly — the diamond-dependency sequence barrier Doc 21 calls out: the
  dependent stage gates on the upstream stage's sequence, so it can never
  see an event the journal hasn't already processed. It is the sole
  writer of `biz_seq`, and it is deliberately slowed down (a short sleep
  every 50 events, by default) so the ring reliably fills during the run.

Because `biz_seq` is always behind (or equal to) `journal_seq`, it's the
slowest sequence in the system, and it's what gates the producer: the
producer cannot claim a slot the business stage hasn't read yet, or it
would overwrite live, unconsumed data. All three sequences are plain
`std::atomic<std::uint64_t>` with release-on-write/acquire-on-read
pairing, and every wait (the producer waiting on `biz_seq`, the journal
waiting on `published`, the business stage waiting on `journal_seq`) uses
`std::atomic<T>::wait`/`notify` — the C++20 feature Doc 21's standards
section calls "the practical default today" for exactly this pattern.

The program prints one line in a `key=value` form:

```
cpus=0/1/2 pinned=true n=100000 capacity=64 slow_every=50 slow_sleep_us=150 \
  published=100000 journal_consumed=100000 journal_mismatches=0 \
  biz_consumed=100000 biz_mismatches=0 gating_violations=0 \
  producer_backpressure_events=1847 max_batch_journal=612 max_batch_biz=4 \
  elapsed_ms=341.207 events_per_sec=293183
```

`max_batch_journal` being far larger than `max_batch_biz` is the batching
effect in miniature: the journal stage, unblocked, frequently finds
hundreds of newly published slots waiting for it, while the deliberately
slow business stage rarely gets more than a handful ahead before it has
to stop and sleep.

### Why the business stage is deliberately slowed down

`producer_backpressure_events > 0` has to be a **deterministic** property
of this demo, not something that depends on the host being busy or slow
at just the right moment. The business stage's sleep schedule forces it
to spend a fixed minimum amount of wall-clock time processing all `n`
events — a floor no amount of host speed can beat — while the ring's
capacity (64 slots, tiny relative to the default 100,000 events) all but
guarantees the producer outruns that floor and has to wait. This is the
same idea Doc 21's "Running in a container" section makes about wait
strategies and CPU quotas, applied here to make a correctness property
reproducible instead of to study latency.

This example does **not** reproduce the chapter's full wait-strategy
matrix (busy-spin / yield / atomic-wait) or the `std::mutex` +
`std::deque` baseline comparison the chapter text also describes — this
scaffold's scope is the sequence-barrier/back-pressure mechanism itself,
verified by hard, observable assertions; a throughput comparison against
a lock-based baseline depends on host core count and placement in ways
that don't belong in a correctness-gated CI check.

## Verification: verify.lua

This project's assertion harness is **Lua 5.4**, not bash asserts.
[`verify.lua`](verify.lua) runs inside the container (which ships both the
binary and a `lua` interpreter) and checks:

1. **Every published event is consumed exactly once, in order, by both
   stages (hard).** `published`, `journal_consumed`, and `biz_consumed`
   must all equal `n`, and both mismatch counters must be zero. A
   mismatch means a stage read a slot's value out of logical position —
   exactly what the single-writer sequence-barrier design exists to
   prevent.
2. **The dependent stage never reads past the journal stage's sequence
   (hard).** `disruptor_ring` itself re-checks this invariant live,
   against the real value of `journal_seq`, at the moment of every read
   in the business stage (see the comment in `disruptor_ring.cpp`) and
   reports a `gating_violations` counter; `verify.lua` asserts it's zero.
3. **Back-pressure actually engages (hard).** `producer_backpressure_events`
   must be at least 1 — the producer has to have actually waited rather
   than overwritten an unread slot at least once. See above for why this
   is a deterministic outcome of the defaults, not a race.
4. **Throughput (`events_per_sec`) is SOFT/informational.** It's printed,
   not asserted against — it depends on the host's core count and
   placement in ways this harness has no baseline for.

`verify.lua` exits 0 on pass and non-zero on any hard failure, printing a
readable summary either way.

## Running it

```bash
./demo.sh            # build + run disruptor_ring + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-21-lock-free-messaging-and-the-disruptor.sh`](../../../scripts/test-concurrency-demo-21-lock-free-messaging-and-the-disruptor.sh).

## Layout

```
21-lock-free-messaging-and-the-disruptor/
├── src/disruptor_ring.cpp   producer + journal + business-logic stages over one ring, prints key=value line
├── conanfile.txt            [requires] fmt/10.2.1
├── CMakeLists.txt           C++20, find_package(fmt), -O2, target disruptor_ring
├── Containerfile            UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua               Lua 5.4 assertion harness (correctness/gating/back-pressure hard, throughput soft)
├── demo.sh                  the driver (docker build + docker run)
└── README.md                this file
```

This follows the directory shape, `verify.lua` contract, `demo.sh`
contract, and CI-wrapper contract that
[`20-mechanical-sympathy`](../20-mechanical-sympathy/README.md#convention-this-example-establishes)
establishes for the whole tutorial.
