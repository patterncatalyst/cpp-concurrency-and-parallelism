# concurrency/33-ingest-match-publish — ingest, match, publish

Compendium reference:
[Doc 33 — Full Example: Ingest, Match, Publish](../../../_docs/33-ingest-match-publish.md)

The runnable companion to compendium Doc 33, and this book's full example: a
real three-stage, low-latency pipeline — ingest, match, publish — wired
together from the patterns earlier chapters spent 32 chapters
establishing one at a time. Nothing here is a new idea; it is the smaller
ideas, stacked.

## What it demonstrates

[`src/pipeline.cpp`](src/pipeline.cpp) is one process,
one binary, three concurrency shapes:

- **Ingest** — several producer threads (`--ingest-threads`, default 4)
  generate a stream of `NEW`/`CANCEL` order messages each (a simulated
  feed, standing in for ch24/25's real connection handlers — see
  "Simplifications" below), stamp an arrival timestamp, and reject
  anything whose deadline (ch3) has already passed *before* it is allowed
  to cost the match stage a cycle (~1% of generated messages arrive
  pre-expired, deterministically, so this path is always exercised).
  Surviving messages are pushed onto a bounded, lock-free ring.

- **The rings** — one `BoundedRing<T>` type, instantiated twice: once as
  the ingest ring (many producers, one consumer) and once as the publish
  ring (one producer, many consumers). It generalizes ch9's SPSC ring and
  ch21's disruptor ring's single-writer-per-counter discipline to a
  per-slot sequence number (Dmitry Vyukov's bounded MPMC queue algorithm),
  so the same type safely supports multiple producers *or* multiple
  consumers while every individual slot's hand-off stays a single-writer
  relationship underneath. Both rings are fixed-capacity and never grow.

- **Match** — exactly one thread, pinned to its own core when the host
  has one to spare, is the sole writer of the order book (ch31's
  single-writer pattern) and busy-polls the ingest ring rather than
  blocking (ch19's fast-path playbook). The order book is a real,
  working price-time-priority limit order book: a pre-sized pool of
  order slots and intrusive doubly-linked FIFOs per price level, with
  cached best-bid/best-ask pointers — zero heap allocation per order
  after startup.

- **Publish** — a small pool of threads (`--publish-threads`, default 3)
  drains the match stage's output ring (ch9's multi-consumer technique)
  and "writes" each outcome out — to an in-memory buffer standing in for
  a subscriber socket. Latency is captured at the moment each event is
  popped, *before* any formatting or I/O, so the measured path never
  includes this program's own `stdout` cost.

The program always exits `0` and never judges itself — it only reports:
one `EVENT` line per accepted order and a final `SUMMARY` line of
counters and latency percentiles. [`verify.lua`](verify.lua) is where
every hard and soft assertion tied to that output lives, matching every
sibling example's "binary reports, Lua judges" convention.

```
EVENT match_seq=4821 kind=NEW outcome=RESTED order_id=3912 price=37 side=BUY \
  producer_tid=842 match_tid=840 publish_tid=844 ring_occ_at_claim=12 \
  ingest_ts_ns=... publish_ts_ns=... latency_ns=18420
...
SUMMARY pinned=true match_tid=840 elapsed_ms=71.204 ingest_threads=4 publish_threads=3 \
  ingest_capacity=64 publish_capacity=512 total_submitted=14800 busy=6214 \
  deadline_expired=152 accepted=8434 accepted_new=6508 accepted_cancel=1926 \
  filled_as_aggressor=2991 rested=3517 filled_later=1402 cancel_ok=1304 cancel_miss=622 \
  final_resting_scanned=811 ingest_peak_occupancy=64 events=8434 \
  p50_latency_ns=9120 p99_latency_ns=68210 p999_latency_ns=142330
```

## Two load shapes, one run

The default configuration drives both load shapes Doc 33 describes back
to back, in a single pass:

1. **Sustained** — each ingest thread submits `--sustained` orders
   (default 1200) paced ~20µs apart. The match thread's own fixed
   throughput ceiling (a short sleep every 30 processed messages — the
   same technique ch21's `disruptor_ring` uses to make a floor
   reproducible on any host) comfortably outpaces this combined rate, so
   the ingest ring should stay mostly empty.
2. **Overload burst** — each thread then submits `--burst` orders
   (default 2500) with *no* pacing at all. Four threads hammering a
   64-slot ring with no delay reliably outruns the match thread's fixed
   ceiling regardless of host speed, which is what makes the ingest ring
   filling — and ingest threads receiving `BUSY` instead of retrying or
   growing anything — a deterministic property of this run rather than a
   race against scheduler luck on whatever machine runs it.

## Verification: verify.lua

[`verify.lua`](verify.lua) runs `pipeline` once and checks:

**Hard** (any failure here is a real bug, not noise):

1. The output parses: a `SUMMARY` line with every expected field, and the
   right number of `EVENT` lines.
2. **No lost or duplicated orders through either ring** — every `EVENT`
   line's `match_seq` is unique, and the full set is exactly
   `{0, ..., events-1}` with no gaps.
3. Ingest-side bookkeeping conservation: `total_submitted == accepted +
   busy + deadline_expired`, and `accepted == events`.
4. **Order-book conservation** — the real correctness-of-matching check:
   `rested == filled_later + cancel_ok + final_resting_scanned`, where
   `final_resting_scanned` is counted by scanning the live pool at the
   end of the run, independently of any running counter.
5. **Single-writer invariant** — every `EVENT` line's `match_tid` (and
   `SUMMARY`'s own) is the *same* thread id, verified over real recorded
   data rather than assumed from the source.
6. **Back-pressure actually engaged** — `busy > 0` under the overload
   burst, and the ingest ring's peak occupancy never exceeded its fixed
   capacity (never grew unbounded).
7. Every event's `kind`/`outcome` pairing is structurally sane
   (`CANCEL_OK`/`CANCEL_MISS` only tag a `CANCEL`; `FILLED`/`RESTED` only
   tag a `NEW`).

**Soft** (reported, not asserted against a fixed number — matching Doc
33's explicit refusal to put a portable latency figure in prose):

8. `p50`/`p99`/`p99.9` latency figures are present and parse as numbers.
   Their relative ordering is a sanity check only, WARNed rather than
   failed, since a small accepted-order sample can defy strict
   monotonicity at the tail.

## Simplifications — what this example does NOT build

This is one container, with one Conan dependency (`fmt`), on purpose.
Doc 33's architecture mentions several heavier integration points; this
example implements the pattern each one represents without pulling in
its dependency:

- **No real gRPC/REST server (ch24/25).** Ingest generates its own
  `NEW`/`CANCEL` stream in-process instead of decoding wire frames from a
  socket. Everything downstream of "a decoded `OrderMsg` with an arrival
  timestamp" is identical either way — only the framing/decoding step is
  stood in for.
- **Unit order quantity.** Every order has an implicit quantity of one,
  so a match is always a full fill, never a partial one. Price-time
  priority, FIFO-per-level matching, and the conservation invariants
  above are all real; a production book would generalize the FIFO
  removal to a partial-quantity decrement without changing the
  structure.
- **No OTel SDK (ch29).** Each `EVENT` line's `producer_tid`/`match_tid`/
  `publish_tid`/`ring_occ_at_claim` fields are exactly what Doc 33
  describes carrying as span attributes on a per-order trace — they are
  printed as plain fields here instead of exported via an OTel SDK, so
  this example stays a single lightweight container.
- **No cpuset-exclusive container pinning (ch32).** The match thread
  pins itself to one core via `sched_setaffinity` when the process's own
  cpuset has more than one CPU available, but this example runs as one
  container rather than the four-container compose stack ("ingest",
  "match", "publish", "load generator") Doc 33's "Running in a
  container" section describes for a real deployment.
- **Match-thread busy-poll uses plain spin/yield, not
  `atomic::wait`/`notify`.** `BoundedRing<T>`'s per-slot sequence
  numbers don't expose a single counter `wait`/`notify` could block on
  the way ch9/ch21's whole-ring counters do; Doc 33's C++20 standards
  note about `wait`/`notify` still applies to those simpler rings, just
  not to this example's generalized one.

## Running it

```bash
./demo.sh            # build + run pipeline + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

`pipeline` itself takes:

```
pipeline [--sustained N] [--burst N] [--ingest-threads N] \
                   [--publish-threads N] [--ingest-capacity N] \
                   [--publish-capacity N]
```

CI verification:
[`../../../scripts/test-concurrency-demo-33-ingest-match-publish.sh`](../../../scripts/test-concurrency-demo-33-ingest-match-publish.sh).

## Layout

```
33-ingest-match-publish/
├── src/pipeline.cpp   ingest + BoundedRing<T> + MatchEngine + publish, one TU
├── conanfile.txt               [requires] fmt/10.2.1 -- the project's one dependency
├── CMakeLists.txt              C++20, find_package(fmt), -O2, target pipeline
├── Containerfile                UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua                  Lua 5.4 assertion harness (correctness hard, timing soft)
├── demo.sh                     the driver (docker build + docker run)
└── README.md                   this file
```

This example follows the directory shape, `verify.lua` contract,
`demo.sh` contract, and CI wrapper contract
[20-mechanical-sympathy](../20-mechanical-sympathy/README.md#convention-this-example-establishes)
establishes for the whole project.
