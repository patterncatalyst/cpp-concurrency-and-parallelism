---
title: "Threads in Modern C++"
order: 4
layout: tutorial
sectionid: docs
part: foundations
description: "std::thread and std::jthread, cooperative cancellation with stop_token, and the lifetime and ownership rules that govern joining versus detaching."
duration: "16 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/51-std-threading.md | anchor books: Williams, Grimm -->

## What we'll cover

- Compare `std::thread` and C++20's `std::jthread`, including `jthread`'s automatic request-and-join on destruction.
- Introduce `stop_token` and `stop_source` as the standard's cooperative-cancellation mechanism, and what it refuses to do.
- Establish the ownership and lifetime rules a thread object imposes on the code that creates it.
- Contrast joining and detaching, and why detaching is rarely the right default in service code.

## std::thread and std::jthread

`std::thread` wraps an operating-system thread in a move-only object: construct
it with a callable and arguments, and the thread starts running immediately,
before the constructor even returns. There is no separate "start" step and no
way to create a `std::thread` in a suspended state. That immediacy is easy to
forget, because it means a thread object can begin touching shared state while
the constructor that produced it is still on the caller's stack.

The object itself carries almost no information. `std::thread::id` is opaque
and comparable only for equality and ordering; `joinable()` reports whether the
thread still has an operating-system thread backing it (it does, until you
`join()` or `detach()` it, after which the object is a shell). `get_id()`
returns the id; `hardware_concurrency()` is a static hint, not a guarantee,
about how many threads can usefully run in parallel on the host. None of this
is a critique of `std::thread` so much as a description of its scope: it is a
thin, portable handle to a native thread, nothing more. Everything else
(naming a thread, pinning it to a core, setting its scheduling policy) lives
one level down, reachable only through `native_handle()`.

C++20's `std::jthread` ("joining thread") is a strict superset built to close
the one gap in that design that actually caused bugs in practice: a
`std::thread` that is still joinable when its destructor runs calls
`std::terminate()`. That is a deliberate choice: the committee would rather
crash loudly than leak a running thread silently. But it means every early
return, every exception, every forgotten `join()` on a control path nobody
tested is a live grenade. `jthread`'s destructor instead requests a stop and
joins, unconditionally, with no way to opt out short of calling `detach()`
yourself first. A function that constructs a `jthread`, does some work, and
returns through five different branches no longer needs five matching
`join()` calls; it needs none.

```cpp
std::jthread worker([] {
    do_work();
});
// no explicit join anywhere below; every return path is safe
```

The second half of `jthread`'s contribution is that its callable may accept a
`std::stop_token` as its first parameter, supplied automatically by the
`jthread` that constructed it. That parameter is what turns "the destructor
will join" into "the destructor will also ask nicely first," and it is the
subject of the next section.

Given both types exist, the practical rule is short: default to `jthread`.
Reach for `std::thread` only when you have a concrete reason to manage the
stop/join contract by hand — interoperating with an API that expects a bare
`std::thread`, for instance, or building your own thread-pool primitive where
you want the termination behavior to be explicit rather than implicit.

## stop_token and stop_source

Before C++20, cancelling a running thread cooperatively meant inventing the
mechanism yourself: an `std::atomic<bool>` flag, captured by reference, polled
in the worker's loop, set by whoever wants the thread to stop. It works, and
it has worked in C++ codebases for two decades, but every team reinvents its
own flavor — some wrap it in a class, some pass it raw, some forget to make it
atomic and get a loop that never notices the flag changed underneath an
optimizer that cached the read.

`std::stop_source` and `std::stop_token` standardize that pattern. A
`stop_source` is the write side: calling `request_stop()` on it sets shared
state and returns `true` the first time it does so (subsequent calls are
no-ops that return `false`). A `stop_token`, obtained from a `stop_source` via
`get_token()`, is the read side: `stop_requested()` polls the same shared
state, and `stop_possible()` reports whether any `stop_source` capable of
requesting a stop still exists. The two sides share reference-counted state
behind the scenes, so a `stop_token` remains valid and answerable even after
every `stop_source` that could have produced it has gone out of scope — it
simply reports `stop_possible() == false` from then on.

A `jthread` owns a `stop_source` internally and threads a `stop_token` from it
into the callable's first parameter when one is accepted. `request_stop()` on
the `jthread` object forwards to that internal source, and so does the
destructor, automatically, before it joins.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
#include <thread>
#include <stop_token>
#include <chrono>
#include <atomic>

void worker(std::stop_token tok, std::atomic<long>& loops) {
    while (!tok.stop_requested()) {
        loops.fetch_add(1, std::memory_order_relaxed);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

void run_cooperative() {
    std::atomic<long> loops{0};
    std::jthread t(worker, std::ref(loops));   // starts, owns its stop_source
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
}   // ~jthread(): request_stop() then join() -- every return path is safe
```

```cpp
// C++23 -- no new stop_token API; move_only_function widens what a jthread
// can run, which matters once the callable owns non-copyable state
#include <thread>
#include <stop_token>
#include <move_only_function>
#include <memory>

void run_with_owned_state(std::unique_ptr<int> state) {
    std::move_only_function<void(std::stop_token)> task =
        [state = std::move(state)](std::stop_token tok) {
            while (!tok.stop_requested()) {
                *state += 1;
            }
        };
    std::jthread t(std::move(task));   // std::function could not hold this
}   // same destructor contract as C++20: request_stop() then join()
```

```cpp
// C++26 -- std::execution (P2300), targeted for C++26; not yet shipping in
// mainline GCC or clang as of this writing -- proposed/experimental
#include <stop_token>
#include <execution>

void run_in_place(std::inplace_stop_source& src) {
    std::inplace_stop_token tok = src.get_token();
    // inplace_stop_source/inplace_stop_token hold their shared state inline
    // rather than behind jthread's heap-allocated, atomically refcounted
    // stop_state -- the allocation-free alternative a sender/receiver
    // pipeline needs when a stop check sits on a hot path.
}
```

The C++26 column names a real gap. `std::stop_token`'s shared state is
allocated on the heap and managed by atomic reference counts, which is the
right default for a general-purpose type but is exactly the kind of cost a
low-latency pipeline wants to avoid on every request. `std::execution`'s
`inplace_stop_source` trades that generality for a token whose state lives
wherever its owner places it (on the stack, inside another object) at the
cost of a stricter lifetime contract: the source must outlive every token and
callback derived from it, with no refcounting to paper over a mistake.

A `stop_token` is cooperative, and that limitation shows up the first time a
thread is blocked rather than looping. A thread parked inside `read(2)`,
waiting on a condition variable with no timeout, or spinning in a library
call that never checks the token will not stop no matter how many times you
call `request_stop()`. The token only helps a thread that polls it. For a
thread that must be interrupted out of a blocking syscall, a different
mechanism is needed entirely: a self-pipe, a `pidfd`, a timeout on the wait
itself. `stop_token` does not pretend to replace them.

## Thread Lifetime and Ownership

A `std::thread` or `std::jthread` object is the only handle a program has to a
running operating-system thread, and that handle is move-only: copying it
would leave two objects claiming ownership of one thread, which the type
system refuses to allow. Moving transfers ownership cleanly — the source
object becomes non-joinable, the destination becomes responsible for the
thread's eventual `join()` or `detach()`.

The rule that follows from this is unforgiving on `std::thread`: if the
object is destroyed while still joinable, the program calls `std::terminate()`
immediately, with no unwinding, no destructors further up the stack, nothing.
This is not a defect to work around with a `try`/`catch`; `std::terminate()`
is specifically not an exception, so catching around the scope changes
nothing. The only ways to avoid it are to `join()`, to `detach()`, or to move
the thread object somewhere that will do one of those for you — which is
precisely what `std::jthread`'s destructor does automatically.

The ownership question that actually causes outages is not the destructor
rule itself but what the thread touches while it runs. A worker that captures
local variables by reference from the function that spawned it is safe only
as long as that function's stack frame is still alive when the worker reads
them. A `std::jthread` that is itself a local variable enforces this
correctly, because its destructor blocks until the worker has finished before
the frame unwinds further. A thread that has been `detach()`-ed, or one whose
handle has been moved into a longer-lived container while its captures still
point at a short-lived stack frame, enforces nothing: the references dangle
the moment the original frame returns, and the worker reads freed memory with
no indication anything went wrong until it crashes somewhere unrelated.

The safe default is to make captured state outlive the thread by construction
— capture by value, hold shared state in a `shared_ptr`, or keep the thread
object itself scoped tightly enough that its lifetime visibly bounds its
captures' lifetime. Reviewing a thread's captures and reviewing its join
discipline are the same review.

## Joining vs Detaching

`join()` blocks the calling thread until the target has finished, and it is
the only operation other than `detach()` that a joinable thread object can
leave to its destructor without crashing the program. After `join()` returns,
the thread object is no longer joinable, and the operating-system resources
backing it have been reclaimed.

`detach()` severs the connection outright: the thread keeps running
independently, the object immediately becomes non-joinable, and nothing in
the program retains a way to wait for it, cancel it, or learn when it exits.
That independence is also detachment's entire cost. A detached thread that
outlives `main()` is terminated by the runtime without running its
destructors to completion; a detached thread that holds a reference into a
stack frame that returns is a dangling reference with no destructor around to
catch the mistake; a detached thread that throws an unhandled exception calls
`std::terminate()` just as a joined one would, except there is no owning
object left anywhere to have prevented the thread from being abandoned in a
half-finished state in the first place.

There are legitimate uses, such as a genuinely fire-and-forget background
task whose owning process is about to exit regardless, or an old-style API
boundary that only accepts a bare thread id. But in service code, where a
request's
lifetime is supposed to be observable and a shutdown path is supposed to be
clean, `detach()` is close to never the right call. Prefer `join()`, and
prefer `jthread` so that the join happens whether or not the code that wrote
the function remembered to ask for it.

{% include excalidraw.html name="04-jthread-stop-token" caption="Figure 4.1 — jthread's owned stop_source, the stop_token handed to the worker, and the destructor's automatic request_stop-then-join" %}
<!-- DIAGRAM SPEC: bespoke palette cream #fdfbf7 bg, blue #4a73b8, green #5a8870, red #c0392b, orange #a06030. Left: a blue box "std::jthread t" containing a nested orange box "stop_source (owned)". An arrow labeled "get_token()" runs from stop_source to a green box "stop_token" held by a "worker thread" box on the right, which loops on "while (!tok.stop_requested())". Below, a red box "~jthread()" with two ordered arrows into it: "1. request_stop()" into stop_source, "2. join()" waiting on the worker thread box, captioned "both happen even if the caller never calls either by hand". A dashed comparison box to the side: "std::thread, still joinable at destruction" with a red arrow straight to a box "std::terminate() -- no unwind". -->

## Running in a container

`hardware_concurrency()` reads the host's advertised CPU count, and under a
cgroup v2 CPU quota that number does not shrink to match the quota. A
container limited to `cpus: "2"` on a 64-core host still reports
`hardware_concurrency() == 64`, because the function reads `/proc/cpuinfo` and
affinity masks, not `cpu.max`. A thread pool sized naively off that return
value will happily create sixty-four `jthread`s, all of which the scheduler
then time-slices across two CPU-quota's worth of runtime — more context
switching, not more throughput. Size pools from `cpu.max` (or, if you control
the orchestrator, from a fixed, explicitly-injected worker count) rather than
trusting `hardware_concurrency()` inside a quota-limited container.

A `cpuset` constraint behaves differently and more transparently: pinning a
container to specific cores with `cpuset.cpus` changes what
`sched_getaffinity()` reports for every thread in it, and `jthread`s created
after that point inherit the narrowed mask. `hardware_concurrency()` still
does not update, so the gap between "what the mask allows" and "what this
function claims" persists either way — only the mechanism differs.

Clean shutdown is where `jthread` pays for itself under an orchestrator.
Kubernetes and plain `docker stop` both send `SIGTERM` and then, after a
grace period, `SIGKILL`. A process whose signal handler calls
`request_stop()` on every outstanding `jthread` and then returns lets each
worker's `stop_token` loop notice on its next poll and exit cleanly, and lets
`main()`'s `jthread` destructors join them all before the process exits on
its own — well inside the grace period, with no forced kill and no resources
abandoned mid-write.

The runnable version of that shutdown path lives in
`examples/concurrency/04-jthread-shutdown/`.

<!-- EXAMPLE SPEC: a jthread-based worker pool that starts N workers polling a stop_token, receives SIGTERM, calls request_stop() on all of them from the handler, and exits 0 before the orchestrator's SIGKILL grace period elapses; proves the destructor-driven join actually completes under a real termination signal. Docker via lgtm-docker-stack. Verified by a Lua verify.lua asserting the container's exit code is 0 and the shutdown log line appears within the grace period, not after a forced kill. -->

## Standards: C++20 / C++23 / C++26

**C++20** is where this chapter's whole toolkit arrives at once: `std::jthread`
itself, `std::stop_token`, `std::stop_source`, and `std::stop_callback` (a
RAII type that registers a callback to run the moment a stop is requested,
useful for waking a thread parked in something other than a polling loop).
Before C++20, none of this existed in the standard library; cooperative
cancellation meant a hand-rolled flag, and automatic joining meant a hand-rolled
RAII wrapper around `std::thread`.

**C++23** adds no new thread or cancellation primitive. What it contributes
indirectly is `std::move_only_function`, which matters here because it lets a
`jthread` (or any callback-taking API) accept a closure that owns a
non-copyable resource, such as a `unique_ptr` or a file handle wrapper,
without first smuggling it through a `shared_ptr` just to satisfy `std::function`'s
copyability requirement. The cancellation model itself is unchanged; the
ergonomics of what you can hand to it improved.

**C++26** has no shipping change to `jthread` or `stop_token` either, but
`std::execution` (the sender/receiver framework from P2300, voted for C++26)
introduces `std::inplace_stop_source` and `std::inplace_stop_token` as a
deliberately lower-level sibling: the same `request_stop()` /
`stop_requested()` contract, without the heap allocation and atomic
reference counting behind `std::jthread`'s version. As of this writing it is
proposed and experimental: mainline GCC and clang have not shipped a
complete `std::execution` implementation, and the ordinary `stop_token` path
described above remains the one to reach for until that changes.

## What we learned

- `std::thread` starts running at construction, is move-only, and calls
  `std::terminate()` if it is destroyed while still joinable — a design that
  turns a forgotten join into a crash rather than a leak.
- `std::jthread` closes that gap: its destructor requests a stop and joins,
  unconditionally, which is why it should be the default and `std::thread`
  the exception that needs a reason.
- `std::stop_source`/`stop_token` standardize cooperative cancellation as a
  shared, reference-counted flag pair; `request_stop()` only ever takes
  effect once, and `stop_requested()` can be polled safely from any thread.
- Cancellation is cooperative only: a thread blocked in a syscall that never
  checks its token will not stop, and `stop_token` does not claim otherwise.
- A thread's captured references are safe only as long as the frame they
  point into outlives the thread; `jthread`'s blocking destructor is what
  usually makes that true without extra bookkeeping.
- `detach()` gives up every means of waiting for, cancelling, or observing a
  thread's exit, and is close to never the right default in service code.
- `hardware_concurrency()` does not shrink under a cgroup CPU quota; size
  worker pools from the quota or an injected count, not from that return
  value.
