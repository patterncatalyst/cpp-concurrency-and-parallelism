---
title: "Debugging Real Races and Deadlocks"
order: 27
layout: tutorial
sectionid: docs
part: correctness-errors-and-debugging
description: "Reproducing an actual data race and an actual deadlock, driving gdb against a multithreaded program, and reading a ThreadSanitizer report line by line."
duration: "17 min"
---

<!-- PROVENANCE: NEW (draws on linux-systems-programming/_docs/28-gdb-and-remote-debugging.md) | anchor books: Son, lsp tooling -->

## Learning objectives

By the end of this chapter you can:

- Construct a reproducible data race from an unsynchronized shared counter and explain why a clean-looking run proves nothing about its absence.
- Force a two-mutex AB/BA deadlock to fail on every run using a `std::latch`, instead of hoping an unreliable timing window gets hit.
- Drive gdb against a multithreaded program: read `info threads`, switch with `thread N`, and catch a live deadlock with `thread apply all bt`.
- Read a ThreadSanitizer report line by line and map each section back to the per-thread vector clock that produced it.
- Attach gdb and run ThreadSanitizer inside a container, accounting for `ptrace` permissions and CPU-quota effects on both.

## Why this matters

A race or a deadlock that only shows up once a quarter, under load, on a host nobody is watching, is exactly the kind of bug that survives code review and a full test run undetected. The only way to get good at reading gdb backtraces and ThreadSanitizer reports is to have a reliable, on-demand failure to point them at, which is why this chapter builds one of each before touching either tool.

Treating a clean run as proof of correctness is the single most common mistake made around concurrency bugs, and it's backwards: a program with a race can pass every test today and fail the moment the scheduler, kernel, or core count changes. Learning to force the failure window open, rather than wait for it, is what turns an occasional, maddening bug report into a deterministic reproduction a debugger can actually work with.

## What we'll cover

- Construct a real, reproducible data race rather than a hypothetical one, as this chapter's worked example.
- Construct a real, reproducible deadlock from a lock-ordering violation.
- Drive gdb against the multithreaded program: inspecting per-thread backtraces, switching threads, and setting thread-scoped breakpoints.
- Read a ThreadSanitizer report for the data race and map each line back to the source locations involved.

A race explained in the abstract ("two threads touch the same variable without synchronization") teaches nothing about what to do the next time one shows up in a real codebase. Races and deadlocks are scheduling-dependent by nature, which means a program that is actually broken can still pass every plain, un-instrumented run you throw at it; a correct-looking result this time is evidence of nothing. This chapter builds one minimal program broken by design for each failure mode, makes both failures reproducible on demand rather than occasional, and then reads what gdb and ThreadSanitizer actually say about them, line by line.

## Reproducing a Real Data Race

The race itself is the same shape [Atomics and the Memory Model]({{ '/docs/08-atomics-and-the-memory-model/' | relative_url }}) uses to introduce happens-before edges, built this time to break by design: two `std::jthread`s each run a tight loop incrementing a shared, plain `int counter` with no mutex and no atomic. A non-atomic `++counter` is not one instruction at the source level; it is a load, an add, and a store, and with no synchronization between the two threads there is no happens-before edge connecting one thread's store to the other's load. That absence is not "probably fine, usually": the C++ object model defines two unsynchronized accesses to the same object, at least one a write, as a **data race**, and a program containing one has undefined behavior, independent of whether a particular run happens to print the mathematically correct total.

That last point is the trap worth building the race specifically to demonstrate: a plain, un-instrumented run of this exact program can print the correct sum on one invocation and a corrupted, lower sum on the next, purely as a function of how the scheduler happened to interleave the two threads' load-add-store sequences that time. Treating "it printed the right number" as proof of correctness is exactly backwards for a race: the absence of a symptom is not the absence of the defect, and a race that happens to resolve favorably under today's scheduler, kernel, and core count can resolve unfavorably the moment any of those three things changes, with no code change at all. `-O2` sharpens the danger further: the standard permits a compiler to assume a race-free program, so nothing stops it from hoisting a read of `counter` out of a loop into a register and never reloading it, in which case the race's symptom isn't a wrong number at the end: it's a thread that never observes the other's writes at all.

## Reproducing a Real Deadlock

The deadlock reuses the exact AB/BA shape [Mutual Exclusion and Locking]({{ '/docs/06-mutual-exclusion-and-locking/' | relative_url }}) already walked through (two mutexes, two threads, each acquiring them in the opposite order), but keeps the broken `lock_guard` version instead of applying that chapter's `scoped_lock` fix, specifically so there is a deadlock left to catch. The twist that makes it worth building rather than reading about: the textbook two-mutex deadlock, left to pure scheduling luck, often does not happen every run: both threads have to reach their second `lock()` call with the other's first lock already held, a timing window that can be narrow enough on an idle, fast machine that the program appears to work nine times out of ten.

A reliable reproduction forces that window open rather than hoping for it. A `std::latch` (covered in [Coordination Primitives]({{ '/docs/07-coordination-primitives/' | relative_url }})) initialized to the thread count, with both threads counting down and waiting on it immediately after acquiring their first lock and before attempting their second, guarantees that neither thread can reach its second acquisition until both already hold their first, turning "sometimes deadlocks" into "deadlocks on every single run," which is the only version of this bug worth handing to a debugger or a CI gate.

<!-- EXAMPLE SPEC: examples/concurrency/27-debugging-races-deadlocks/: two small C++20 programs. (a) racy_counter: two std::jthreads incrementing a shared non-atomic int in a tight loop with no synchronization, built once plain and once under -fsanitize=thread, plus an atomic-counter "fixed" variant built the same two ways; verify.lua runs the TSan build of the racy variant and asserts a nonzero exit plus "data race" in stderr naming the increment's source line, then runs the TSan build of the fixed variant and asserts a clean exit 0. (b) ab_ba_deadlock: two threads acquiring std::mutex a and b via std::lock_guard in opposing order, with a std::latch(2) forcing both threads to hold their first lock before attempting the second; verify.lua launches it backgrounded, waits briefly, attaches `gdb -p $pid --batch -ex 'thread apply all bt'`, and asserts the combined backtrace names pthread_mutex_lock frames in both threads plus the two Account-level acquisition functions, then confirms the process is still alive and has to be reaped with `timeout --signal=KILL`; a separate std::scoped_lock-fixed build of the identical acquisition pattern is asserted to exit 0 under the same timeout. Docker via lgtm-docker-stack, image built with CAP_SYS_PTRACE enabled for the gdb-attach step and gdb/libtsan present. -->

## gdb on Multithreaded Programs

Everything gdb does for an ordinary single-threaded crash (breakpoints, `print`, `bt`, stepping) extends to a multithreaded program through a small, specific vocabulary layered on top. `info threads` lists every thread gdb knows about, each with an id, its OS thread id, and the function it is currently stopped in. It is the first command to run against a hung process, since a deadlock's signature is visible right there: every thread involved sits inside a locking primitive, not inside application logic. `thread N` switches gdb's notion of the current thread, after which `bt`, `frame`, and `print` all operate against that thread's own stack, exactly as if it were the only thread in the program.

`thread apply all bt` is the one command that actually catches a deadlock: rather than switching threads one at a time, it backtraces every thread in a single pass, and reading the output for a lock-ordering deadlock means looking for the cycle directly: one thread's backtrace sitting inside `pthread_mutex_lock` (or glibc's internal `__lll_lock_wait`) on mutex `a`, a second thread's backtrace sitting inside the identical call on mutex `b`, with each thread's own source frame showing it already holds the other mutex. Because glibc's `pthread_mutex_t` records its current owner in `__data.__owner`, `print *(pthread_mutex_t*)&a` (or printing the C++ wrapper's underlying handle) from either thread's frame names the owning thread id directly: the cycle is not inferred from reading source, it is read straight out of the mutex's own live state.

Attaching to an already-hung process rather than starting it fresh under gdb is the common case for a process that deadlocked minutes or hours ago in production: `gdb -p <pid>` attaches live, and because a deadlocked process is by definition not making progress, there is nothing to interrupt: the backtrace is stable the instant gdb attaches and stays that way until you detach. `set scheduler-locking on` is the control that matters once a session needs to single-step one thread without every other thread racing ahead concurrently and scrambling the picture; its `step` variant locks scheduling only while single-stepping and releases other threads between explicit `continue` commands, a middle ground useful when you want to watch one thread's interleaving-sensitive region in isolation without freezing the rest of the program for the whole session. A **watchpoint** (`watch counter`) stops execution the instant a specific memory location changes, naming the exact write that corrupted shared state rather than the surrounding function. Hardware watchpoints, backed by the CPU's debug registers, cost almost nothing per access but are limited in count (four on x86-64); a software watchpoint has no such limit but single-steps the entire program to check the value after every instruction, which is legitimately too slow for anything beyond a narrow, already-isolated window. A thread-scoped breakpoint (`break increment thread 2`) stops only when thread 2 specifically reaches that location, the tool for isolating one worker out of a pool of otherwise-identical threads all running the same function.

{% include excalidraw.html name="27-gdb-lock-cycle-backtrace" caption="Figure 27.1: thread apply all bt on the hung AB/BA deadlock, reading the lock cycle directly off two threads' backtraces and the mutexes' own owner fields" %}
<!-- DIAGRAM SPEC: cream #fdfbf7 background, two side-by-side thread columns under a header "gdb -p <pid> -ex 'thread apply all bt'". Left column "Thread 2", blue #4a73b8: three stacked frames bottom to top, "main.cpp:70 run_transfer(from=b, to=a)", "lock_guard lock_b(b.mutex) -- held", "pthread_mutex_lock(a.mutex) -- BLOCKED", the top frame outlined in red #c0392b. Right column "Thread 3", green #5a8870: three stacked frames, "main.cpp:75 run_transfer(from=a, to=b)", "lock_guard lock_a(a.mutex) -- held", "pthread_mutex_lock(b.mutex) -- BLOCKED", top frame outlined in red. Two red dashed arrows cross between the columns: one from Thread 2's blocked frame to Thread 3's held-lock frame labeled "waiting on a, owned by Thread 3", one from Thread 3's blocked frame to Thread 2's held-lock frame labeled "waiting on b, owned by Thread 2". A footer orange #a06030 box reads "print *(pthread_mutex_t*)&a -> __data.__owner names Thread 3 directly -- the cycle is read off live state, not inferred from source". -->

## Reading a ThreadSanitizer Report

The output below is **representative of the shape a ThreadSanitizer report takes against this chapter's racy-counter program**: illustrative formatting to teach how to read one, not a transcript captured from a run in this book, since no example here is built or executed as part of writing it:

```
WARNING: ThreadSanitizer: data race (pid=12345)
  Write of size 4 at 0x7b0400000d80 by thread T2:
    #0 increment(int&) racy_counter.cpp:14
    #1 worker(int&) racy_counter.cpp:19

  Previous write of size 4 at 0x7b0400000d80 by thread T1:
    #0 increment(int&) racy_counter.cpp:14
    #1 worker(int&) racy_counter.cpp:19

  Location is global 'counter' of size 4 at 0x7b0400000d80

  Thread T2 (tid=12346, running) created by main thread at:
    #0 pthread_create
    #1 main racy_counter.cpp:30

SUMMARY: ThreadSanitizer: data race racy_counter.cpp:14 in increment(int&)
```

Each section maps onto a specific fact TSan's instrumentation observed during the one execution it just ran. The two "Write of size 4" blocks are the conflicting accesses themselves: both writes rather than a read and a write, in this particular shape, because `++counter` is a read-modify-write and TSan reports the write half of each conflicting operation along with the full call stack that reached it, naming `racy_counter.cpp:14` as precisely as the compiler's debug info allows. "Location is global 'counter'" identifies what was raced on, which matters more once a report involves a heap allocation or a class member rather than an obviously-named global; TSan additionally reports the allocation site for heap locations, letting a report on a member variable be traced back to which object's instance was involved. The "created by" block reconstructs each thread's parentage, which is how a report involving a thread pool's worker threads still names a human-meaningful creation site rather than an anonymous pthread id.

The report's deeper mechanism is the one [Atomics and the Memory Model]({{ '/docs/08-atomics-and-the-memory-model/' | relative_url }}) already introduced: TSan maintains a vector clock per thread, one logical-time entry per thread it has observed, and updates it at every synchronization point (a mutex unlock/lock pair, an atomic release/acquire, a thread join) to track precisely which other threads' prior writes a given access is guaranteed to have observed. Two accesses to the same location, at least one a write, with neither thread's vector clock showing a happens-before relationship to the other, is exactly TSan's definition of a race: the same definition the standard uses, checked dynamically against the one interleaving the instrumented binary actually executed, rather than proven for every interleaving the program could ever hit. That distinction is the report's most important limitation: TSan is a **dynamic** analysis, so a clean run with no warnings means no race was observed on *this* execution's schedule and inputs, not that no race exists in the program. A race gated behind a rare interleaving, an input the test suite never exercises, or code TSan's instrumentation never touched (a precompiled third-party `.so` not rebuilt with `-fsanitize=thread`) can sit undetected through an arbitrarily long run of clean reports. By default TSan continues past a detected race rather than aborting immediately, accumulating a running count and exiting with a nonzero code once the process ends (the specific value configurable via `TSAN_OPTIONS=exitcode=`), so a single run can surface more than one distinct race rather than stopping at the first.

{% include excalidraw.html name="27-tsan-report-anatomy" caption="Figure 27.2: a representative TSan report's five sections mapped to what the instrumentation actually tracked: two conflicting accesses, the raced-on location, and each thread's creation site" %}
<!-- DIAGRAM SPEC: cream #fdfbf7 background. A single annotated report card styled as a terminal block, five horizontal bands stacked top to bottom, each with a colored left tab and callout pointing right. Band 1 (red #c0392b tab) "Write of size 4 ... by thread T2" -> callout "conflicting access #1, with full call stack to the exact source line". Band 2 (red tab) "Previous write ... by thread T1" -> callout "conflicting access #2 -- no happens-before edge found between T1's write and T2's write". Band 3 (blue #4a73b8 tab) "Location is global counter" -> callout "what was raced on; a heap location additionally reports its allocation-site stack". Band 4 (green #5a8870 tab) "Thread T2 created by main thread" -> callout "parentage reconstruction -- names a human call site, not a bare pthread id". Band 5 (orange #a06030 tab) "SUMMARY: data race racy_counter.cpp:14" -> callout "one line per distinct race; process exits nonzero once all threads finish, not at the first report". A footer note reads: every fact here comes from TSan's per-thread vector clock, updated at each mutex unlock/lock, atomic release/acquire, and join -- this is dynamic analysis, so a clean report covers only the interleaving this run actually hit. -->

## Running in a container

gdb's ability to attach to a running process at all depends on `ptrace(2)` permission, and a container is the environment most likely to have withdrawn it: a default container run typically grants `CAP_SYS_PTRACE` only for tracing a process's own children, which is enough for `gdb --batch -ex run` launching the target itself but not enough for `gdb -p <pid>` attaching to a process started separately, and Kubernetes' default seccomp profile plus a locked-down `securityContext` can remove the capability from both cases. `--cap-add=SYS_PTRACE` restores it for a specific container without the much broader `--security-opt seccomp=unconfined`, which disables the entire seccomp filter rather than this one syscall family; a scoped custom seccomp profile allowing exactly `ptrace` is the better-practiced middle ground for an image meant specifically for debugging sessions. In Kubernetes, `kubectl debug` creates an ephemeral debug container sharing the target pod's process namespace specifically so a gdb binary that never shipped in the production image can still attach to its process tree.

TSan interacts with a container differently, because it needs no `ptrace` at all: its instrumentation runs inside the traced process itself, added at compile time, so a hardened container that drops `SYS_PTRACE` entirely does not block a TSan-instrumented binary from reporting a race the way it blocks gdb from attaching to one. What TSan does need is address space: its shadow-memory bookkeeping reserves a large virtual-memory region per process, which an aggressive `ulimit -v` or a container's memory-overcommit policy can reject at process startup with an allocation failure that looks nothing like a test failure and everything like a broken image. CPU quota compounds both tools' costs multiplicatively rather than additively: TSan's own instrumentation overhead stacked on top of a container capped at a fraction of a core turns what would be a fast local reproduction into a run that can itself trip a CI job's timeout, a failure mode easy to misdiagnose as "the race stopped reproducing" when the real cause is scheduling, not the defect.

## Standards: C++20 / C++23 / C++26

C++20 leaves capturing a stack trace entirely to the debugger or a third-party library: there is no standard-library way for a program to describe its own call stack, so a diagnostic printed from inside the program (a log line, an assertion failure) names only what the programmer manually threaded through as context, and reconstructing the actual call chain means reaching for gdb, `backtrace()`/`backtrace_symbols()` from glibc, or a library like backward-cpp. C++23's `<stacktrace>` header changes that: `std::stacktrace::current()` captures the calling thread's stack into an ordinary, copyable value right where it's called, with each `std::stacktrace_entry` exposing its source file, line, and description, and `std::to_string` rendering the whole thing for a log line. A lock-ordering check that detects a violation at runtime (an assertion that a given mutex is not already held by the current thread, checked via a thread-local set of currently-held mutex addresses maintained by the application) can now attach a precise, in-process stack trace to its diagnostic without a debugger attached at all. C++26's proposed Contracts facility (accepted via P2900, with only early, incomplete experimental compiler support as of this writing; no production toolchain implements it) pushes the same idea earlier: a function precondition expressed directly in its declaration is checked at every call, deterministically, independent of which interleaving a particular run happened to hit, which is a fundamentally different reliability shape from a race detector that only reports a violation on the specific execution that triggers it.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20 -- no standard way to capture a stack trace from inside the
// program; a diagnostic names only what's manually threaded through,
// and reconstructing the real call chain needs gdb or glibc's backtrace().
void assert_not_held(std::mutex& m) {
    if (!held_by_this_thread(m)) return;
    std::cerr << "lock-order violation detected (attach gdb for a trace)\n";
    std::abort();
}
```

```cpp
// C++23 -- std::stacktrace::current() captures the call chain as an
// ordinary value, right at the point of the violation, with no debugger
// attached and no third-party backtrace library involved.
#include <stacktrace>

void assert_not_held(std::mutex& m) {
    if (!held_by_this_thread(m)) return;
    auto trace = std::stacktrace::current();
    std::cerr << "lock-order violation detected:\n" << std::to_string(trace);
    std::abort();
}
```

```cpp
// C++26 (proposed Contracts, P2900; only early, incomplete experimental
// compiler support as of this writing, no production toolchain) -- the
// precondition is part of the function's declaration, checked at every
// call deterministically, not only on the one interleaving that hits it.
void transfer(Account& from, Account& to, long amount)
    pre(!held_by_this_thread(from.mutex) && !held_by_this_thread(to.mutex))
{
    std::scoped_lock lock(from.mutex, to.mutex);
    // ...
}
```

## What we learned

- A race or a deadlock that only happens occasionally under natural scheduling is still a real bug; forcing the window open (a `std::latch` serializing both threads' first-lock acquisition before either attempts its second) turns "sometimes" into "every run," which is the only form of either bug worth handing to a tool.
- `thread apply all bt` catches a live deadlock by exposing the lock cycle directly: two threads each blocked in `pthread_mutex_lock` on the mutex the other one owns, confirmed by printing the mutex's own `__data.__owner` field rather than inferred from source.
- `scheduler-locking`, hardware watchpoints, and thread-scoped breakpoints exist specifically because a plain `break`/`continue` session, unmodified, lets every other thread race ahead while you inspect one; each of the three trades a different kind of control for a different kind of cost.
- A ThreadSanitizer report names the two conflicting accesses, the raced-on location, and each thread's creation site, all derived from per-thread vector clocks updated at every synchronization point; because it is dynamic analysis, a clean TSan run proves only that the exercised schedule and inputs hit no race, never that the program contains none.

Next, **sanitizers and dynamic analysis** broadens the toolbox this chapter's TSan report opened: AddressSanitizer's memory-error coverage, Valgrind's no-rebuild alternative, and what each one catches that the others miss.
