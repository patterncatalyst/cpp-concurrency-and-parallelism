---
title: "Fibers and Stackful Coroutines"
order: 13
layout: tutorial
sectionid: docs
part: tasks-futures-async
description: "Stackful fibers versus stackless coroutines, what the fiber's own stack buys and costs, the guard page, and choosing a scheduler."
duration: "15 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/54-boost-fiber.md | anchor books: Grimm, Son -->

## What we'll cover

- Contrast stackful fibers, each with their own real stack and cooperative scheduling, against [Chapter 11]({{ '/docs/11-coroutines-in-depth/' | relative_url }})'s stackless coroutines, whose state lives in a compiler-sized heap frame.
- Quantify what a fiber's dedicated stack buys in programming-model freedom, and what it costs in memory, relative to a thread's stack and a coroutine's frame.
- Cover the guard page that turns a fiber stack overflow into an immediate fault instead of silent corruption of whatever memory sits next to it.
- Lay out the scheduler choices Boost.Fiber exposes, and when the single-threaded default is the wrong one to keep.

A `co_await` only ever suspends the coroutine that contains it. That sounds like a narrow restriction until a function five call frames below the coroutine body needs to suspend on its own — a blocking read hidden three layers inside a library you don't control, say — and discovers it cannot, because `co_await` is valid only inside a coroutine, and nothing automatically makes its caller one too. The usual name for the problem is **function coloring**: a suspending function infects every function that calls it, all the way up, and a single non-coroutine link anywhere in that chain breaks the whole thing. A **fiber** sidesteps the problem by never needing the compiler's cooperation in the first place. It has its own stack, and suspending it is a stack switch, not a language construct — which means it can suspend from anywhere an ordinary function can be called, at a cost this chapter measures honestly rather than waves away.

## Stackful vs Stackless

Chapter 11 built the stackless model: `co_await`, `co_yield`, and `co_return` are compiler-recognized tokens that transform a function into a state machine, with its locals stored in a heap-allocated frame rather than on the call stack. That design is why a coroutine frame can be small — it holds only what's actually live across a suspension point, not an entire reserved stack — and it's also why suspension is lexically scoped to coroutine bodies: the compiler has to see `co_await` to generate the state-machine transform around it, so only a function the compiler recognizes as a coroutine can ever suspend.

A fiber is the opposite trade along the same axis. `boost::fiber`, built on `boost::context`, gives each fiber a genuine stack — a contiguous region of memory with its own stack pointer — and a context switch between fibers is a handful of registers saved to one stack and restored from another, entirely in user space, with no kernel involvement and nothing analogous to a `promise_type` anywhere in sight. Because the stack is real, a fiber can suspend from inside a function the compiler has never heard of:

```cpp
void leaf() {
    boost::this_fiber::yield();   // suspend from an ORDINARY function
}

void middle(int depth) {
    if (depth == 0) leaf();
    else middle(depth - 1);       // five ordinary stack frames deep
}

// called from the fiber's own entry function:
middle(5);
```

Neither `leaf` nor `middle` is a coroutine in any sense the compiler recognizes. Neither contains `co_await`. `boost::this_fiber::yield()` works anyway, because yielding a fiber doesn't ask the compiler for anything — it asks `boost::context` to save the current stack pointer and registers and switch to a different stack, a mechanism that has no idea, and no need to know, what function it happened to be standing in when it was called. That is the entire difference stated as plainly as it gets: a stackless coroutine can suspend only where the compiler built it a state machine to suspend from; a stackful fiber can suspend anywhere a function call is legal, because suspension never touched the compiler at all.

## What the Stack Actually Buys

The number worth anchoring this to is rough but directionally solid across common Linux toolchains: a default thread stack on the order of several megabytes, a default fiber stack on the order of a hundred-odd kilobytes, and a stackless coroutine frame running from tens of bytes up to however much state it carries live across a suspension point — three orders of magnitude apart at each step, fiber sitting squarely between the other two. Boost reports the fiber number directly through `boost::context::stack_traits::default_size()`, and it's worth treating as a property of your toolchain to check rather than a constant to memorize, the same caution Chapter 11 raised about HALO: exact figures move with the platform, and the ordering — thread stack larger than fiber stack larger than coroutine frame, by roughly the same order of magnitude at each step — is the claim to carry forward, not any one number from any one run.

That ordering follows from what each one has to store. A thread's stack is sized to survive the deepest call chain the kernel might schedule it mid-execution, plus room the kernel reserves; a fiber's stack is sized the same way but owned by your program, shrinkable if the call depth is bounded; a coroutine frame stores only what's live across a suspension, because the compiler's own liveness analysis already knows what that is. Cost and capability move together: the more a paused computation remembers about *where* it paused — a full call stack versus a handful of named locals — the more memory that costs.

The corollary is the actual answer to "when does stackful still win." A fiber earns its stack specifically where the call chain between the suspension point and the fiber's entry is deep, or where part of that chain is foreign code you cannot rewrite as a sequence of coroutines — a vendor library exposing only a blocking callback interface, a recursive parser with no natural `co_await` points, a C API with no notion of suspension at all. Wrapping that kind of code in a stackless coroutine means either rewriting it (often impossible, if it's a dependency) or running it on a separate OS thread and bridging the result back with a future, which reintroduces the exact per-call thread cost coroutines exist to avoid. A fiber runs it unmodified, suspends it from wherever it happens to be, and resumes it later with the stack intact — a capability no stackless design can express, at a price measured in a stack, not a workaround.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, three horizontal bars of decreasing width stacked top to bottom, log-scale implied. Top bar, widest, blue #4a73b8, labeled "thread stack -- several MiB, kernel-scheduled, a task_struct and a tid in /proc". Middle bar, orange #a06030, labeled "fiber stack -- roughly 100 KiB, user-scheduled, invisible to the kernel, suspends from ANY ordinary function". Bottom bar, narrowest, green #5a8870, labeled "coroutine frame -- tens of bytes up, user-scheduled, suspends ONLY at co_await inside a coroutine body". Two amber down-arrows between the bars labeled "many fibers fit in one thread's stack" and "many frames fit in one fiber's stack". A red #c0392b footer box: "cost and capability move together, in opposite directions." -->
{% include excalidraw.html name="13-three-ways-to-pause" caption="Figure 13.1 — three ways to hold a paused computation: a thread's kernel-visible stack, a fiber's user-space stack, and a coroutine's heap frame, in decreasing cost and increasing restriction on where they may suspend" %}

## The Guard Page

Giving a fiber a real stack reintroduces a hazard stackless coroutines never have: running off the end of it. Boost ships more than one stack allocator, and the practically important difference between the two most common ones is exactly one page. `fixedsize_stack` allocates precisely the number of bytes requested and nothing more. `protected_fixedsize_stack` allocates one additional page beyond that and maps it `PROT_NONE` — readable and writable by nobody, including the fiber whose stack it guards.

```cpp
boost::context::protected_fixedsize_stack alloc(65536);
// total mapping: 65536 bytes of usable stack + one PROT_NONE guard page
```

A fiber that stays inside its allotted 64 KiB never touches the guard page and never notices it exists. A fiber that recurses past the end of that stack — a runaway recursive call, a buffer indexed past its bound, an oversized local — walks straight into the `PROT_NONE` mapping on its very next write, and the MMU faults immediately: `SIGSEGV`, delivered at the exact point of the overrun, with a process that terminates rather than continues silently corrupting whatever page happened to be mapped next. Without the guard page, that same overrun writes through into adjacent memory — possibly another fiber's stack, possibly heap state — and the resulting corruption can surface far from its cause, in a completely unrelated part of the program, long after the write that caused it.

The guard buys determinism about *when* a stack overflow is caught, not protection against every way a stack can be mis-sized. It is exactly one page. A single stack frame larger than that page — an oversized local array, say — can step clean over the guard into whatever is mapped beyond it, and neither Boost nor the MMU notices anything wrong, because no individual access ever lands inside the guarded range. The guard page catches the common case, a recursion or loop that overflows one page at a time; it is not a bound on frame size, and code with unusually large stack frames needs a stack sized generously enough that this limitation never matters in practice.

## Choosing a Scheduler

A fiber only ever runs because something decided to run it, and Boost.Fiber makes that something a pluggable, per-thread **scheduler** rather than a fixed runtime policy. The default, `algo::round_robin`, keeps one queue per participating thread: a fiber created on a given thread stays on that thread for its entire life, moved onto the CPU in turn whenever it's that fiber's position in the queue and the currently running fiber yields. Sixteen fibers under `round_robin` on one thread occupy exactly one core, taking turns — concurrent, never parallel, by construction.

```cpp
boost::fibers::use_scheduling_algorithm<boost::fibers::algo::shared_work>();
```

One line, called on each participating thread, changes the arrangement entirely: `algo::shared_work` keeps a single queue that every opted-in thread pulls from, so a fiber can resume on a different thread than the one it suspended on. The same sixteen fibers, run under `shared_work` across four threads, spread themselves across all four — concurrent and parallel now, at a cost `round_robin` never asked you to pay. Under the default, a fiber's data is touched by exactly one thread for its entire lifetime, which removes an entire category of synchronization from code written against it: nothing it touches between two yield points needs a lock, because nothing else can be running on that thread in between. `shared_work` gives that property up the moment a fiber can migrate — the same mutex that was free to leave unlocked under `round_robin` now needs to actually be there, because a second thread genuinely can touch the data concurrently.

A subtler trap follows directly from migration: thread-local storage is *thread*-local, not fiber-local. A fiber that reads a `thread_local` before yielding and reads it again after resuming can be reading two different threads' copies under `shared_work`, silently, with no diagnostic — exactly the kind of bug that reproduces under `shared_work` and vanishes under `round_robin`, making it miserable to track down if the two ever get swapped during a refactor. Boost provides `boost::fibers::fiber_specific_ptr` for state that genuinely needs to travel with the fiber rather than the thread, and reaching for plain `thread_local` inside code that might run under a migrating scheduler is a latent defect, not a style choice.

Neither scheduler is generically correct. `round_robin` is the right default because it buys back a synchronization-free programming model for fibers that don't need to spread across cores; `shared_work` (and Boost's work-stealing scheduler beyond it) is right once more fibers carry real CPU-bound work than one core can absorb. Exposing the choice as one line per thread, rather than deciding it for you, is the point: Boost.Fiber leaves the concurrent-versus-parallel decision in your hands.

## Running in a container

A fiber's stack is ordinary heap-backed memory from the kernel's point of view — `mmap`-allocated, counted against the process's resident set once touched — so a memory-constrained container (`memory.max` on cgroup v2, or a Kubernetes pod's memory limit) sees a pool of fibers as a cost proportional to how many are live at once times their stack size, the same arithmetic as a thread pool but at roughly a hundred-odd kilobytes per unit instead of several megabytes. A worker pool rewritten from threads to fibers inside an identical memory limit can typically sustain far more concurrent units of work before approaching the limit, which is the direct, container-visible version of the three-way comparison in Figure 13.1. `protected_fixedsize_stack`'s guard page costs virtual address space, not resident memory — a `PROT_NONE` mapping is never backed by a physical page — so it doesn't move the needle on a memory limit, but it does consume address space, worth checking against a container's `ulimit -v` if one has been set unusually tight alongside the memory cgroup.

What a container's constraints do *not* change is the cooperative-scheduling contract underneath all of this. A fiber that calls a genuinely blocking syscall — a `read()` on a file descriptor with no nonblocking flag set, say — blocks the OS thread it's running on, and every other fiber queued on that thread stalls with it, CPU quota or no CPU quota; nothing about fibers makes a blocking call non-blocking. A worker pool built from fibers still needs every I/O path inside it to be genuinely nonblocking (or to live on a dedicated thread, outside the fiber scheduler, reached only through a handoff) for the model to deliver what it promises — fibers buy a cheaper, more flexible unit of suspension, not a free pass around the kernel's actual blocking calls.

The runnable version of this chapter's memory comparison lives at `examples/concurrency/13-fiber-worker-pool/`.

<!-- EXAMPLE SPEC: builds an identical worker pool two ways -- N OS threads and N boost::fibers under round_robin -- doing the same fixed amount of cooperative work, reports RSS and stack-region count for both, and separately demonstrates protected_fixedsize_stack catching a deliberate stack overflow (exit via SIGSEGV on the guard page) versus fixedsize_stack silently continuing. Docker via lgtm-docker-stack, run once unconstrained and once with --memory capping RSS to show the fiber pool sustaining a higher worker count under the identical limit. Verified by a Lua verify.lua asserting the fiber pool's RSS-per-worker is at least an order of magnitude below the thread pool's, and that the protected-stack overflow case exits on a signal (>=128) while completing within a bounded timeout. -->

## Standards: C++20 / C++23 / C++26

Boost.Fiber is not, and as of the current working draft is not becoming, part of the C++ standard — there is no `std::fiber`, no standardized stackful-coroutine type, in C++20, C++23, or the C++26 draft. The genuine cross-standard difference is not in fibers themselves but in how the standard expects you to bridge a blocking, non-awaitable call into coroutine code without one, since that workaround is the closest standard C++ gets to what a fiber buys directly.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20 -- no stackful-coroutine facility in the standard. Bridging a
// blocking, non-awaitable call into coroutine code means running it on a
// dedicated thread and resuming the coroutine from there -- paying a whole
// OS thread for the duration, which is precisely what a fiber avoids.
Task<int> call_legacy_blocking() {
    std::promise<int> result;
    std::jthread worker([&] { result.set_value(legacy_blocking_call()); });
    co_return co_await resume_when_ready(result.get_future());
}
```

```cpp
// C++23 -- std::generator standardizes a STACKLESS synchronous coroutine
// type (Chapter 11), which does not help here: a generator still suspends
// only at co_yield inside a coroutine body, so legacy_blocking_call() is
// exactly as un-awaitable as it was in C++20.
std::generator<int> values_from(std::span<const int> xs) {
    for (int x : xs) co_yield x;   // no help for blocking, non-coroutine calls
}
```

```cpp
// C++26 (proposed, std::execution / P2300 -- no shipping compiler support)
// A scheduler can represent "run this on a dedicated blocking-call pool" as
// a first-class value, formalizing the C++20 workaround above rather than
// giving C++ a standard stackful-coroutine type.
auto work = std::execution::on(blocking_pool_scheduler,
                                std::execution::just_from([] {
                                    return legacy_blocking_call();
                                }));
int v = std::execution::sync_wait(std::move(work)).value();
```

Across all three columns, a fiber remains a third-party facility (Boost.Fiber, or a platform primitive like `ucontext.h` underneath it) rather than something the standard provides. What changes standard to standard is only how awkward the *workaround* for not having one is to write — a hand-rolled thread-and-promise bridge in C++20 and C++23, a named scheduler concept to express the same bridge in C++26's proposed model — never whether the standard gives you the thing Boost.Fiber gives you directly.

## What we learned

- Stackless coroutines (Chapter 11) can suspend only inside a function the compiler recognizes as a coroutine; a fiber, with its own real stack, can suspend from an ordinary function several frames deep, because switching it is a stack-pointer swap, not a language-level transform.
- Cost and capability move together: a thread's stack, a fiber's stack, and a coroutine's frame sit roughly an order of magnitude apart at each step, and the ordering reflects what each one has to remember about where it paused.
- A fiber's stack is what makes it the right tool for deep call chains and for foreign, non-rewritable blocking code that a stackless coroutine cannot wrap without moving it to its own thread.
- `protected_fixedsize_stack` costs one extra `PROT_NONE` page over `fixedsize_stack` and turns a stack overflow into an immediate, diagnosable `SIGSEGV` instead of silent corruption of adjacent memory — though a single frame larger than one page can still step over it.
- Boost.Fiber's scheduler is a per-thread, pluggable choice: `round_robin` never migrates a fiber off the thread that created it, buying a lock-free programming model between yields; `shared_work` spreads fibers across threads for real parallelism, at the cost of making that same data genuinely shared and making `thread_local` a latent migration bug.
- No C++ standard through the C++26 working draft provides a stackful-coroutine type; only the vocabulary for bridging blocking code into async code without one changes from standard to standard.

Next, [Parallel Algorithms and Execution Policies]({{ '/docs/14-parallel-algorithms-and-execution-policies/' | relative_url }}) leaves the suspension-and-scheduling question behind entirely and turns to the other half of this book's subject: converting available cores into finished work on data that doesn't need to suspend at all.
