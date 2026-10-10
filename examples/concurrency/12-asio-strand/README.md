# concurrency/12-asio-strand — strand vs. mutex: serialization without a lock

Compendium reference:
[Doc 12 — Async Runtimes and Event Loops](../../../_docs/12-async-runtimes-and-event-loops.md)

The runnable companion to compendium Doc 12's strand section. The one-line
takeaway: **a strand serializes handlers without a mutex** — the same
unsynchronized counter, incremented by several threads, comes back exactly
correct through a strand and measurably wrong posted straight to a
multithreaded `io_context`, with only the executor changed. A mutex around
the same counter is also correct, but pays for it differently: **a mutex
blocks a thread; a strand defers a handler.**

## What it demonstrates

[`src/asio_strand.cpp`](src/asio_strand.cpp) builds one binary, `asio_strand`,
selected by `--mode`. Everything runs in-process — no sockets, no TCP port.

- `--mode strand` / `--mode nostrand` — **the race demo.** N copies of the
  identical handler are posted either through a single shared
  `asio::strand` or straight to the `io_context`, then drained by several
  threads all calling `run()`. The handler reads an unsynchronized
  `long counter`, calls `std::this_thread::yield()` (an explicit scheduling
  point) and spins briefly, then writes the incremented value back —
  deliberately widening the window in which two handlers could interleave,
  so the no-strand case's race is a deterministic, CI-reliable signal
  rather than a coin flip on a quiet host. Through the strand, Asio's own
  guarantee — handlers posted to the same strand never run concurrently,
  no matter how many threads call `run()` — holds regardless of how long a
  handler occupies its thread or whether it yields mid-handler: `overlaps`
  stays `0` and `counter` lands on exactly `N`. Posted directly, with no
  such guarantee, another worker thread's own handler interleaves for
  real: `overlaps > 0`.
- `--mode strand-cost` / `--mode mutex-cost` — **the kernel-cost
  comparison.** The same equivalent, always-correct work (plain
  `++counter`, none of the race-demo's widening — that instrumentation
  would equally inflate both sides) guarded by a strand versus a
  `std::mutex`. Each worker thread reports its own
  `getrusage(RUSAGE_THREAD).ru_nvcsw` (voluntary context switches) right
  before it exits — a portable proxy for how often a thread had to go
  through the kernel to get the answer, without needing the `ptrace`
  capability `strace -f -c -e trace=futex` would require (this project's
  `demo.sh` convention runs a plain `docker run --rm`, no extra
  capabilities granted).

Each mode prints one line in a `key=value` form:

```
mode=strand threads=6 n=4000 counter=4000 expected=4000 overlaps=0 active_max=1 distinct_tids=6 elapsed_ms=8.112
mode=nostrand threads=6 n=4000 counter=3958 expected=4000 overlaps=112 active_max=3 distinct_tids=6 elapsed_ms=6.004
mode=strand-cost threads=6 n=4000 counter=4000 voluntary_ctxt_switches=14 elapsed_ms=5.201
mode=mutex-cost threads=6 n=4000 counter=4000 voluntary_ctxt_switches=389 elapsed_ms=7.845
```

`distinct_tids` is a tiny topology probe in the spirit of the chapter's
"Who Actually Runs Your Handler" section: each worker thread records its
own `gettid()` the first time it runs a handler, so the line reports how
many distinct OS threads actually did the work — informational only, not
asserted.

## Boost.Asio, pinned static

This is the project's first example to pull **Boost** (`boost/1.84.0`,
`shared=False`) via Conan — Asio itself is header-only within Boost, but
the package also builds Boost.System and friends. Pinning Boost static
means this Containerfile needs none of
[`01-execution-models`](../01-execution-models/)'s runtime-lib staging
step (that example's oneTBB dependency forces a shared `hwloc`); the
binary needs nothing beyond `libstdc++` at runtime, same as
[`20-mechanical-sympathy`](../20-mechanical-sympathy/).

## Verification: verify.lua

[`verify.lua`](verify.lua) runs inside the container and checks two things,
across several trials each:

1. **The race demo (hard assertion).** Every `strand` trial must show
   `overlaps == 0` and `counter == N` exactly — a strand violating this
   would mean Asio's own serialization guarantee was broken, not
   environment noise. Every `nostrand` trial must show `overlaps > 0` —
   the race this demo exists to show must actually manifest.
2. **The kernel-cost comparison (soft / informational).** `counter == N`
   is still checked as a hard sanity check for both `strand-cost` and
   `mutex-cost` (both mechanisms are supposed to produce the exact count,
   always). The `voluntary_ctxt_switches` comparison itself — strand
   versus mutex — is reported as `PASS` when the strand averaged fewer,
   or `WARN` (never a failure) otherwise: it's a portable proxy for
   kernel-blocking activity, not a literal `futex(2)` count, and this
   harness does not assert a fixed ratio.

`verify.lua` exits `0` on pass (with or without the kernel-cost `WARN`)
and non-zero on any hard failure.

### Why the kernel-cost check is soft

Counting actual `futex(2)` calls needs `strace -f -c -e trace=futex`,
which needs a `ptrace` capability this project's `demo.sh` convention
doesn't grant (`docker run --rm`, no `--cap-add`). `ru_nvcsw` is a
reasonable, portable stand-in — a thread parked by a contended mutex's
`futex(FUTEX_WAIT)` and later woken registers a voluntary context
switch — but it is still a proxy, not the metric itself, and a
synthetic single-strand benchmark can plausibly show idle worker threads
parking in the `io_context`'s own scheduler while all the work sits on
one strand. The race-demo assertions above are the load-bearing checks;
this comparison is explanatory color, exactly as the chapter frames it.

## Running it

```bash
./demo.sh            # build + run asio_strand (all four modes) + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-12-asio-strand.sh`](../../../scripts/test-concurrency-demo-12-asio-strand.sh).

## Layout

```
12-asio-strand/
├── src/asio_strand.cpp   --mode strand|nostrand|strand-cost|mutex-cost, prints key=value line
├── conanfile.txt         [requires] boost/1.84.0 (shared=False), fmt/10.2.1
├── CMakeLists.txt        C++20, find_package(Boost COMPONENTS system), -O2, target asio_strand
├── Containerfile         UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime
├── verify.lua            Lua 5.4 assertion harness (race demo hard, kernel-cost soft)
├── demo.sh               the driver (docker build + docker run)
└── README.md             this file
```
