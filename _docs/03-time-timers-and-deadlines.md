---
title: "Time, Timers, and Deadlines"
order: 3
layout: tutorial
sectionid: docs
part: foundations
description: "The clock taxonomy a concurrent service actually needs, monotonic time, timeouts, and propagating a deadline across a call chain."
duration: "13 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/24-time-timers-deadlines.md | anchor books: Williams -->

## What we'll cover

- Distinguish `steady_clock` (monotonic) from `system_clock` (wall time) and why mixing them up breaks timeout logic.
- Cover the vDSO fast path that lets `clock_gettime` avoid a syscall, and why that matters for high-frequency time checks.
- Show how to express and enforce a timeout on a blocking or async operation.
- Propagate a single deadline across a chain of nested calls so no individual hop can silently exceed the caller's budget.

A thread that waits on a lock, a condition variable, or a socket needs to know how long it's been waiting, and it needs that answer to be right even while the system clock is being corrected underneath it. Get the clock choice wrong and the bug doesn't show up in testing — it shows up the first time `chronyd` or `ntpd` steps the wall clock during a slow request, and a timeout that should have fired early fires late, or fires immediately on a perfectly healthy connection. This chapter fixes the clock choice once, so every timeout and deadline in the rest of the book inherits it correctly.

## The Clock Taxonomy: steady_clock vs system_clock

`<chrono>` gives you several clocks, and exactly one of them is safe to build a duration or a deadline on. `std::chrono::system_clock` represents wall time — the thing a log timestamp or a "scheduled for 3pm" field needs — and it is explicitly *not* monotonic: it's disciplined by NTP, which means it can be stepped forward or backward by the system, and `system_clock::now()` reads can decrease between two successive calls. `std::chrono::steady_clock` counts from an unspecified epoch, usually near boot, and carries the one guarantee that matters here: it never steps and two successive reads always satisfy `t1 >= t0`. NTP can gently *slew* its rate over time, but it will never make it jump.

The rule that follows is absolute: **any duration or deadline is measured on `steady_clock`, never on `system_clock`.** A heartbeat timeout, a lock-acquisition budget, an RPC deadline — all of these are durations, "no progress for N seconds," and none of them should ever be expressed as a difference of two `system_clock::time_point` values. Compute a deadline as `system_clock::now() + 3s` and store it, and if the wall clock gets stepped backward by half a second before that deadline arrives, the stored deadline recedes into the future and a dead peer looks alive for an extra half second. Step the clock forward past the deadline instead, and a healthy connection is declared dead on the next check. `std::chrono::high_resolution_clock` deserves a specific warning here: the standard does not require it to be steady, and on some standard library implementations it is an alias for `system_clock`. Reach for `steady_clock` by name whenever the code is measuring an interval rather than displaying a timestamp, and never assume `high_resolution_clock`'s name implies the guarantee you actually need.

A second, quieter benefit of using `<chrono>`'s typed durations instead of raw integers is that the two clocks' `time_point`s aren't implicitly comparable or convertible to each other — a `steady_clock::time_point` and a `system_clock::time_point` are distinct types, and mixing them is a compile error rather than a value silently reinterpreted in the wrong units. That's worth leaning on deliberately: a function signature that takes a `std::chrono::steady_clock::time_point deadline` rather than a bare `int64_t deadline_ns` documents, and enforces at the type level, which clock the caller is required to have used. The handful of production incidents this chapter exists to prevent almost always trace back to a `long` or a `double` carrying a timestamp across a function boundary with no type to say which clock, or which unit, produced it.

<!-- DIAGRAM SPEC: Two horizontal clock tracks, cream #fdfbf7 background, time flowing left to right. Top track labeled "system_clock (wall time)" in blue #4a73b8, drawn as a dashed line that visibly steps backward partway across (a small loop-back kink) when an "NTP correction" label with a downward arrow hits it. A deadline marker placed before the kink is shown receding to the right after the step, with a red #c0392b annotation "a dead peer looks alive a little longer." Bottom track labeled "steady_clock (monotonic)" in green #5a8870, a straight, strictly increasing line with no kink under the same NTP correction event, its deadline marker fixed in place, annotated "timeout fires on real elapsed time." -->
{% include excalidraw.html name="03-clock-taxonomy" caption="Figure 3.1 — a wall-clock deadline can recede when NTP steps the clock; a steady_clock deadline cannot" %}

## Monotonic Time and the vDSO Fast Path

A deadline check that runs once per loop iteration on a hot path needs to be close to free, and on Linux it is. `clock_gettime(CLOCK_MONOTONIC, ...)` — what `steady_clock::now()` calls underneath — does not trap into the kernel. The kernel maps a read-only page, the vDSO, into every process's address space and updates a timekeeping structure on it at each timer tick; glibc's `clock_gettime` wrapper reads that page directly in userspace, with no `syscall` instruction and no context switch to the kernel and back. The cost of a `steady_clock::now()` call on a modern core is on the order of tens of nanoseconds — closer to a function call than to I/O.

The proof is an absence. Trace a program that reads the monotonic clock several times with `strace -e trace=clock_gettime`, and you will see **zero** matching lines, not because the reads didn't happen but because none of them became a syscall:

```console
[host]$ strace -e trace=clock_gettime ./build/clockprobe
+++ exited with 0 +++
```

What *does* trap is sleeping. You cannot sleep in userspace — the kernel has to take the thread off the run queue and arrange a wakeup — so `nanosleep`/`clock_nanosleep` and `timerfd_settime` show up in a trace exactly where `clock_gettime` doesn't. The asymmetry is the whole point of this section: checking the time is nearly free, so there is no excuse for a hot loop to avoid checking a deadline on every pass to save cycles. The excuse that remains valid is sleeping or blocking too eagerly, which does cost a real trip through the scheduler — the subject of the next section.

## Expressing and Enforcing Timeouts

Every blocking primitive in the standard library that can wait takes a `_for` (duration) or `_until` (time point) variant, and the time-point variants are clock-typed: `wait_until` takes a `time_point` whose clock determines how the deadline is interpreted. Pass a `steady_clock::time_point` and the wait is immune to a wall-clock step; pass a `system_clock::time_point` and it inherits exactly the bug the previous section described. `wait_for` is implemented in terms of `wait_until` against `steady_clock` internally, which is part of why it's the safer default when a relative duration is all you have.

A bounded wait on a condition variable, written against a `stop_token` so it can also be cancelled cooperatively, looks like this:

```cpp
bool wait_for_work(std::condition_variable_any& cv,
                    std::mutex& m,
                    std::stop_token st,
                    std::chrono::milliseconds timeout,
                    std::function<bool()> ready) {
    std::unique_lock lock(m);
    // steady_clock under the hood; immune to a wall-clock step mid-wait.
    return cv.wait_for(lock, st, timeout, std::move(ready));
}
```

The same discipline applies outside the standard library's own waiters. A blocking read on a socket has no native timeout parameter; the usual shape is to compute the remaining budget from a `steady_clock` deadline on every loop iteration and hand that remainder to `poll` or `epoll_wait`, which take a millisecond timeout and return 0 when it elapses with nothing ready:

```cpp
auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
for (;;) {
    const auto left = deadline - std::chrono::steady_clock::now();
    if (left <= std::chrono::steady_clock::duration::zero()) {
        return TimedOut;
    }
    const int timeout_ms = static_cast<int>(
        std::chrono::duration_cast<std::chrono::milliseconds>(left).count()) + 1;
    const int n = ::poll(fds, nfds, timeout_ms);
    if (n == 0) return TimedOut;
    // handle ready fds, and reset `deadline` on real traffic if this is a
    // liveness timeout rather than a one-shot operation deadline
}
```

Recomputing `left` from a fixed `deadline` every iteration, rather than counting down a separately-maintained duration, is what keeps retried `EINTR`s and spurious wakeups from silently extending the total wait — the deadline is a fixed point in monotonic time, not a budget that has to be manually decremented and can be decremented wrong.

## Propagating Deadlines Across Calls

A single operation rarely stays inside one function. A request arrives, calls into a connection-pool checkout, which calls into a query executor, which calls into a retry loop — and the naive approach of giving each layer its own fixed timeout quietly breaks the caller's actual budget. If the caller wants a 500 ms response and each of three nested calls independently applies a 500 ms timeout "to be safe," the request can legitimately take 1.5 seconds before anything reports a failure, because every hop measured its own patience instead of the caller's.

The fix is to compute one deadline at the top of the call chain and pass that single `steady_clock::time_point` down through every hop, rather than passing a duration that gets re-applied at each level:

```cpp
using Deadline = std::chrono::steady_clock::time_point;

Result execute_query(Deadline deadline) {
    if (std::chrono::steady_clock::now() >= deadline) {
        return Result::DeadlineExceeded;  // already out of budget; don't even start
    }
    return run_with_deadline(deadline);
}

Result checkout_and_execute(ConnectionPool& pool, Deadline deadline) {
    auto conn = pool.checkout(deadline);        // same deadline, not a fresh timeout
    if (!conn) return Result::DeadlineExceeded;
    return execute_query(deadline);
}

Result handle_request(ConnectionPool& pool, std::chrono::milliseconds budget) {
    const auto deadline = std::chrono::steady_clock::now() + budget;  // computed once
    return checkout_and_execute(pool, deadline);
}
```

Every hop does the same two things: check whether the deadline has already passed before doing any work, and hand the *same* `time_point` further down rather than deriving a new one. No hop can silently extend the caller's total budget, and a hop that's already out of time fails immediately instead of starting work it can't finish. This is the exact discipline [Concurrent REST Endpoints]({{ '/docs/24-concurrent-rest-endpoints/' | relative_url }}) and [Concurrent gRPC Services]({{ '/docs/25-concurrent-grpc-services/' | relative_url }}) build on — an HTTP client's request timeout and gRPC's own deadline propagation are both, under the hood, exactly this pattern: one absolute point in monotonic time, carried as data through every layer that touches the request, rather than a duration re-measured and re-trusted at each hop.

<!-- DIAGRAM SPEC: Horizontal call chain, cream #fdfbf7 background, four boxes left to right: "handle_request" (blue #4a73b8, computes deadline = now + 500ms), "checkout_and_execute" (green #5a8870, receives deadline unchanged), "execute_query" (green #5a8870, receives deadline unchanged), "run_with_deadline" (orange #a06030, receives deadline unchanged). A single amber horizontal bar below all four boxes represents the one shared deadline value, with a shrinking amber highlight showing remaining budget narrowing left to right as time passes within each hop. A red #c0392b "X" marks a hop that checks the deadline and returns DeadlineExceeded immediately rather than starting work, contrasted with a dashed grey alternative path above labeled "naive: each hop re-applies 500ms -- total budget silently triples." -->
{% include excalidraw.html name="03-deadline-propagation" caption="Figure 3.2 — one deadline value carried unchanged through every hop, versus each hop re-deriving its own timeout and silently multiplying the caller's budget" %}

A runnable version of this chain, with an injectable delay at the middle hop, lives at `examples/concurrency/03-timers-and-deadlines/`.

<!-- EXAMPLE SPEC: a three-hop call chain matching the snippet above, with a configurable artificial delay injectable at any one hop, proving the outer caller's total wall-clock budget is never exceeded regardless of which hop is slow; plus a clockprobe subprogram traced with strace to confirm zero clock_gettime syscalls for repeated steady_clock reads while nanosleep/timerfd calls do appear; verified by verify.lua asserting (1) total elapsed time across the chain never exceeds the configured budget by more than scheduler jitter, (2) a hop that starts after the deadline has passed returns DeadlineExceeded without doing work, and (3) the strace capture contains zero clock_gettime lines; built and run via Docker through lgtm-docker-stack -->

## Running in a container

A monotonic deadline is immune to NTP, but it is not immune to the container not running. CFS bandwidth control enforces a cgroup's `cpu.max` quota by throttling the cgroup for the remainder of each accounting period (100 ms by default) once it has burned its allotted CPU time — and while throttled, the container's threads don't get scheduled at all, even though `CLOCK_MONOTONIC` keeps advancing in real wall time exactly as it should. A thread whose deadline check is `steady_clock::now() >= deadline` will see the deadline pass during a throttling stall even though the thread did nothing wrong and burned no excess CPU time of its own — the clock behaved correctly; the scheduler didn't give the thread a chance to notice sooner.

This produces a specific, confusing failure mode: a service with a tight deadline budget (say, 10 ms) that works fine unthrottled starts reporting spurious `DeadlineExceeded` under load, not because any hop got slower, but because the container's quota was exhausted and the whole process paused for a chunk of a 100 ms period. `cat /sys/fs/cgroup/<path>/cpu.stat` exposes `nr_throttled` (how many periods triggered a throttle) and `throttled_usec` (cumulative microseconds spent throttled); a spike in those counters correlating with a spike in deadline exceedances is the signature, and it rules out "the query got slower" in favor of "the container didn't get to run." The fix at the deployment layer is sizing the CPU request/limit with enough headroom that a normal request doesn't straddle a throttling period; the fix at the code layer is building deadline budgets with enough margin that a single throttling stall doesn't exhaust them, and logging `nr_throttled` alongside deadline-exceeded errors so the two are never debugged as if they were the same bug.

## Standards: C++20 / C++23 / C++26

`<chrono>` itself changed shape more in C++20 than in the two standards since. C++20 added calendar and timezone support — `year_month_day`, `zoned_time`, and new clock types including `utc_clock`, `tai_clock`, `gps_clock`, and `file_clock` — giving the wall-clock half of this chapter's taxonomy a proper vocabulary for display and scheduling-by-calendar, entirely separate from `steady_clock`'s job of measuring elapsed time. C++23 doesn't add new clocks; it finishes wiring the C++20 calendar types into `std::format`, so a duration or a `zoned_time` can be formatted directly with a chrono format spec instead of being decomposed by hand. C++26 proposes `std::execution` schedulers (P2300) with a `schedule_after`/time-based scheduling vocabulary that expresses "run this after a deadline" as a composable sender rather than as a `sleep_for` call or a raw `time_point` comparison — the same deadline-as-a-value idea this chapter builds by hand, lifted into the sender/receiver model Chapter 1 introduced. As with that chapter, no shipping compiler implements the scheduling portion of P2300 yet; treat it as proposed.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
// New calendar/timezone vocabulary for the *wall-clock* half of the
// taxonomy -- never used for the deadline itself, only for displaying it.
#include <chrono>
const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
const auto wall_now = std::chrono::system_clock::now();
const auto local = std::chrono::zoned_time{std::chrono::current_zone(), wall_now};
// `local` is for a log line; `deadline` is what the code actually waits on.
```

```cpp
// C++23
// std::format gains full chrono support: format a duration or a zoned_time
// directly instead of decomposing hours/minutes/seconds by hand.
#include <format>
std::string msg = std::format("deadline in {:%T}, local time {:%Y-%m-%d %H:%M:%S %Z}",
                               std::chrono::seconds(3), local);
```

```cpp
// C++26 (proposed; no shipping compiler support as of GCC 16 / clang 22)
// std::execution expresses "run after a deadline" as a composable sender
// rather than a sleep_for call or a hand-rolled time_point comparison.
auto work = std::execution::schedule_after(scheduler, std::chrono::milliseconds(500))
          | std::execution::then([] { return check_liveness(); });
std::execution::sync_wait(std::move(work));
```

## What we learned

- `steady_clock` never steps and is the only correct clock for a duration or a deadline; `system_clock` is wall time, NTP-steppable in both directions, and correct only for timestamps meant for humans or logs.
- `clock_gettime` on `CLOCK_MONOTONIC` is a vDSO read, not a syscall — a program can check a deadline on every loop iteration for tens of nanoseconds, while a trace of the same program shows zero `clock_gettime` lines and the sleeping calls it actually does make.
- `wait_for`/`wait_until` are clock-typed; pass a `steady_clock::time_point` to `wait_until` so a wall-clock step can never corrupt the wait, and recompute a `poll`/`epoll` timeout from a fixed `steady_clock` deadline each iteration rather than counting down a separately-tracked duration.
- Propagate one absolute deadline through a call chain instead of re-applying a fresh timeout at each hop — the pattern underneath both HTTP request timeouts and gRPC deadline propagation in later chapters.
- Under a cgroup CPU quota, a monotonic deadline can still expire from CFS throttling rather than genuine slowness; `cpu.stat`'s `nr_throttled`/`throttled_usec` distinguishes "the container didn't run" from "the work was actually slow."
