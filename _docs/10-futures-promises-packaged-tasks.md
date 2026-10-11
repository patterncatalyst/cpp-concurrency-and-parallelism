---
title: "Futures, Promises, and Packaged Tasks"
order: 10
layout: tutorial
sectionid: docs
part: tasks-futures-async
description: "std::async and its launch policies, the future/promise pair, packaged_task, shared_future, and how exceptions cross the async boundary."
duration: "13 min"
---

<!-- PROVENANCE: NEW (adapted from linux-systems-programming/_docs/51-std-threading.md) | anchor books: Williams ch4, Grimm -->

## What we'll cover

- Cover `std::async` and its launch policies, including the default policy's surprise: it may run deferred, on no new thread at all, until you call `get()` or `wait()`.
- Introduce the future/promise pair as the general building block `std::async` is implemented on top of.
- Cover `packaged_task` for wrapping a callable with its own future, and `shared_future` for broadcasting one result to multiple waiters.
- Trace how an exception thrown in the producer surfaces at the consumer's `future::get()`, and where that model stops being enough.

## std::async and Launch Policies

`std::async` is the simplest way in the standard library to turn a callable into a result you can collect later instead of a value you block on immediately.

```cpp
std::future<int> f = std::async([] { return compute(); });
// ... do other work ...
int result = f.get(); // blocks here if compute() isn't done yet
```

What runs between those two lines, and on which thread, is governed by a launch policy you can pass as the first argument: `std::launch::async`, `std::launch::deferred`, or their bitwise OR, which is also the default when no policy is given.

`std::launch::async` is unambiguous: the callable starts running immediately, on a new thread of execution, exactly as if you had handed it to `std::thread` and wired up a promise yourself. `std::launch::deferred` is the opposite: nothing runs until some thread calls `get()` or `wait()` on the returned future, at which point the callable executes synchronously, on the calling thread, inside that call. No new thread is ever created for a deferred task.

The default policy — `std::launch::async | std::launch::deferred` — hands the choice to the implementation, and the implementation is permitted to pick either, which means the only guarantee an unqualified `std::async` call gives you is "the result is computed by the time `get()` returns." It is not a guarantee of concurrency. A library that schedules every default-policy call as deferred, because its thread pool is saturated or because its heuristics say so, is conforming. Code that relies on default-policy `std::async` calls actually overlapping — say, three calls meant to run their I/O concurrently — can silently degrade to fully sequential execution on a standard-conforming implementation, with no diagnostic. The fix is to say what you mean: pass `std::launch::async` explicitly whenever concurrent execution is the point, and reserve the default only for call sites that are correct either way.

A related gotcha shows up when code tries to poll a future instead of blocking on it outright. `future::wait_for` and `wait_until` return a `std::future_status` — `ready`, `timeout`, or `deferred` — and that third value is the tell: a `deferred`-policy task reports `std::future_status::deferred` forever, no matter how long you wait, because nothing is running it until `get()` or `wait()` forces it to. Polling code that treats `deferred` the same as `timeout` and retries in a loop spins indefinitely on a task that was never going to make progress on its own; the correct handling is to check for `deferred` once and, if it appears, call `get()` directly rather than continuing to poll.

A second trap sits in the returned future's destructor rather than in the launch policy. A `std::future` obtained from `std::async` with the async policy has special destructor semantics: if it is the last reference to that shared state and the task hasn't finished, its destructor blocks until the task completes. This does not apply to a future obtained from a `std::promise` or `std::packaged_task` directly — only the one `std::async` hands back. The practical consequence is that an unnamed temporary future is a hidden synchronization point:

```cpp
std::async(std::launch::async, [] { slow_io(); }); // temporary destroyed immediately
log("submitted"); // does NOT run until slow_io() finishes
```

The temporary's destructor runs at the end of the full expression, and that destructor blocks on `slow_io()`. The call reads like fire-and-forget; it behaves like a blocking call with the work's name chosen to look otherwise. Binding the result to a named variable with a long enough lifetime doesn't change this — the block still happens, just later, at the variable's own destruction. If concurrent, non-blocking submission is the goal, `std::async` with a destructor-sensitive future is the wrong primitive; a thread pool that owns its own worker threads, covered in [Chapter 15]({{ '/docs/15-thread-pools-and-work-scheduling/' | relative_url }}), doesn't have this property, because none of its futures come from `std::async`.

## future, promise, and packaged_task

`std::async` is convenient but inflexible: it couples "describe the work" and "run the work" into one call. `std::promise` and `std::future` split those two halves apart, which is what lets you hand the producing side to a thread pool, a hardware callback, or any other execution context you don't control through `std::async`'s interface.

A `std::promise<T>` is the producer's handle; calling `.get_future()` on it once yields the matching `std::future<T>`, the consumer's handle onto the same shared state. The producer eventually calls `set_value(v)` (or, on failure, `set_exception(ptr)`), and the consumer's `get()` returns `v` — blocking until it's available if `get()` is called first.

```cpp
std::promise<int> prom;
std::future<int> fut = prom.get_future();

std::thread producer([p = std::move(prom)]() mutable {
    int result = do_work();
    p.set_value(result);
});

int value = fut.get(); // blocks until set_value() runs
producer.join();
```

This is the primitive `std::async` is built on: internally, an `async`-policy call creates a promise/future pair, starts a thread (or schedules the deferred invocation) that eventually calls `set_value`, and hands you the future. Reaching for `promise`/`future` directly makes sense whenever the value's producer isn't a callable you're launching yourself — a completion callback from an async I/O library, a hardware interrupt handler posting its result, or a single result shared across a boundary that doesn't speak `std::thread`.

`std::packaged_task<R(Args...)>` sits between the two: it wraps an existing callable so that invoking the task runs the callable and routes its return value (or exception) into an internal promise automatically, without you writing `set_value` by hand.

```cpp
std::packaged_task<int(int, int)> task(
    [](int a, int b) { return a + b; });
std::future<int> fut = task.get_future();

std::thread worker(std::move(task), 3, 4);
int sum = fut.get(); // 7
worker.join();
```

The task is itself a callable — it has `operator()` — so it can be moved into a `std::thread`, pushed onto a work queue, or stored in a container of type-erased callables (`std::function<void()>`, with the task's own argument binding done ahead of time) the way a thread pool typically stores pending work. That composability — a unit of work that is both "a thing you can call" and "a thing with its own future" — is the reason `packaged_task` is the usual building block for hand-rolled thread pools rather than `std::async`, which gives you no hook to defer submission onto a pool's own queue.

`std::async` also has a resource ceiling that `packaged_task` on a hand-rolled pool doesn't share: each `std::launch::async` call is free, in the implementation's view, to create a new OS thread, and a tight loop issuing thousands of such calls can exhaust the thread limit the platform allows a process, surfacing as `std::system_error` thrown out of `std::async` itself rather than out of the work it was asked to run. A fixed-size pool of worker threads consuming a queue of `packaged_task`s caps the number of OS threads at the pool's size regardless of how many tasks are submitted, which is the second reason — alongside submission flexibility — that production code reaches for a pool once task volume stops being small and bursty.

## shared_future

A plain `std::future<T>` models a single consumer: calling `get()` on it is only valid once, because `get()` moves the result out of the shared state for move-only `T`, and even for copyable `T` the standard restricts a plain future to one `get()` call and invalidates the future afterward. Multiple threads that all need the same result — a cache warm-up result read by several worker threads, a configuration load gating several subsystems — need something that can be waited on by more than one party.

`std::shared_future<T>` is that something. Converting is one call: `std::future<T>::share()` consumes the original future and returns a `shared_future<T>`, which is copyable, so each waiting thread can hold its own copy.

```cpp
std::promise<Config> prom;
std::shared_future<Config> cfg = prom.get_future().share();

auto worker = [cfg] {
    const Config& c = cfg.get(); // returns a const&, callable repeatedly
    use(c);
};

std::thread t1(worker), t2(worker), t3(worker);
prom.set_value(load_config());
t1.join(); t2.join(); t3.join();
```

`shared_future::get()` returns `const T&` rather than moving the value out, which is what makes repeated calls from multiple threads safe — each caller observes the same completed object rather than racing to claim it. The underlying shared state's reference counting and the one-time completion of `set_value` are both handled by the library; the only thing that changes relative to a plain future is cardinality of readers.

## Exceptions Across the Async Boundary

A future's job is not only to deliver a return value but to deliver whatever the producer did instead of returning one. If a callable passed to `std::async`, or run inside a `packaged_task`, throws, the exception is caught by the library and stored in the shared state in place of a value. The consumer's `get()` rethrows it at the call site, on the consumer's thread, the first time `get()` is called.

```cpp
std::future<int> f = std::async(std::launch::async, [] () -> int {
    throw std::runtime_error("producer failed");
});

try {
    f.get(); // throws std::runtime_error here, on the calling thread
} catch (const std::runtime_error& e) {
    log(e.what());
}
```

This is the same mechanism a manual `promise` uses explicitly: `promise::set_exception(std::current_exception())` inside a `catch` block stores the exception the way `set_value` stores a result, and `future::get()` rethrows it. `std::async` and `packaged_task` both do this for you automatically, wrapping the callable's body in a `try`/`catch` you never write.

The guarantee is specific: the exception crosses the thread boundary intact — the same exception object, not a serialized description of it, not a generic "something failed" marker — and it surfaces exactly once, at the first `get()`. A `shared_future` rethrows a copy of the stored exception at each caller's `get()`, so every waiter observes the same failure. If no one ever calls `get()`, the exception is simply never observed; nothing re-raises it elsewhere, and there is no equivalent of an uncaught-exception-on-a-detached-thread crash for a future nobody collected.

This model is sufficient for "one async operation, one eventual result or error" and strained by almost anything more structured than that. There is no way to say "run this, then chain this other async operation onto its result" without blocking the chaining thread on `get()` — a future has no `.then()`, no combinator for "whichever of these two finishes first," and no way to compose N futures into one future-of-all-N without a loop that blocks on each in turn. Exceptions propagate correctly across one hop, but there's no way to express a *pipeline* of hops without that pipeline's every stage blocking a thread on the previous stage's `get()`. That absence of continuation and composition is precisely what the next chapter's subject exists to fix: a C++20 coroutine's `co_await` is a non-blocking continuation attached to a suspension point, built on the same exception-propagation guarantee this chapter establishes, with the blocking removed.

<!-- DIAGRAM SPEC: cream #fdfbf7 background. Two lanes side by side. Left lane "future / promise (this chapter)": a blue #4a73b8 box "producer thread" with an arrow labeled "set_value() / set_exception()" into a shared-state box, then a red #c0392b dashed arrow labeled "get() blocks" from a green #5a8870 "consumer thread" box into the shared-state box, with an annotation "one hop, no continuation — chaining a second async step means blocking here first". Right lane "coroutine co_await (next chapter)": the same shared-state box but the consumer side is an orange #a06030 box "awaiting coroutine" with a "co_await" arrow that returns control to a caller instead of blocking, and a dashed resume arrow coming back in on completion, annotated "non-blocking continuation — the same exception-propagation guarantee, no thread parked". -->
{% include excalidraw.html name="10-future-vs-coroutine" caption="Figure 10.1 — a future's get() blocks the consumer thread on one producer; a coroutine's co_await attaches a continuation without blocking it, over the same exception-propagation guarantee" %}

## Running in a container

None of `std::async`, `std::promise`, or `std::packaged_task` touch anything a container namespaces directly, but the default launch policy's "maybe a thread, maybe not" behavior interacts with container CPU limits in a way worth checking explicitly. Under a cgroup CPU quota (`--cpus=2` in Docker/Podman terms), an implementation's `std::async` heuristics may lean further toward `std::launch::deferred` than they would on an unconstrained host, since spawning more concurrent threads than the quota's effective core count buys no additional throughput and adds scheduling overhead. The worker-pool example below makes this visible rather than assumed: it reports, per task, whether the implementation actually ran it on a separate thread (by comparing `std::this_thread::get_id()` inside the task against the submitting thread's id) and the wall-clock overlap between tasks submitted back to back, run once under `--cpus=4` and once under `--cpus=1`. Explicit `std::launch::async` calls should show overlap in both cases (up to the core count); default-policy calls may not, and the gap between the two is the chapter's launch-policy point made observable.

<!-- EXAMPLE SPEC: examples/concurrency/10-futures-promises-packaged-tasks/ builds a small worker pool around std::packaged_task that accepts N callables and returns their futures, plus a comparison harness that submits the same N tasks via explicit std::launch::async, explicit std::launch::deferred, and the default policy, recording each task's executing thread id and completion timestamp; verified by a Lua verify.lua asserting that std::launch::async tasks run on a thread id distinct from the submitter while std::launch::deferred tasks run on the submitter's own thread id inside the get() call, and that an exception thrown in a packaged_task is observed at the corresponding future::get() call site; built via lgtm-docker-stack with --cpus=4 and --cpus=1 variants for the container section above. -->

## Standards: C++20 / C++23 / C++26

`std::async`, `std::future`, `std::promise`, `std::packaged_task`, and `std::shared_future` are all pre-C++20 facilities — nothing in their interface changes across C++20, C++23, or C++26. What changes around them is the surrounding vocabulary a reader is expected to already know when this chapter's limitations come up.

```cpp
// Unchanged across C++20/23/26: the future/promise family's public interface
// is the same shape it has been since C++11. There is no codetabs delta here
// because there is no cross-standard behavior difference to show.
std::promise<int> p;
std::future<int> f = p.get_future();
```

C++20 adds coroutines as a language feature (next chapter) that supersede futures for composition, without deprecating or changing futures themselves — the two coexist, and a coroutine body can still `co_await` a wrapper around a `std::future` if one is written, though the standard library does not provide that wrapper directly. C++23 adds `std::generator`, a synchronous coroutine type, which has no relationship to `std::async`'s asynchronous model beyond sharing the `co_` keywords. C++26's proposed `std::execution` senders and receivers, covered in the next chapter, are the first standard-library-level attempt at the composition `std::future` lacks — a sender can be chained, combined, and cancelled without any of the parties blocking on `get()` — but as of this writing no shipping compiler implements it, so it remains a forward reference rather than a replacement available today.

## What we learned

- `std::async`'s default launch policy lets the implementation choose `async` or `deferred` per call; relying on concurrent execution without passing `std::launch::async` explicitly is a silent correctness gap, not a guaranteed behavior.
- A future returned by `std::async` with the async policy blocks in its destructor if the task hasn't finished — an unnamed temporary turns what looks like fire-and-forget into a hidden synchronization point.
- `std::promise`/`std::future` is the general producer/consumer primitive `std::async` is built on; reach for it directly when the producer isn't a callable you're launching through `std::async` yourself.
- `std::packaged_task` wraps a callable with its own future and remains callable itself, which is why it — not `std::async` — is the usual unit of work for a hand-rolled thread pool.
- `std::shared_future::get()` returns `const T&` and can be called repeatedly from multiple threads, unlike a plain future's single-use `get()`.
- An exception thrown by the producer is stored in the shared state and rethrown, intact, at the consumer's `get()` — a correct but strictly one-hop model, with no continuation or composition, which is exactly what makes coroutines, next, worth the added machinery.
