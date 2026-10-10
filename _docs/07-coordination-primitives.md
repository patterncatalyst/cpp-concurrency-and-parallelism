---
title: "Coordination Primitives"
order: 7
layout: tutorial
sectionid: docs
part: shared-state-and-synchronization
description: "condition_variable, C++20's latch and barrier, and counting_semaphore, and how to choose among them."
duration: "12 min"
---

<!-- PROVENANCE: NEW | anchor books: Grimm, Williams -->

## What we'll cover

- `condition_variable`'s predicate-loop idiom, and why a bare `wait()` is a correctness bug, not a style preference.
- C++20's `std::latch` for a single-use countdown and `std::barrier` for a reusable, phased rendezvous with a completion step.
- `std::counting_semaphore` and `std::binary_semaphore` for bounding concurrent access without the ownership semantics of a mutex.
- A decision guide mapping coordination patterns (rendezvous, phased pipeline, resource pool) to the primitive built for each.

A mutex ([Chapter 6]({{ '/docs/06-mutual-exclusion-and-locking/' | relative_url }})) answers one question: who may touch this data right now. Most concurrent programs also need to answer a second, different question: has some condition become true yet, and how many threads should proceed when it does. That is coordination, not exclusion, and conflating the two is where a surprising fraction of concurrency bugs live. This chapter covers the standard library's purpose-built answers to the coordination question.

## condition_variable and Spurious Wakeups

`std::condition_variable` lets a thread block until another thread signals that something worth checking has changed. The mechanics are three pieces: a `std::mutex` guarding the shared state, the condition variable itself, and a predicate — a function or lambda that inspects the state and returns whether the wait is actually over.

The naive form waits without a predicate:

```cpp
std::unique_lock lk(m);
cv.wait(lk);          // returns... sometimes for the wrong reason
```

This compiles, runs, and fails intermittently in production. `wait()` can return without any call to `notify_one()` or `notify_all()` — a spurious wakeup, permitted by the standard because the underlying futex wakeup on Linux ([Chapter 5]({{ '/docs/05-shared-state-and-the-futex/' | relative_url }})) can itself be spurious, and because POSIX condition variables make the same allowance. A spurious wakeup is not a malfunction to work around defensively; it is part of the contract, and code that ignores it is wrong by specification, not by bad luck.

The fix is the predicate form:

```cpp
std::unique_lock lk(m);
cv.wait(lk, [&] { return ready; });
```

This is equivalent to:

```cpp
while (!ready) {
    cv.wait(lk);
}
```

`wait` reacquires the lock before testing the predicate, loops back to sleep if the predicate is still false, and returns holding the lock once it's true. The loop also absorbs a second real hazard beyond spurious wakeup: a notification that arrives before the waiter has even started waiting (the waiter checks `ready`, finds it false, and the notifying thread sets it and calls `notify_one()` in the gap before `wait()` is actually called) is not lost, because the predicate check at the top of the loop catches the already-true state on first entry. The predicate must read state protected by the same mutex `lk` holds; a condition variable has no memory of its own; it is purely a wakeup channel layered over state you track separately.

`notify_one()` wakes a single waiter and is the right default when any one waiter can make progress on the new state (e.g., a work queue with one item added). `notify_all()` wakes every waiter and is required when the state change doesn't matter equally to all of them — a shutdown flag, or state where the predicate differs per waiter. Calling `notify_one()` when the logic actually requires `notify_all()` manifests as threads that hang forever, waiting for a wakeup that already happened and was delivered to someone else.

C++20 adds `std::condition_variable_any`, which works with any lockable type (not just `std::unique_lock<std::mutex>`) and gained a `stop_token`-aware overload: `wait(lock, stop_token, predicate)` returns early if the token's `stop_requested()` becomes true, which composes directly with `std::jthread`'s cooperative cancellation ([Chapter 4]({{ '/docs/04-threads-in-modern-cpp/' | relative_url }})) without hand-rolling a cancellation flag alongside the data predicate.

## C++20 latch and barrier

A condition variable with a counter and a predicate can implement a countdown rendezvous, but C++20 standardizes the two most common shapes directly, and both are lock-free in their fast path on most implementations.

`std::latch` is single-use. Construct it with a count; threads call `count_down()` as they finish their part, and `wait()` blocks until the count reaches zero:

```cpp
std::latch startup_done(3);

auto worker = [&](int id) {
    initialize_subsystem(id);
    startup_done.count_down();
    startup_done.wait();      // all three must finish before any proceeds
    run_subsystem(id);
};
```

`arrive_and_wait()` combines the two calls for the common case where the same thread does both. Once the count hits zero, the latch is spent — there is no way to reset it and reuse it for a second round. That one-shot nature makes `latch` the right tool for startup barriers, "wait for N subsystems to initialize," or "wait for N background tasks launched at the top of a function to finish before returning" (a scope-exit latch takes the place of joining N threads individually, and composes with task-based rather than thread-based parallelism).

`std::barrier` is the reusable counterpart, built for a loop where the same group of threads needs to rendezvous once per phase, repeatedly:

```cpp
std::barrier sync_point(num_workers, [] {
    // completion function: runs once per phase, on one arriving thread,
    // after all num_workers have arrived and before any is released.
    merge_phase_results();
});

auto worker = [&](int id) {
    for (int phase = 0; phase < num_phases; ++phase) {
        do_phase_work(id, phase);
        sync_point.arrive_and_wait();   // blocks until all workers reach here
    }
};
```

The completion function is `barrier`'s distinguishing feature over a hand-rolled countdown: it runs exactly once per phase, after every thread has arrived and before any is released into the next phase, making it the natural place to merge per-thread partial results or swap double-buffered state. Because a `barrier` resets its count automatically for the next phase, the same object drives an arbitrary number of rounds. `arrive_and_drop()` lets a thread exit the group permanently (useful when a work-stealing pool shrinks mid-run) without blocking the remaining participants on a count the exiting thread can no longer satisfy.

<!-- EXAMPLE SPEC: examples/concurrency/07-coordination-primitives/ runs a fixed worker pool through several barrier-synchronized phases, each phase writing a partial sum into a per-thread slot and the completion function merging those slots into a running total; verified by a Lua verify.lua asserting the final merged total matches the closed-form expected sum and that stdout shows exactly one completion-function line per phase (never zero, never more than once), built via lgtm-docker-stack. -->
The example at `examples/concurrency/07-coordination-primitives/` runs this pattern end to end.

{% include codetabs.html langs="C++20|C++23|C++26" %}
```cpp
// C++20: completion function type is fixed at construction and must be
// invocable with no state beyond what it captures by reference/pointer.
std::barrier phase_sync(4, [&shared_buffer] {
    shared_buffer.swap_halves();
});
```
```cpp
// C++23: no change to latch/barrier's public interface; the standard
// library's underlying futex-based implementations on Linux narrowed their
// spurious-wake surface, which is an implementation quality improvement,
// not an API difference worth coding around.
std::barrier phase_sync(4, [&shared_buffer] {
    shared_buffer.swap_halves();
});
```
```cpp
// C++26: std::barrier and std::latch are unchanged; coordination in this
// release is extended instead by hazard_ptr/rcu for lock-free reclamation
// (Chapter 9), not by new rendezvous types.
std::barrier phase_sync(4, [&shared_buffer] {
    shared_buffer.swap_halves();
});
```

## counting_semaphore

`std::counting_semaphore<LeastMaxValue>` tracks a non-negative count of available "permits." `acquire()` blocks until a permit is available and decrements it; `release(n)` adds `n` permits back; `try_acquire()` and the timed variants (`try_acquire_for`, `try_acquire_until`) are non-blocking or time-bounded. `std::binary_semaphore` is an alias for `counting_semaphore<1>`.

The distinction from a mutex is ownership. A mutex has a notion of the owning thread — only the thread that locked it may unlock it, and most implementations assert or invite undefined behavior on a cross-thread unlock. A semaphore has no owner: any thread may call `release()`, including one that never called `acquire()`. That makes a semaphore the right tool for signaling between threads (a producer releasing permits a different consumer acquires) and the wrong tool for protecting a critical section, where you want exactly the owning-thread discipline a mutex enforces.

A counting semaphore bounds concurrency directly — capping the number of threads inside a section to `N` without full mutual exclusion:

```cpp
std::counting_semaphore<8> connection_slots(8);

void handle_request() {
    connection_slots.acquire();
    struct ReleaseGuard {
        std::counting_semaphore<8>& sem;
        ~ReleaseGuard() { sem.release(); }
    } guard{connection_slots};
    do_work_with_bounded_concurrency();
}
```

Eight threads can be inside `do_work_with_bounded_concurrency()` simultaneously; the ninth blocks in `acquire()` until one of the eight releases. A mutex can't express "up to 8," only "up to 1." A `std::binary_semaphore` initialized to 0 is also the idiomatic way to signal a single event from one thread to another — simpler than a `condition_variable` plus a boolean flag plus a mutex when there's exactly one piece of state (has the event happened) and no predicate logic beyond that.

On Linux, `counting_semaphore`'s fast path is a lock-free atomic decrement; only the blocking path touches the futex, the same two-tier design covered for `std::mutex` in [Chapter 5]({{ '/docs/05-shared-state-and-the-futex/' | relative_url }}).

Neither the standard nor glibc's futex-based implementation guarantees FIFO fairness among blocked acquirers: a semaphore released while several threads are queued does not promise to wake the longest-waiting one first. For most resource-pool uses that's immaterial, since any of the eight connection slots serves any caller equally. Code that relies on semaphore order to implement priority or round-robin scheduling is relying on an implementation detail, not a guarantee. It should build that ordering explicitly, with a queue of waiters each holding its own `binary_semaphore`, rather than trust acquisition order.

The `LeastMaxValue` template parameter on `counting_semaphore` is a hint, not a hard ceiling enforced at runtime — it tells the implementation the maximum value the count will reach, which lets some implementations pick a cheaper internal representation, but `release()` calls that push the count past a value the hint didn't anticipate are still well-defined as long as they stay within the type's actual range. Picking a small, accurate `LeastMaxValue` (8 for an 8-slot pool, not some arbitrary large number) costs nothing and documents the intended bound at the call site.

## Choosing the Right Primitive

<!-- DIAGRAM SPEC: three stacked lanes on a cream #fdfbf7 background, one per primitive, each showing three worker boxes (blue #4a73b8) feeding into a shape. Lane 1 "latch (single-use)": three worker boxes each with an arrow labeled "count_down()" into a counter box starting at 3 and counting to 0; a dashed red #c0392b line through the counter after it hits zero labeled "spent — cannot reset"; one waiter box released past the counter labeled "wait() returns once". Lane 2 "barrier (reusable)": three worker boxes arrive at a hexagon labeled "completion function" (green #5a8870), an orange #a06030 curved arrow loops from the hexagon back to the worker boxes labeled "phase N+1 — count resets automatically". Lane 3 "counting_semaphore(8)": a pool box labeled "8 permits" with multiple worker boxes acquiring (arrows in, permits decrementing) and releasing (arrows out, permits incrementing) concurrently, no single owner highlighted, caption note "any thread may release, not just the acquirer". -->
{% include excalidraw.html name="07-coordination-primitives" caption="Figure 7.1 — latch (single-use countdown), barrier (reusable phased rendezvous with a completion function), and counting_semaphore (ownerless permit pool) side by side" %}

| Pattern | Primitive | Why |
|---|---|---|
| Wait for a state change, re-check under a lock | `condition_variable` (predicate form) | Only tool with a built-in wait-and-recheck loop against externally tracked state |
| Wait for N one-time events, then proceed | `std::latch` | Single-use countdown, no reset needed |
| Repeated phased rendezvous across a fixed thread group | `std::barrier` | Reusable, with a completion function run once per phase |
| Bound concurrent access to a resource pool | `std::counting_semaphore` | Permits without ownership; any thread may release |
| Signal a single event, thread-to-thread | `std::binary_semaphore` | Lighter weight than a condvar+flag+mutex when there's no predicate logic |
| Protect a critical section | `std::mutex` / `std::shared_mutex` | Only these enforce owning-thread discipline ([Chapter 6]({{ '/docs/06-mutual-exclusion-and-locking/' | relative_url }})) |

A rule of thumb that resolves most ambiguity: if the question is "may I touch this data," reach for a mutex; if it's "has this happened yet" or "have enough of us arrived," reach for a coordination primitive. Mixing them up produces code that happens to work on today's scheduler and kernel and stops working on tomorrow's — using a semaphore to protect mutable state another thread reads without its own synchronization, say, or polling a flag under a mutex in a tight loop instead of blocking in a condition variable.

Two anti-patterns are common enough to call out directly. The first is reinventing `latch` or `barrier` from a raw `condition_variable` and a hand-counted integer: the logic is easy to get right once and easy to get subtly wrong the second time a phase count changes, and the standard types exist precisely so that counting logic isn't rewritten per project. The second is using a `condition_variable`'s bare `wait()` because "this code path only ever has one notifier," a claim that is usually true until a refactor adds a second one; the predicate form costs one extra lambda and removes an entire class of future regression. Neither anti-pattern fails a code review by inspection — both pass until the exact interleaving that exposes them shows up on a production host months later.

## Running in a container

The `barrier`-phased worker pattern above is sensitive to the number of participants, which is exactly the number a container often lies about: `std::thread::hardware_concurrency()` reports the host's core count unless the container's cgroup CPU quota is read directly, so a pool sized off `hardware_concurrency()` inside a `--cpus=4` container can construct a `barrier` for more participants than there are cores to run them, and a late-arriving thread stalls every other phase waiting for a CPU slice the scheduler keeps deferring. Size the participant count from `sched_getaffinity` or the cgroup `cpu.max` file, not from `hardware_concurrency()` alone, when running phased-barrier code in a container with a CPU limit. Running the same program under `docker run --cpus=2` versus `--cpus=8` with a fixed participant count is a direct way to see barrier phases lengthen as the host oversubscribes available cores. The completion function still runs exactly once per phase, but the phase itself takes longer to complete as each `arrive_and_wait()` queues for CPU time rather than running immediately.

## Standards: C++20 / C++23 / C++26

C++20 introduced all four primitives covered in this chapter (`latch`, `barrier`, `counting_semaphore`/`binary_semaphore`, and `condition_variable_any`'s `stop_token` overload) as part of the same standardization wave as `jthread`. There is no C++17 fallback; code targeting C++17 reimplements these with a mutex, a condition variable, and a counter, which is precisely the boilerplate these types exist to delete.

C++23 made no changes to the public interface of `latch`, `barrier`, or the semaphore types. The practical change was in implementation quality: several standard library implementations tightened the futex-wait paths these types sit on, reducing unnecessary wakeups under contention. No source change is needed to benefit from it.

C++26 does not add new rendezvous or counting primitives. The coordination story's next real addition is in lock-free reclamation, covered in [Chapter 9]({{ '/docs/09-lock-free-data-structures/' | relative_url }}) — `std::hazard_pointer` and `std::rcu`, both still experimental and without shipping compiler support, not in this chapter's scope.

## What we learned

- `condition_variable` is a wakeup channel, not a memory of state; always wait on a predicate that re-checks externally tracked data, because spurious wakeups and missed-notification races are part of the specified contract, not edge cases.
- `std::latch` is a single-use countdown for one-time rendezvous (startup, scope-exit joins); `std::barrier` is its reusable, phased counterpart, distinguished by a completion function that runs once per phase on the arriving threads' behalf.
- `std::counting_semaphore` bounds concurrent access without a mutex's ownership discipline — any thread may `release()`, which is exactly what makes it fit for producer/consumer signaling and resource-pool caps that a mutex cannot express.
- The dividing line between a mutex and every primitive in this chapter is the question each answers: "may I touch this data" versus "has this happened yet." Reaching for the wrong one produces code whose bugs are intermittent and timing-dependent rather than immediate.
