---
title: "Coroutines in Depth"
order: 11
layout: tutorial
sectionid: docs
part: tasks-futures-async
description: "C++20 coroutine machinery, promise_type and awaitables, the heap allocation that the compiler may elide, and a look ahead to C++26 senders and receivers."
duration: "16 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/53-coroutines.md + linux-systems-programming/_docs/27-async-runtimes-and-coroutines.md | anchor books: Williams, Grimm, Lim -->

## Learning objectives

By the end of this chapter you can:

- Walk through the compiler-generated coroutine machinery: the frame, `promise_type`, and the `await_ready`/`await_suspend`/`await_resume` triad.
- Apply symmetric transfer so a chain of coroutine resumptions doesn't grow the call stack.
- Check whether HALO eliminates a given coroutine's heap allocation on your own toolchain, instead of assuming it does.
- Use `std::generator` for a lazily produced sequence, and avoid holding a reference past a suspension point it can't survive.
- Compare C++26's proposed senders/receivers model to the hand-rolled `Task` type built earlier in the chapter.

## Why this matters

Chapter 10 ended on a specific limitation: a `std::future` has no continuation and no composition, so chaining one async step onto another means blocking a thread on `get()`. Coroutines close that gap at the language level, and nearly every async library built on top of C++20, Boost.Asio included, exposes that gap-closing through the exact machinery this chapter covers.

Treating `co_await` as a black box works until a coroutine leaks its frame, a reference dangles across a suspension point, or a performance claim about HALO turns out to be wrong on your compiler. Each of those failure modes traces back to one of the mechanisms built here: the frame, the awaitable protocol, and the ownership rules around a `coroutine_handle`.

## What we'll cover

- Walk the compiler-generated coroutine machinery: the frame, `promise_type`, and the `await_ready`/`await_suspend`/`await_resume` triad.
- Cover symmetric transfer and why returning a handle from `await_suspend` avoids unbounded stack growth across chained resumptions.
- Cover HALO (Heap Allocation eLision Optimization) and why the frame allocation it targets is permitted, not guaranteed.
- Cover C++23's `std::generator`, and the lifetime trap where a captured reference doesn't outlive the first suspension point.
- Preview C++26's `std::execution` senders and receivers as the direction standard async composition is heading, labeled experimental.

The previous chapter ended on a specific gap: a `std::future` has no continuation and no composition, so chaining one async step onto another means blocking a thread on `get()` first. A C++20 coroutine closes that gap at the language level. `co_await` suspends a function without blocking the caller, returns control to it, and resumes the function later from exactly where it left off: the same exception-propagation guarantee as a future, with the blocking removed. This chapter covers the machinery that makes that possible: what the compiler builds when it sees `co_await`, `co_yield`, or `co_return`, what that machinery costs, and where it traps the unwary.

## Coroutine Machinery: promise_type and Awaitables

Any function containing `co_await`, `co_yield`, or `co_return` is a coroutine, transformed by the compiler into a state machine behind the scenes. Nothing about the call site changes (a coroutine is called like any other function), but the body is rewritten so it can suspend and resume from that point later, with its locals intact. The storage holding those locals, the current suspension point, and a little bookkeeping is the **coroutine frame**, almost always heap-allocated (the exception is covered below) and never a type you write or take `sizeof` of directly.

What you do write is a `promise_type`: a nested type the compiler looks up via `std::coroutine_traits` on the coroutine's return type. It is the customization point for everything about the coroutine's behavior: what happens before the body runs, what happens after it finishes, and what `co_return`/`co_yield` do with their operands.

```cpp
struct Task {
    struct promise_type {
        Task get_return_object() {
            return Task{std::coroutine_handle<promise_type>::from_promise(*this)};
        }
        std::suspend_always initial_suspend() noexcept { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        void return_void() {}
        void unhandled_exception() { std::terminate(); }
    };
    std::coroutine_handle<promise_type> handle;
};
```

`get_return_object()` builds the value the caller actually receives from calling the coroutine: here, a `Task` wrapping a `std::coroutine_handle`, the non-owning pointer-with-a-nicer-name that refers to the frame. `initial_suspend()` decides whether the body starts immediately or waits, suspended, for an explicit first resume; `final_suspend()` decides the same question at the other end, once the body has run to completion. `return_void()` (or `return_value(T)`, for a coroutine that produces a result) handles `co_return`; `unhandled_exception()` runs, from inside a `catch` block the compiler generates around the whole body, if the coroutine throws and never catches it internally.

Every `co_await expr` is a protocol, not a single operation. `expr` is converted to an **awaitable**, directly if it already has the three required member functions, or via an `operator co_await` found by argument-dependent lookup or on the promise type otherwise, and the compiler emits, in order: `await_ready()`, which returns `bool` and skips suspension entirely when the result is already available; if that returns `false`, `await_suspend(handle)`, where `handle` refers to the suspending coroutine itself, giving the awaitable a way to arrange for that exact coroutine to resume later; and finally, once resumed, `await_resume()`, whose return value becomes the value of the whole `co_await` expression.

```cpp
struct ReadAwaitable {
    Reactor& reactor;
    int fd;
    bool await_ready() noexcept { return false; }
    void await_suspend(std::coroutine_handle<> h) {
        reactor.wait_readable(fd, h); // parks h; reactor resumes it on readiness
    }
    void await_resume() noexcept {}
};
```

This is the entire bridge between a coroutine and an external event source: `await_suspend` hands the reactor a handle to call `.resume()` on whenever it decides the coroutine should continue, and nothing about the caller is blocked while that wait is pending. `std::suspend_always` and `std::suspend_never`, used above for `initial_suspend`/`final_suspend`, are the two trivial awaitables the standard provides, for "always suspend here" and "never suspend here."

## Symmetric Transfer

`await_suspend` has a second return-type overload beyond `void`: it may return a `std::coroutine_handle<>`, resumed immediately in place rather than returning control to whatever called the suspending coroutine. This is **symmetric transfer**, and it solves a problem easy to miss until it causes a crash.

A naive implementation of "coroutine A finishes, so resume whichever coroutine was awaiting A" calls `.resume()` on the awaiter directly from inside `await_suspend`. That call does not return until the awaiter itself suspends or finishes, and if the awaiter's own completion resumes a third coroutine the same way, the call stack grows by one frame per link. A long enough chain of coroutines awaiting each other's results, exactly the shape a coroutine-based pipeline produces, overflows the stack despite every individual function having long since "returned" in the coroutine sense.

```cpp
struct FinalAwaiter {
    bool await_ready() noexcept { return false; }
    std::coroutine_handle<> await_suspend(
            std::coroutine_handle<promise_type> h) noexcept {
        auto continuation = h.promise().continuation;
        return continuation ? continuation : std::noop_coroutine();
    }
    void await_resume() noexcept {}
};
```

Returning the handle instead of calling `.resume()` directly tells the compiler to perform the transfer as a tail call, a jump rather than a nested call: no stack frame accumulates no matter how many coroutines are chained. `std::noop_coroutine()` is the handle to use when there's nothing to resume: a special handle whose `.resume()` does nothing, used here so a top-level task with no awaiter can still return a handle from `final_suspend` without a null check. The pattern (stash the awaiter's handle during `co_await`, return it during `final_suspend`) is the standard way to build a `Task<T>` type with chained, unbounded composition and no recursion cost, the composability a bare `std::future` could not offer.

## HALO: The Allocation That May Not Happen

A coroutine frame is allocated by a call the compiler inserts, equivalent to `operator new`, sized to hold the promise, the resume/destroy function pointers, a state index recording where to resume, and whichever local variables are live across a suspension point. A variable used only before the first `co_await`, or only between two of them, need not be stored in the frame at all, since the compiler's liveness analysis already knows it. Frame size is therefore a function of what a coroutine *carries* across suspension, not a flat overhead: one that suspends immediately and holds nothing can have a frame of tens of bytes, just the fixed bookkeeping, while one holding a large buffer across every suspension pays for that buffer on every frame.

The standard permits an implementation to skip the heap allocation entirely when it can prove, at the call site, that the frame cannot outlive its caller: this is HALO, Heap Allocation eLision Optimization, the usual answer to "isn't a heap allocation per call expensive?" The wording in `[dcl.fct.def.coroutine]` is *may*, not *shall*: a license granted to the optimizer, contingent on proving the frame's lifetime is bounded by the call, exercised at the optimizer's discretion rather than guaranteed by the language.

That gap between "permitted" and "happens" is not hypothetical. Across mainstream C++20/23 toolchains, the easiest possible case for elision (a coroutine that runs to completion inside the call that created it, `std::suspend_never` at both ends so nothing escapes) has been observed to elide fully under one compiler at moderate optimization levels and not at all under another at the same level, on the same source. Treat that as the expected shape of the result, not a number to rely on: whichever toolchain you ship on is the only one that matters, and the only way to know what it does is to measure it: overload `operator new` inside `promise_type` and count calls. "The optimizer will remove it" is a claim about a toolchain, not the language; treating it as a guarantee compiles cleanly, passes every test, and is wrong only in its performance model.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, two horizontal bands. Upper band "what the standard permits": a box quoting [dcl.fct.def.coroutine] "the implementation MAY elide the coroutine-frame allocation when it can prove the frame does not outlive the caller" in blue #4a73b8, with an annotation "may: no conforming program may assume elision occurs". Lower band "what a toolchain actually does, same source and same -O level": two side-by-side boxes, one green #5a8870 labeled "compiler A: allocates on the heap every call" and one orange #a06030 labeled "compiler B: elides every call", joined by a horizontal bracket labeled "identical standard, identical optimization flag, different answer". A closing red #c0392b box across the bottom reads "measure your own toolchain: overload operator new in promise_type and count". -->
{% include excalidraw.html name="11-halo-permission-not-guarantee" caption="Figure 11.1: HALO is a permission, not a guarantee. Identical source at an identical optimization level can allocate on one toolchain and elide entirely on another, both conforming" %}

## C++23's std::generator

A **generator** is a coroutine that produces a sequence of values lazily, one `co_yield` at a time, instead of building a container up front. Before C++23, writing one meant hand-rolling a `promise_type` with `yield_value`, a handle wrapper satisfying the range-for protocol, and an iterator: boilerplate every project needing one had to write again. C++23 standardizes the result as `std::generator<T>`.

```cpp
std::generator<std::uint64_t> fibonacci() {
    std::uint64_t a = 0, b = 1;
    while (true) {
        co_yield a;
        const std::uint64_t next = a + b;
        a = b;
        b = next;
    }
}

for (auto value : fibonacci() | std::views::take(10)) {
    use(value);
}
```

Two things about that function matter beyond the brevity. It is an infinite loop with no termination condition, consumed finitely by `std::views::take` (or an explicit `break`), and that is not a leak. Breaking out destroys the generator object, which destroys the coroutine frame, which destroys a coroutine suspended mid-`co_yield`; destroying a suspended coroutine is well-defined, runs the destructors of any locals in scope at the suspension point, and frees the frame. The per-call state (`a` and `b` above) is in the function body as ordinary locals, not hoisted into a hand-written class's members the way a manual generator requires; that is the ergonomic argument for `std::generator`, independent of any performance claim.

## The Lifetime Trap

`std::coroutine_handle` is, by design, a non-owning primitive: a pointer to the frame with a richer interface, not a smart pointer. Copying a handle copies the pointer; destroying a handle variable does nothing to the frame. Only an explicit `.destroy()` call frees it, or an actual resume-to-completion via `final_suspend` with `std::suspend_never`. A coroutine object that stores a raw handle and never calls `.destroy()` leaks the frame with no diagnostic from any tool: no compiler warning, no sanitizer trip in an ordinary run, because nothing in the type system distinguishes an owned handle from an abandoned one.

```cpp
struct OwningTask {
    std::coroutine_handle<promise_type> handle;

    ~OwningTask() {
        if (handle) {
            handle.destroy(); // the only thing that frees the frame
        }
    }

    OwningTask(const OwningTask&) = delete;             // one owner per frame
    OwningTask& operator=(const OwningTask&) = delete;
};
```

The fix is the standard one for any non-owning handle in C++: wrap it in a type whose destructor calls `.destroy()`, and delete that type's copy operations so a copy can't produce two owners racing to free one frame. This is why essentially every coroutine tutorial hands you a wrapper type before it hands you a coroutine body: the wrapper is the only thing standing between the code and a leak the compiler will never flag.

A sharper version of the same discipline shows up around references rather than the handle itself. A coroutine parameter passed by reference is as perilous across a suspension point as any reference held past the scope that produced it: if the referred-to object's lifetime ends before the coroutine resumes (a local in the caller's stack frame, destroyed once the caller moves on past the point where it suspended the coroutine), the coroutine resumes holding a dangling reference, and nothing about `co_await` warns you.

```cpp
Task use_dangling_ref(const std::string& name) { // reference parameter
    co_await something();     // suspends; caller may now return
    log(name);                // UB if the caller's `name` has been destroyed
}

void caller() {
    std::string local = "transient";
    auto t = use_dangling_ref(local); // fine so far, local still alive
} // local destroyed here, possibly before the coroutine resumes and reads it
```

A plain function parameter by reference is safe precisely because the function runs to completion, synchronously, before the caller can destroy its locals: that invariant is what makes reference parameters safe everywhere else in C++, and a coroutine is the one place a function body can outlive the call that started it. The rule that generalizes: anything needed after the first suspension point must be owned by the frame (a by-value parameter, or a copied/moved local), not borrowed from a caller whose lifetime the coroutine has no visibility into.

## C++26 std::execution: Senders and Receivers

Everything above is machinery for one coroutine at a time. None of it answers the composition question the previous chapter raised: how do you build a *pipeline* of async steps, cancel one mid-flight, or run several concurrently and combine their results, generically rather than one hand-rolled `Task` type at a time?

C++26's `std::execution` (the senders/receivers model from P2300) is the standard library's proposed answer. A **sender** describes an asynchronous unit of work without yet running it, and senders compose with algorithms like `then`, `when_all`, and `let_value` the way range adaptors compose over `std::ranges`: build up a description of a pipeline, then hand it to a **scheduler**, the model's abstraction over where the work actually runs (a thread pool, an I/O reactor, the calling thread). A **receiver** is the completion handler a sender eventually calls (with a value, an error, or a cancellation signal), which is where exception and cancellation propagation finally gets a vocabulary that spans an arbitrarily long pipeline instead of one `get()` call.

```cpp
// C++26 (proposed; shape per P2300, not implemented by any shipping compiler
// at time of writing):
namespace ex = std::execution;

ex::sender auto work =
    ex::schedule(my_scheduler)
    | ex::then([] { return load_data(); })
    | ex::then([](Data d) { return process(d); });

auto [result] = ex::sync_wait(std::move(work)).value();
```

<span class="status status--unverified">experimental: `std::execution` is part of the C++26 working draft via P2300, but no mainstream shipping compiler ships a conforming implementation as of this writing; the shape above reflects the proposal's interface and may still change. Do not take the snippet as something you can compile today.</span>

The relationship to this chapter's machinery is additive, not a replacement: a coroutine can be made `co_await`-able against a sender via the standard's awaitable connection points, so a hand-rolled `Task` type and a senders-based pipeline are expected to interoperate rather than compete for the same niche. Coroutines give an imperative, straight-line way to write a suspending function; senders give a declarative, composable description of a pipeline that a scheduler is free to reorder, parallelize, or run inline, closer in spirit to range adaptors than to `co_await`. Which of the two a given piece of code should use is a question the ecosystem has not finished answering, precisely because the standard vocabulary for the second does not yet exist in a compiler you can install.

## Running in a container

Coroutine frame size and HALO behavior are properties of the compiler and optimization level, not of anything a container namespaces, so a Containerfile's job here is pinning the toolchain precisely enough that a measurement taken inside the container matches one quoted in a report built from it: two images built `FROM` different base-image minor versions can legitimately disagree on whether a frame is elided, for the same reason two host compilers can. The practical pattern is a multi-stage build compiling the frame-size and HALO examples at `-O0` through `-O3` as separate stages, each copying its measurement output to a fixed path, so one container run prints the full optimization-level matrix without a host rebuild at every level.

<!-- EXAMPLE SPEC: examples/concurrency/11-coroutines-in-depth/ instruments a promise_type's operator new to report coroutine frame size for a trivial coroutine and one carrying a large buffer across a suspension, builds a std::generator-based Fibonacci sequence consumed finitely via std::views::take, and reproduces the coroutine_handle lifetime trap (an abandoned handle vs. one owned by a destructor-based wrapper); verified by a Lua verify.lua asserting the trivial frame is smaller than the large-buffer frame by at least the size of the buffer, that the generator produces the correct Nth Fibonacci term, and that the owned-handle case frees its frame (observed via operator delete) while the abandoned case does not; built via lgtm-docker-stack with a multi-stage Containerfile compiling the HALO case at -O0 through -O3 to make elision-or-not observable per optimization level, matching the container section above. -->

## Standards: C++20 / C++23 / C++26

{% include codetabs.html langs="C++20|C++23|C++26" %}
```cpp
// C++20: the coroutine language feature itself — co_await, co_yield,
// co_return, promise_type, the awaitable protocol, and std::coroutine_handle
// — ships with no standard-library coroutine TYPE at all. std::suspend_always
// and std::suspend_never are the only ready-made awaitables; a generator,
// a task type, or anything else usable from a coroutine body must be
// hand-written, as earlier in this chapter.
struct Task { struct promise_type { /* hand-written, as above */ }; };
```
```cpp
// C++23: std::generator<T> ships in <generator>, standardizing the most
// common hand-rolled coroutine type from C++20 code. No change to the core
// coroutine language machinery from C++20 -- promise_type, the awaitable
// protocol, and coroutine_handle are identical. This is a library addition,
// not a language one.
#include <generator>
std::generator<int> count_to(int n) {
    for (int i = 0; i < n; ++i) co_yield i;
}
```
```cpp
// C++26 (proposed, P2300, no shipping compiler support at time of writing):
// std::execution adds senders/receivers as a standard composition model
// layered ON TOP of the unchanged C++20 coroutine machinery -- a coroutine
// can be made co_await-able against a sender, rather than senders replacing
// promise_type or coroutine_handle. Labeled experimental throughout this
// chapter; treat as a preview, not a feature you can rely on in shipping code.
namespace ex = std::execution;
auto work = ex::schedule(sched) | ex::then(load) | ex::then(process);
```

`std::coroutine_handle`, the awaitable protocol, and `promise_type`'s customization points are unchanged from C++20 through the current C++26 working draft; every delta above is additive (a new library type, a proposed composition layer), never a change to the core language machinery.

## What we learned

- A coroutine is a function containing `co_await`, `co_yield`, or `co_return`, transformed into a state machine whose locals live in a heap-allocated frame and whose behavior is customized through a `promise_type`.
- `co_await` is a three-call protocol (`await_ready`, `await_suspend`, `await_resume`), and an `await_suspend` that returns a handle performs symmetric transfer, a tail call keeping a long chain of resumptions from growing the stack.
- HALO permits eliding the frame's heap allocation when the compiler can prove it doesn't outlive its caller, but the wording is *may*; whether your toolchain takes the opportunity is discoverable only by measuring it, never guaranteed by the language.
- `std::coroutine_handle` owns nothing: a type with a destructor calling `.destroy()` is the only thing standing between a coroutine and a frame leak with no diagnostic.
- A coroutine that uses a captured or parameter reference after a suspension point risks dangling if the referent's owner moves on first; anything needed post-suspension belongs in the frame by value.
- C++23's `std::generator` standardizes the hand-rolled synchronous-generator pattern; destroying one mid-suspension is well-defined, not a leak.
- C++26's proposed `std::execution` senders and receivers answer composition (chaining, combining, cancelling async work without a blocking `get()` at every step), layered on top of this chapter's machinery, not replacing it; no shipping compiler implements it yet.

Next, [Chapter 12]({{ '/docs/12-async-runtimes-and-event-loops/' | relative_url }}) puts this chapter's `ReadAwaitable` pattern on a real event loop: the `epoll_wait` that resumes a parked handle on socket readiness, and how that single-threaded reactor compares to a multi-threaded `io_context`.
