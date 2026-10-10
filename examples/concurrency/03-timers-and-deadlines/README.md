# concurrency/03-timers-and-deadlines — deadline propagation across a call chain

Compendium reference:
[Doc 3 — Time, Timers, and Deadlines](../../../_docs/03-time-timers-and-deadlines.md)

The runnable companion to compendium Doc 3. The one-line takeaway:
**compute one deadline at the top of a call chain and pass that single
`steady_clock::time_point` down through every hop** — never a duration
re-applied at each level — so no hop can silently extend the caller's total
budget.

## What it demonstrates

[`src/deadline_chain.cpp`](src/deadline_chain.cpp) is a runnable version of
the chapter's own four-function snippet: `handle_request` computes the
deadline once, then `checkout_and_execute` → `execute_query` →
`run_with_deadline` each receive the identical `time_point` and each check
it before doing any work.

```
handle_request(budget) -> checkout_and_execute(deadline) -> execute_query(deadline) -> run_with_deadline(deadline)
```

Two modes:

- **`--budget-ms N --delay-hop checkout|query|run|none --delay-ms M`**
  (default) — runs the full chain once. `--delay-hop`/`--delay-ms` inject an
  artificial delay at exactly one hop. That delay is itself deadline-aware:
  it sleeps until `min(now + delay, deadline)`, never past the shared
  deadline — because a hop that oversleeps the deadline it was handed would
  defeat the entire chapter. This is what lets the demo prove the caller's
  total wall-clock budget is never exceeded *regardless of which hop is
  slow*: no single hop can itself run past the deadline, and every hop
  checks before it works.
- **`--direct checkout|query|run`** — calls one hop function directly with a
  deadline already 50ms in the past, bypassing the chain. Proves a hop
  entered after its deadline has already passed returns
  `DeadlineExceeded` *without doing any work* — tracked with a
  `work_performed` flag set only inside the section of the hop that runs
  after its own pre-check passes.

```
mode=chain budget_ms=150 delay_hop=query delay_ms=750 result=DeadlineExceeded elapsed_ms=150.41 trace=checkout_and_execute:ok,execute_query:deadline_exceeded_after_delay
mode=direct hop=run result=DeadlineExceeded work_performed=0 elapsed_ms=0.02
```

[`src/clockprobe.cpp`](src/clockprobe.cpp) is the chapter's vDSO proof: it
reads `steady_clock::now()` 5,000 times (accumulated into a checksum so the
optimizer can't delete the loop), then makes exactly one `sleep_for` call.
Traced with `strace -e trace=clock_gettime`, the read loop should produce
**zero** matching lines; the one sleep should produce a `nanosleep`/
`clock_nanosleep` line.

## Verification: verify.lua

[`verify.lua`](verify.lua) runs inside the container and checks, per Doc 3's
EXAMPLE SPEC:

1. **Hard.** Total elapsed time across the chain never exceeds the
   configured budget by more than a 150ms scheduler-jitter margin — checked
   for a happy path (no delay) and for an oversized delay (5× the budget)
   injected at each of the three hops in turn. Every one of those slow-hop
   cases must also report `DeadlineExceeded`.
2. **Hard.** A hop called directly (`--direct`) with an already-expired
   deadline returns `DeadlineExceeded` with `work_performed=0`, for all
   three hops.
3. **Soft / best-effort.** A `strace -e trace=clock_gettime` capture of
   `clockprobe` contains zero `clock_gettime` lines. `strace` is
   intentionally **not installed** in the runtime image — it isn't
   guaranteed to be in `ubi10-minimal`'s enabled repo set, and the chapter's
   own EXAMPLE SPEC marks this check as optional ("if strace isn't in the
   minimal image, skip it and note it; don't hard-fail"). `verify.lua`
   checks for `strace` on `PATH` and prints a note instead of failing when
   it's absent.

`verify.lua` exits 0 on pass (with or without the strace check having run)
and non-zero on any hard failure.

### Why 150ms of jitter margin

The chapter's own "Running in a container" section explains the source of
this slop directly: under a CFS CPU quota, a deadline check can see the
deadline pass during a throttling stall (the default accounting period is
100ms) even though the thread did nothing wrong. The margin here is sized
to absorb one such stall without masking a real regression — a hop that
blows the budget by seconds, not milliseconds, still fails.

## Running it

```bash
./demo.sh            # build + run deadline_chain/clockprobe + verify.lua
./demo.sh --clean    # remove the image
DEMO_NO_PAUSE=1 ./demo.sh   # skip the presenter pause (CI / scripted)
```

CI verification:
[`../../../scripts/test-concurrency-demo-03-timers-and-deadlines.sh`](../../../scripts/test-concurrency-demo-03-timers-and-deadlines.sh).

To see the strace proof directly from the host (strace is not shipped
inside the image):

```bash
docker run --rm --entrypoint clockprobe cpp-tut/concurrency-03-timers-and-deadlines:latest &
# or, with a local build: strace -e trace=clock_gettime,nanosleep,clock_nanosleep ./build/clockprobe
```

## Layout

```
03-timers-and-deadlines/
├── src/deadline_chain.cpp   the chapter's 4-hop chain, one shared deadline, injectable delay, direct-call mode
├── src/clockprobe.cpp       5,000 steady_clock reads (vDSO) + one sleep_for (real syscall)
├── conanfile.txt            no external deps — pure standard library + POSIX sleep
├── CMakeLists.txt           C++20, -O2, two targets: deadline_chain, clockprobe
├── Containerfile             UBI 10 (gcc + cmake + conan) builder → ubi-minimal + lua runtime (no strace)
├── verify.lua                Lua 5.4 assertion harness (budget/deadline hard, strace soft)
├── demo.sh                   the driver (docker build + docker run)
└── README.md                 this file
```
