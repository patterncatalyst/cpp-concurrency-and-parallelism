---
title: "Async Runtimes and Event Loops"
order: 12
layout: tutorial
sectionid: docs
part: tasks-futures-async
description: "The epoll event loop underneath async I/O, Boost.Asio's strand and work-guard, and the question of which thread actually runs a given handler."
duration: "16 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/27-async-runtimes-and-coroutines.md + linux-systems-programming/_docs/55-boost-asio.md | anchor books: Williams, Lim -->

## Learning objectives

By the end of this chapter you can:

- Wire a coroutine's `await_suspend` to a real `epoll` reactor and trace a full suspend/resume cycle through `epoll_ctl`/`epoll_wait`.
- Explain why a freshly constructed `io_context` returns immediately from `run()`, and use `executor_work_guard` to keep it alive until work actually arrives.
- Serialize handlers that touch shared state with a strand instead of a mutex, and measure the difference in blocked threads and futex calls.
- Determine which thread runs a given handler under each `io_context` threading shape, and identify where that choice forces synchronization.
- Relate Boost.Asio's executor and strand vocabulary to C++26's proposed scheduler/sender model.

## Why this matters

A hand-rolled `epoll` loop answers every question about concurrency by construction: one thread, one queue, no ambiguity about who runs what. Reaching for a library like Boost.Asio buys scale, more sockets, more threads, less code to maintain, at the cost of making "which thread runs this handler" a question with more than one answer. Getting that question wrong is a data race that may not show up until the thread pool grows past one worker in production.

This chapter builds the mental model needed to answer it correctly: the readiness mechanism underneath both the hand-rolled loop and Asio is identical, and the strand is the tool that restores single-threaded reasoning for the one piece of shared state that needs it, without paying for a lock.

## What we'll cover

- Put [Chapter 11]({{ '/docs/11-coroutines-in-depth/' | relative_url }})'s `ReadAwaitable` on a real `epoll` reactor, and trace a coroutine's suspend-resume cycle through `epoll_ctl`/`epoll_wait`.
- Cover Boost.Asio's `io_context`, why a freshly constructed one returns from `run()` having done nothing, and the work guard that keeps it alive.
- Introduce the strand as an executor that serializes handlers without a mutex, and measure what that buys over blocking.
- Trace, concretely, which thread ends up running a given handler under a multi-threaded `io_context`, and preview where C++26 execution schedulers fit.

Chapter 11 built the coroutine itself: the frame, `promise_type`, and the `await_ready`/`await_suspend`/`await_resume` triad that lets a function suspend without blocking its caller. That chapter's `ReadAwaitable` handed a coroutine handle to a `Reactor` and trusted it to call `.resume()` later. This chapter is that reactor, built out, and then a library's answer to the same problem: Boost.Asio, which does the same readiness-based suspension but adds vocabulary a hand-rolled loop never needed: who runs a handler, and whether two of them can run at once. Nothing below re-derives `co_await` or the awaitable protocol; both are assumed.

## The epoll Event Loop

A `recv` or `accept` on a nonblocking socket either succeeds immediately or returns `EAGAIN`, and `EAGAIN` is not an error to propagate: it is the kernel's way of saying "nothing to read yet, ask again later." A thread that busy-polled on that answer would burn a core doing nothing; `epoll_wait` is the alternative, a single syscall that blocks the calling thread until at least one of a whole set of watched file descriptors becomes ready, handing back exactly which ones. One thread can watch thousands of connections this way, asleep until there's real work.

A coroutine reactor wires `ReadAwaitable::await_suspend` directly to that interest set. Recall the shape from Chapter 11:

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

`wait_readable` is where the coroutine handle actually meets the kernel:

```cpp
void Reactor::wait_readable(int fd, std::coroutine_handle<> h) {
    waiters_[fd] = h;
    epoll_event ev{};
    ev.events = EPOLLIN | EPOLLONESHOT;
    ev.data.fd = fd;
    const int op = armed_.insert(fd).second ? EPOLL_CTL_ADD : EPOLL_CTL_MOD;
    ::epoll_ctl(epfd_, op, fd, &ev);
}
```

`waiters_[fd]` is the map from a watched descriptor back to the exact coroutine frame parked on it. `EPOLLONESHOT` disarms the descriptor the instant it fires, so a socket that becomes readable wakes the one coroutine waiting on it and nothing double-resumes before the next `co_await` re-arms it: the same discipline a level-triggered loop needs to avoid spurious re-notification, reused here to keep exactly one resumption per readiness event. The reactor's run loop is the other half:

```cpp
void Reactor::run() {
    epoll_event events[64];
    while (!stopped_) {
        int n = ::epoll_wait(epfd_, events, 64, -1);
        for (int i = 0; i < n; ++i) {
            auto it = waiters_.find(events[i].data.fd);
            if (it != waiters_.end()) {
                auto h = it->second;
                waiters_.erase(it);
                h.resume();
            }
        }
    }
}
```

`h.resume()` is a plain function call into the coroutine frame, which runs from its suspension point as if the blocking `recv` it was waiting on had simply returned data. Nothing about `await_resume()` (still `void` in `ReadAwaitable` above) tells the caller anything happened; the information the coroutine actually wants, the bytes, comes from calling `recv` again once resumed, which is why the retry loop lives in the coroutine body rather than in the awaitable. The entire mechanism is: one epoll instance, one map from fd to handle, and a resume call. No thread pool, no scheduler abstraction, nothing a library adds, which is exactly the baseline the next sections measure a library against.

<!-- DIAGRAM SPEC: cream #fdfbf7 background, three horizontal bands. Top band "coroutine" holds a connection() frame with a highlighted box "co_await ReadAwaitable{reactor, fd}" in blue #4a73b8 and a dashed "frame suspended, nothing on the stack" box beside it. Middle band "Reactor (one thread)" holds "wait_readable(fd, h): waiters_[fd] = h" in orange #a06030 and "epoll_wait(-1)" in green #5a8870, with an amber arrow from the coroutine's co_await down into wait_readable labeled "await_suspend", an arrow from wait_readable to a kernel box labeled "epoll_ctl(EPOLLIN|EPOLLONESHOT)", and an arrow coming back up from epoll_wait to the coroutine labeled "h.resume()". Bottom band "kernel" holds an "fd readable" box in red #c0392b that fires into epoll_wait. Caption note: "suspension is a return, not a blocked thread." -->
{% include excalidraw.html name="12-epoll-coroutine-suspension" caption="Figure 12.1: Chapter 11's ReadAwaitable, wired to a real epoll reactor. await_suspend parks the handle, epoll_wait resumes the exact handle that fd belongs to" %}

## The io_context and the Work Guard

Boost.Asio's `io_context` is a library's version of the `Reactor` above, backed on Linux by the same `epoll_wait` call, hidden behind an executor interface. Nothing about readiness changes by switching to it; what changes is a lifetime model that trips up almost everyone the first time they meet it.

```cpp
asio::io_context ioc;
std::size_t ran = ioc.run();   // ran == 0, immediately
```

A freshly constructed `io_context` has nothing queued, and `run()` returns the moment it finds no outstanding work, not when some notion of "the program is done" is satisfied, because the `io_context` has no way to know what that means. A hand-rolled reactor's lifetime is the `while` loop you wrote; an `io_context`'s lifetime is a refcount on pending operations, and that refcount can legitimately hit zero before the async work you meant to start has even been posted.

The fix is `asio::executor_work_guard`, a claim against that refcount that keeps `run()` blocked until something releases it:

```cpp
asio::io_context ioc;
auto guard = asio::make_work_guard(ioc);
asio::post(ioc, [&guard] {
    do_startup_work();
    guard.reset();   // release the claim; run() may now return
});
std::thread t([&ioc] { ioc.run(); });   // blocks until guard.reset()
```

The guard is not tied to any particular handler; it is a bare promise that work is coming, independent of whether any has been posted yet. A server that accepts connections for its whole lifetime typically holds a guard for exactly that long, so that a lull with zero connections in flight (zero outstanding work, by the `io_context`'s own accounting) doesn't make `run()` walk off the end of the thread that's supposed to keep serving. Releasing the guard, by contrast, is how a program tells its `io_context` threads to drain and exit once the last handler finishes, without an explicit `stop()` that would cut off work mid-flight.

## The Strand: Serialization Without a Mutex

A single `epoll_wait` loop never needed a vocabulary for "can two handlers run at once," because there was only ever one thread to run them. An `io_context` with several threads all calling `run()` on it has no such guarantee by default: the same handler, posted to a shared queue that eight threads are pulling from, can execute on any of them, including two at the same time on two different handlers touching the same data.

A **strand** is an executor wrapping another executor with one guarantee: handlers posted through it never run concurrently with each other, no matter how many threads are servicing the underlying `io_context`. Posting the identical handler body two ways makes the difference concrete. Through a strand, with eight threads all calling `run()`:

```cpp
asio::strand<asio::io_context::executor_type> strand(ioc.get_executor());
long counter = 0;   // deliberately unsynchronized
for (int i = 0; i < 2000; ++i) {
    asio::post(strand, [&counter] { ++counter; });
}
// after 8 threads drain the queue: counter == 2000, every time
```

An unsynchronized `long`, incremented 2,000 times from a pool of eight threads, still lands on exactly 2,000, because the strand never lets two of those increments overlap: there is no race to lose. Post the same handler straight to the `io_context` instead of through the strand, change nothing else, and the count comes back short, with two handlers observed executing at once; how many increments are lost and how many overlaps occur shift from run to run as scheduling shifts. The sign never moves (unguarded, concurrent increments on a plain `long` lose updates); only the magnitude does, which is the expected shape of a measurement whose subject is undefined behavior: a run that happened to lose nothing would be legal, not evidence the race wasn't there.

A mutex around that same counter would also produce the correct count, and that comparison is where a strand earns a separate name rather than being "a lock with extra steps." A contended `std::mutex` falls back to `futex(FUTEX_WAIT)` on Linux ([Chapter 5]({{ '/docs/05-shared-state-and-the-futex/' | relative_url }})): the losing thread sleeps, and someone has to wake it. A strand never puts a thread to sleep at all: if a handler can't run right now because another one from the same strand is mid-execution, the strand queues it and the thread that would have run it goes back to the `io_context` to pick up other work instead. Counting futex calls under `strace -f -c -e trace=futex` for identical, correct work shows the strand reaching the kernel several times less often than the mutex, because it never parks a thread and so has nothing to wake. The runnable example measures the exact ratio on whatever host runs it. **A mutex blocks a thread. A strand defers a handler.**

What a strand costs instead is ordering: `asio::post(strand, h)` means "run this later, through the queue," even if the posting thread is idle and nothing else holds the strand at that moment. `asio::dispatch` is the escape hatch for "run inline if it's safe to do so right now, defer only if it isn't", named here as the alternative, not built out. And a strand's guarantee is narrower than it sounds: it says nothing about a thread touching the same data outside a handler entirely, and nothing about handlers posted through a *different* strand. A strand is a serialization domain you associate with one piece of shared state (a connection, a session), not a blanket lock over your whole program.

## Who Actually Runs Your Handler

A hand-written `epoll_wait` loop answers "which thread runs this handler" by construction: the one thread that called `epoll_wait`, because there is only one. Asio turns that into a choice, made by how you call `run()`, and the choice is visible from outside the process by reading `gettid()` inside each handler and counting the distinct values:

- **One thread, one `io_context`**: every handler runs on the thread that called `run()`. Nothing inside a handler needs synchronization, because nothing else can be running concurrently with it.
- **Several threads, one shared `io_context`**: all of them calling `run()` on the same object, pulling from one queue. Handlers can land on any of them, including two at once on two different cores. This is the shape that makes a strand necessary rather than optional.
- **One `io_context` per thread**: no sharing, so no cross-thread handoff for handlers on that context's own descriptors, at the cost of not being able to move load from a busy context to an idle one.
- **A dedicated thread pool** (`asio::thread_pool`): the pool owns its worker threads outright, and there is no `run()` call written anywhere in that branch; work is posted to the pool's executor instead.

The practical rule that falls out of this: a handler is not thread-safe merely because Asio handed it to you. The same handler body is race-free under the first shape and a live data race under the second, and the only thing that changed is how many threads called `run()`. Code that assumes single-threaded semantics because the reactor "feels" single-threaded (because it was, in the hand-rolled version this chapter opened with) is exactly the bug a strand exists to close, and exactly the bug that `gettid()` sampling catches from outside when a review of the source alone does not.

## Execution Schedulers

Everything above is one executor model: post a callable, have something run it, maybe through a strand for ordering. C++26's proposed `std::execution` (the senders/receivers model from P2300, already previewed in Chapter 11 for coroutine composition) generalizes the same idea into a standard vocabulary that an `io_context`, a thread pool, or a hand-rolled reactor could all implement: a **scheduler** is anything you can `schedule()` work onto, and a **sender** is a description of that work, composable with `then`, `when_all`, and friends before anything runs.

```cpp
// C++26 (proposed; shape per P2300, no shipping compiler support)
namespace ex = std::execution;

ex::sender auto pipeline =
    ex::schedule(io_scheduler)
    | ex::then([] { return read_request(); })
    | ex::then([](Request r) { return handle(r); });

ex::sync_wait(std::move(pipeline));
```

An `io_context`'s executor and a strand both anticipate this model without implementing it: an executor is already "a thing you post work to," and a strand is already "an executor with an ordering guarantee", which is close to a scheduler with a serialization property attached. What `std::execution` would add is a standard type for both concepts, so a pipeline built against it isn't locked to Asio's executor interface specifically. As of this writing it is proposed and experimental, with no mainstream shipping compiler implementing it; Boost.Asio's `io_context`, strand, and work guard remain the practical vocabulary for this problem today.

## Running in a container

The epoll reactor and the `io_context` both read file-descriptor limits from the same place a container constrains them: `ulimit -n`, or the pod-level equivalent an orchestrator sets. A connection-heavy service that sizes its listen backlog or its expected concurrent-connection count against the host's default `1048576` will instead hit `EMFILE` well before that, inside a container whose `nofile` soft limit was left at a conservative default. The failure mode is a `accept4` returning an error the coroutine's retry loop was never written to expect, not a crash with an obvious cause.

The strand's benefit over a mutex (fewer futex calls, no blocked thread) compounds under a CPU quota rather than canceling out. A `std::mutex`'s contended path parks a thread via `futex(FUTEX_WAIT)` and someone has to wake it later; under a tight `cpu.max` quota, that thread may not get scheduled again for a full period after its wakeup is posted, stretching a lock hold into a visible stall. A strand never parks anybody: a deferred handler just waits in a queue for whichever `io_context` thread next has quota to spend, so the same CPU throttling that makes a mutex-based design's latency erratic leaves a strand-based one comparatively unaffected, since there was never a sleeping thread for the scheduler to delay waking. Running the multi-threaded `io_context` echo-server example from this chapter inside a container built with `--cpus=2` and comparing `distinct_tids` under `topology-pool` against the unconstrained host run is the direct way to see that a quota narrows how many threads actually run concurrently without changing how many Asio is willing to spawn.

The runnable version of this chapter's measurements lives at `examples/concurrency/12-asio-strand/`.

<!-- EXAMPLE SPEC: posts the same unsynchronized-counter handler through a strand and directly to a multi-threaded io_context, reports counter/overlap counts for both, and measures futex calls under strace for a strand versus a std::mutex doing equivalent work; also runs an echo server under topology-one/topology-pool/topology-percore shapes reporting distinct_tids via gettid(). Docker via lgtm-docker-stack (strace available in the image; also demonstrates the --cpus constraint narrowing distinct_tids under topology-pool). Verified by a Lua verify.lua asserting the strand case has overlaps==0 and counter==expected, the no-strand case has overlaps>0, strand futex calls < mutex futex calls / 2, and topology-one reports exactly distinct_tids==1 while topology-pool reports distinct_tids>1. -->

## Standards: C++20 / C++23 / C++26

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20 -- Asio's coroutine integration is built directly on Chapter 11's
// machinery: asio::awaitable<T> is a coroutine type with its own
// promise_type, and co_spawn launches it on an executor.
asio::awaitable<void> echo(tcp::socket sock) {
    char buf[1024];
    for (;;) {
        std::size_t n = co_await sock.async_read_some(
            asio::buffer(buf), asio::use_awaitable);
        co_await asio::async_write(sock, asio::buffer(buf, n), asio::use_awaitable);
    }
}
asio::co_spawn(ioc, echo(std::move(sock)), asio::detached);
```

```cpp
// C++23 -- identical coroutine contract; no new Asio-facing language feature
// shipped. std::move_only_function lets a completion-handler queue hold
// heterogeneous, move-only handlers (one that owns a socket, say) without
// std::function's copyability tax.
std::vector<std::move_only_function<void(std::error_code)>> pending;
pending.emplace_back([sock = std::move(sock)](std::error_code ec) mutable {
    if (!ec) { /* ... */ }
});
```

```cpp
// C++26 (proposed, std::execution / P2300 -- no shipping compiler support)
// A scheduler and sender pipeline express "what work, on what executor" as a
// composable value, generalizing the executor/strand vocabulary above rather
// than replacing it.
auto work = std::execution::schedule(io_scheduler)
          | std::execution::then([] { return read_next(); });
std::execution::sync_wait(std::move(work));
```

Execution policies for readiness and suspension are unchanged across all three columns; every delta here is in how work gets *composed and scheduled*, not in how a socket becomes readable. Boost.Asio's own API has tracked this without waiting for the standard: `co_spawn`/`awaitable`/`use_awaitable` already express the C++20 coroutine column above in shipping code, years ahead of any standard networking facility reaching the same point, and `std::execution` is positioned to generalize the executor concept Asio already has rather than to introduce a new one from nothing.

## What we learned

- `epoll_wait` is the mechanism under every reactor in this book: one syscall, many watched descriptors, returns only the ones that are ready. `ReadAwaitable::await_suspend` from Chapter 11 parks a coroutine handle against a descriptor; `EPOLLONESHOT` guarantees exactly one resume per readiness event.
- `io_context::run()` returns on no outstanding work, not on completion: a fresh context runs zero handlers immediately, and `executor_work_guard` is the claim that keeps it alive until something explicitly releases it.
- A strand serializes handlers without a lock: the same unsynchronized counter incremented by eight threads came back exactly correct through a strand and measurably wrong posted straight to the `io_context`, with only the executor changed.
- A mutex blocks a thread into the kernel on contention; a strand defers a handler and returns the thread to the pool: correct either way, with the strand reaching the kernel several times less often on equivalent work.
- Who runs a handler is a choice visible from outside the process via `gettid()`: one thread, a shared pool, one context per thread, or a dedicated thread pool each change what a handler may safely assume about concurrent execution.
- C++26's proposed `std::execution` senders and schedulers generalize the executor/strand vocabulary Asio already has into a standard, composable form; no shipping compiler implements it, so Asio's own types remain the practical tool today.

Next, [Fibers and Stackful Coroutines]({{ '/docs/13-fibers-and-stackful-coroutines/' | relative_url }}) covers the other way to suspend a unit of work: one with its own stack, able to suspend from inside ordinary, non-coroutine code that `co_await` can never reach.
