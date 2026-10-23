---
title: "Mutual Exclusion and Locking"
order: 6
layout: tutorial
sectionid: docs
part: shared-state-and-synchronization
description: "The mutex family, the RAII lock wrapper types, and the lock-ordering discipline that avoids deadlock."
duration: "15 min"
---

<!-- PROVENANCE: NEW (adapted from linux-systems-programming/_docs/50-pthreads.md, 51-std-threading.md) | anchor books: Williams, Grimm -->

## Learning objectives

By the end of this chapter you can:

- Choose among `mutex`, `recursive_mutex`, `timed_mutex`, and `shared_mutex` based on the specific capability a critical section actually needs.
- Pick the right RAII wrapper (`lock_guard`, `unique_lock`, or `scoped_lock`) for a given acquisition pattern, including multi-mutex locking.
- Apply a lock-ordering convention, or `std::scoped_lock`'s try-all-and-back-off algorithm, to prevent circular-wait deadlock.
- Diagnose a deadlock from outside a process using `/proc/<pid>/task/*/wchan`, without a debugger attached.
- Justify RAII locking as the default and treat a bare `lock()`/`unlock()` pair as a finding that needs explicit justification in review.

## Why this matters

A two-mutex deadlock produces no exception, no error code, and no log line. The program stops producing observable behavior and sits there, and nothing short of inspecting kernel-level thread state from outside the process reveals why. That failure mode is unforgiving in production: it surfaces under load, on an interleaving nobody's test exercised, often weeks after the code that introduced it shipped.

The fix is mostly discipline rather than cleverness: pick the right mutex type for the job, wrap every acquisition in RAII so an exception or early return cannot strand a lock, and either enforce a global lock order or let `scoped_lock` handle multi-mutex acquisition safely by construction. Each of those choices is cheap to make correctly up front and expensive to retrofit once a deadlock has already shipped to production.

## What we'll cover

- Survey the mutex family: `mutex`, `recursive_mutex`, `timed_mutex`, and `shared_mutex`, and when each is the right choice.
- Cover the RAII lock wrapper types: `lock_guard`, `unique_lock`, and C++17's `scoped_lock` for multi-lock acquisition.
- Establish a lock-ordering convention that prevents circular-wait deadlock across more than one mutex.
- Make the case for RAII locking as the default, with manual `lock()`/`unlock()` treated as an exception that needs justification.

## The Mutex Family

`std::mutex` is the default for a reason: it is non-recursive, exclusive, and
as cheap as the previous chapter demonstrated when it is not contended.
Everything else in the family trades some of that simplicity for a specific
capability, and the trade deserves a precise accounting, because reaching for the
wrong family member is a common source of subtle bugs.

`std::recursive_mutex` permits the same thread to lock it more than once
without deadlocking itself, decrementing an internal count on each matching
`unlock()`. It exists for one legitimate reason: a call graph where a locked
function may re-enter itself or call another function that needs the same
lock, typically in code you cannot restructure cleanly: virtual dispatch
through a base class that also takes the lock, for instance. It is not a
convenience for "I didn't want to think about who already holds this." A
recursive mutex that is reached for to paper over an unclear locking
discipline usually means the discipline needs fixing, not the mutex type;
every recursive acquisition is a place where the invariant the lock is
supposed to protect might already be mid-violation by the outer call.

`std::timed_mutex` and its recursive and shared variants add
`try_lock_for()` and `try_lock_until()`, which attempt to acquire the lock
but give up after a duration or at a deadline rather than blocking forever.
The use case is narrow and specific: a path that must make forward progress
even when contended, trading correctness-under-contention for
liveness-under-contention. A server thread that would rather return a
"busy" response than block indefinitely behind a slow holder is the shape
this exists for; it is not a general substitute for understanding why the
lock is held for as long as it is.

`std::shared_mutex` (C++17) is the one that actually changes the concurrency
model rather than just adding a timeout. It supports two acquisition modes:
exclusive, via `lock()`/`unique_lock`, for a writer that needs sole access,
and shared, via `lock_shared()`/`shared_lock`, for readers that may run
concurrently with each other as long as no writer holds the exclusive mode.
For a cache or configuration structure that is read far more often than it
is written, this converts what would be serialized reader traffic under
`std::mutex` into parallel reads, at the cost of a somewhat more
expensive lock operation per acquisition and the possibility of writer
starvation under some implementations' fairness policies. Measure before
assuming it is a net win on a given workload: a shared_mutex under light
contention is strictly more expensive per operation than a plain mutex, and
the payoff only appears once reader concurrency is real.

| Type | Recursive? | Timeout? | Reader/writer split? | Typical use |
| --- | --- | --- | --- | --- |
| `mutex` | no | no | no | the default |
| `recursive_mutex` | yes | no | no | unavoidable re-entrant locking |
| `timed_mutex` | no | yes | no | bounded-wait acquisition |
| `shared_mutex` | no | no | yes | read-heavy shared state |

## RAII Lock Wrappers

A mutex acquired with a bare `lock()` call is correct only until the first
exception, early return, or `break` statement between that call and the
matching `unlock()`, any of which skips the unlock and leaves the mutex
held forever, with every other thread that wants it blocking silently. RAII
wrapper types exist to make that failure mode unreachable by construction:
the lock is acquired in a constructor and released in a destructor, so the
ordinary unwinding machinery of the language (the same mechanism that runs
destructors on every exit path from a scope) releases the lock regardless
of how the scope is left.

`std::lock_guard` is the minimal version: it acquires its mutex in the
constructor, releases it in the destructor, and offers nothing else. No
deferred locking, no manual unlock before the scope ends, no move support.
That minimalism is a feature in a code review: a `lock_guard` in a function
body is a guarantee, visible at a glance, that the lock is held for exactly
that scope's lifetime and no longer.

`std::unique_lock` is the version with options. It can defer acquisition
(`std::defer_lock`), adopt a lock already held by the calling thread
(`std::adopt_lock`), try rather than block (`std::try_to_lock`), release
early with an explicit `.unlock()` and later re-`.lock()` within the same
scope, and it is movable, so ownership of a held lock can be transferred out
of a function. Every one of those capabilities is also a way to reintroduce
the bug `lock_guard` makes impossible: an early `.unlock()` call followed by
code that assumes the lock is still held is exactly the bare-`unlock()`
mistake, just spelled with an RAII type standing nearby. Reach for
`unique_lock` when you need one of its specific capabilities, not as a
habitual upgrade from `lock_guard`.

```cpp
void transfer(Account& from, Account& to, long amount) {
    std::unique_lock lock_from(from.mutex, std::defer_lock);
    std::unique_lock lock_to(to.mutex, std::defer_lock);
    std::lock(lock_from, lock_to);   // acquire both, deadlock-free
    from.balance -= amount;
    to.balance += amount;
}   // both released here, in destructor order
```

`std::scoped_lock` (C++17) is the answer to exactly the pattern above,
collapsed into one type: construct it with one or more mutexes and it
acquires all of them, using the same deadlock-avoidance algorithm
`std::lock()` uses internally, then releases all of them on destruction. For
the single-mutex case it is interchangeable with `lock_guard`; for two or
more, it replaces the `defer_lock` plus `std::lock()` dance above with a
single declaration, and it is where the next section's deadlock argument
actually lives.

## Lock Ordering and Deadlock Avoidance

The textbook deadlock needs only two mutexes and two threads. Thread one
locks `a` then `b`; thread two locks `b` then `a`; if each acquires its first
lock before either attempts its second, each now holds exactly what the
other is waiting for, and neither can proceed. Nothing about this raises an
exception, returns an error code, or sets `errno`; the two threads
stop, forever, and the only external evidence is that `/proc/<pid>/task/*/wchan`
reads the kernel's futex-parked function for every thread involved, since
Chapter 5's mechanism applies to a deadlocked wait exactly as it does to any
other one. A deadlocked program is not a failing program; it is a program
that has stopped producing observable behavior.

{% include excalidraw.html name="06-lock-ordering-deadlock" caption="Figure 6.1: the same opposing acquisition order, fatal with lock_guard and safe with scoped_lock" %}
<!-- DIAGRAM SPEC: bespoke palette cream #fdfbf7 bg, blue #4a73b8, green #5a8870, red #c0392b, orange #a06030. Upper band titled "std::lock_guard, opposing order": Thread 1 box with ordered steps "lock_guard x(a)" then "lock_guard y(b)"; Thread 2 box with ordered steps "lock_guard x(b)" then "lock_guard y(a)"; two red arrows cross between the boxes labeled "each holds what the other needs"; a red outcome box reads "deadlock -- no error, no exception, program simply stops". Lower band titled "std::scoped_lock, same opposing order": Thread 1 box "scoped_lock lock(a, b)"; Thread 2 box "scoped_lock lock(b, a)"; a green arrow loops between them labeled "try-all, back off, retry -- not argument order"; a green outcome box reads "both complete -- order does not matter to scoped_lock". -->

The two independent fixes are a global lock-ordering convention and
`std::scoped_lock`, and they solve different parts of the problem. A lock
order (always acquire the account with the lower id first, or more
generally, any total order over the mutexes a codebase uses together)
prevents the circular wait from forming in the first place, by construction:
if every thread acquires multiple locks in the same relative order, no two
threads can ever hold what the other is waiting for. The discipline this
requires is organizational rather than technical. It has to be documented,
it has to cover every place two or more mutexes are taken together, and it
has to survive code review as new call sites appear, because a single
function that acquires the pair in the wrong order breaks the invariant for
the whole program, not just for itself.

`std::scoped_lock` solves the same problem a different way: rather than
requiring every caller to agree on an order, it does not care about order at
all. Given two or more mutexes, it locks the first, then attempts the rest;
if any attempt fails, it releases everything it has acquired so far and
retries from a different starting point, using the same algorithm
`std::lock()` exposes directly. `scoped_lock(a, b)` on one thread and
`scoped_lock(b, a)` on another, run concurrently and indefinitely, cannot
deadlock each other, not "deadlock rarely" or "deadlock less often than
with `lock_guard`," but cannot, because the acquisition order the argument
list specifies is not the order the implementation actually uses.

That guarantee has a scope worth being precise about: it covers the mutexes
named in one `scoped_lock` construction. It says nothing about a thread that
holds a lock from one `scoped_lock` and then, inside that scope, constructs a
second `scoped_lock` (or a bare `lock_guard`) naming an overlapping mutex:
that reintroduces exactly the ordering problem `scoped_lock` was solving for
its own argument list. The practical rule this leaves: use `scoped_lock` for
every point in the program where two or more mutexes are acquired together,
and treat acquiring a second mutex inside a scope that already holds one,
outside of a single `scoped_lock` call naming both, as a decision that needs
the lock-ordering convention stated explicitly, in a comment or in review, or
not made at all.

## RAII Locking Discipline

A bare `mu.lock()` / `mu.unlock()` pair, with no RAII type anywhere between
them, is correct only for as long as nothing between those two calls can
throw, return, `break`, `continue`, or `goto` out of the block, a
constraint that holds today and is one refactor away from not holding
tomorrow. The function that called `transfer()` safely for two years breaks
the moment someone adds a bounds check that throws on an invalid account
in the middle of the critical section, and the mutex involved stays locked
for the rest of the process's life, silently, with no exception at the call
site that made the mistake.

This is why a bare `lock()`/`unlock()` pair, outside of the narrow cases
where `unique_lock`'s `adopt_lock` or an early-release pattern
needs it, is a legitimate finding in code review rather than a style
preference. It is not that manual locking is always wrong; it is that the
RAII types cost nothing beyond the lock and unlock calls they wrap, since the
compiler inlines the wrapper away, while removing an entire category of bug
the manual form cannot defend against by construction. A reviewer who sees `lock_guard`, `unique_lock`, or
`scoped_lock` can reason about the critical section's extent by reading the
scope; a reviewer who sees a bare `lock()` has to trace every exit path by
hand, on every future change to the function, to confirm the matching
`unlock()` still runs.

```cpp
// flagged in review: every exit path between lock() and unlock()
// has to be re-verified by hand on every future change to this function
void withdraw_unsafe(Account& acct, long amount) {
    acct.mutex.lock();
    if (amount > acct.balance) {
        throw std::runtime_error("insufficient funds");  // mutex stays locked
    }
    acct.balance -= amount;
    acct.mutex.unlock();
}

// the RAII version: the same exception now releases the lock on the way out
void withdraw(Account& acct, long amount) {
    std::lock_guard lock(acct.mutex);
    if (amount > acct.balance) {
        throw std::runtime_error("insufficient funds");
    }
    acct.balance -= amount;
}
```

The runnable version of both acquisition orders lives in
`examples/concurrency/06-lock-ordering/`.

<!-- EXAMPLE SPEC: two mutexes and two threads acquiring them in opposing order, once with std::lock_guard (reproducing the deadlock, observed via timeout(1) and /proc/<pid>/task/*/wchan reading the kernel's futex-parked function) and once with std::scoped_lock (completing a fixed number of acquisitions in opposing order with no deadlock). Docker via lgtm-docker-stack. Verified by a Lua verify.lua asserting the lock_guard run is killed by timeout with a nonzero exit, the scoped_lock run exits 0, and both wchan readings during the deadlock show every involved thread parked. -->

## Running in a container

None of the mutex family's behavior changes under a container, but the
pressure that turns a marginal lock-ordering bug into a reproducible
deadlock does. A cgroup CPU quota that throttles a container mid-critical-
section, the same mechanism the previous chapter described for futex
contention, widens the window during which a thread holding lock `a` can
be preempted before it reaches for lock `b`, which is exactly the window a
racing thread needs to grab `b` first and complete the circular wait. A
lock-ordering bug that never manifests on an unthrottled development laptop
because both acquisitions in the hot path normally happen within a few
nanoseconds of each other can become routine once the container's quota
stretches that gap to microseconds or milliseconds under load. Testing lock
ordering under a representative CPU quota, not just on bare metal, is the
practical consequence.

An induced deadlock is also easier to diagnose from outside a
container than from inside one, because the diagnostic path is procfs rather
than a debugger attached to the process. `cat /proc/<pid>/task/*/wchan` from
the host (or from a debug container sharing the target's PID namespace, via
`--pid=container:<name>` in Docker or an ephemeral debug container in
Kubernetes) works without `ptrace` permission and without a debugger image
baked into the production container, which matters because the production
image frequently has neither `gdb` nor the capability to attach one. Reading
every involved thread's `wchan` as `futex_wait` (or the kernel's equivalent
symbol) and cross-referencing which mutex addresses those threads were last
seen requesting is often enough to identify a lock-ordering violation without
ever needing a live debugger session against the container.

## Standards: C++20 / C++23 / C++26

**C++20** adds no new mutex type to this family; `mutex`, `recursive_mutex`,
`timed_mutex`, and `shared_mutex` are all C++11 or C++17 arrivals, and
`scoped_lock` is C++17. What C++20 changes is what sits naturally alongside
them: `std::jthread` and `std::stop_token` from Chapter 4 make it
straightforward to write a background updater that holds a `shared_mutex` in
exclusive mode only briefly and exits cleanly on request, a combination that
previously needed a hand-rolled stop flag threaded through the same
critical sections the lock already guarded.

**C++23** adds no new mutex type either, but `std::move_only_function`
enables a pattern this chapter's discipline argument benefits from directly:
a writer can construct a completion closure that owns non-copyable state
while holding the lock, store it in a `move_only_function`, release the lock,
and invoke the closure afterward, shrinking the critical section to exactly
the work that needs the lock, without first smuggling the closure through a
`shared_ptr` to satisfy `std::function`'s copy requirement.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
#include <shared_mutex>
#include <unordered_map>
#include <string>

class Cache {
public:
    std::string get(const std::string& key) {
        std::shared_lock lock(mu_);          // concurrent readers allowed
        auto it = map_.find(key);
        return it != map_.end() ? it->second : std::string{};
    }
    void put(std::string key, std::string value) {
        std::unique_lock lock(mu_);          // exclusive while writing
        map_[std::move(key)] = std::move(value);
    }
private:
    std::shared_mutex mu_;
    std::unordered_map<std::string, std::string> map_;
};
```

```cpp
// C++23 -- shrink the critical section with a deferred, move-only completion
#include <shared_mutex>
#include <unordered_map>
#include <functional>
#include <string>

class Cache {
public:
    void put(std::string key, std::string value) {
        std::move_only_function<void()> publish;
        {
            std::unique_lock lock(mu_);
            map_[key] = value;
            publish = [key = std::move(key), log = audit_log_.get()] {
                log->record(key);             // runs after the lock is released
            };
        }
        publish();
    }
private:
    std::shared_mutex mu_;
    std::unordered_map<std::string, std::string> map_;
    std::unique_ptr<AuditLog> audit_log_;
};
```

```cpp
// C++26 (proposed, P2530/P2545 -- RCU; not yet shipping in mainline GCC or
// clang as of this writing) -- readers take no lock at all
#include <rcu>              // proposed header name, subject to change
#include <unordered_map>
#include <string>

class Cache {
public:
    std::string get(const std::string& key) {
        std::rcu_domain::read_lock guard;    // no futex, no mutex
        auto* snapshot = snapshot_.load(std::memory_order_acquire);
        auto it = snapshot->find(key);
        return it != snapshot->end() ? it->second : std::string{};
    }
private:
    std::atomic<std::unordered_map<std::string, std::string>*> snapshot_;
};
```

**C++26** carries forward the same hazard-pointer and RCU proposals
(P2530, P2545) from the previous chapter, and here they read as a direct
alternative to `shared_mutex` for the read-mostly case: an RCU-protected
reader never calls `lock_shared()` and never touches the futex path at all,
at the cost of writers working against snapshots rather than mutating shared
state in place. As with the futex chapter's note, this is proposed and
experimental: no mainline compiler ships it, and `shared_mutex` remains the
standard, available answer for reader/writer splitting until it does.

## What we learned

- `std::mutex` is the default; `recursive_mutex` is for unavoidable
  re-entrant locking, `timed_mutex` is for bounded-wait acquisition, and
  `shared_mutex` is for read-heavy state where concurrent readers are worth
  a more expensive lock operation.
- RAII lock types tie lock lifetime to scope lifetime, so an exception or
  early return cannot leave a mutex held: a failure mode a bare
  `lock()`/`unlock()` pair cannot defend against by construction.
- `lock_guard` is minimal and non-movable by design; `unique_lock` adds
  deferred locking, early release, and move support, each of which can
  reintroduce the bug `lock_guard` prevents if used carelessly.
- The textbook two-mutex deadlock produces no error, no exception, and no
  return code: only `/proc/<pid>/task/*/wchan` from outside the process
  shows every thread parked on the kernel's futex-wait path.
- A global lock-ordering convention prevents the circular wait from forming;
  `std::scoped_lock` solves the same problem without requiring one, by
  trying all its mutexes and backing off on failure rather than locking in
  argument order.
- `scoped_lock`'s deadlock-avoidance guarantee covers the mutexes in one
  construction; acquiring an additional mutex inside a scope that already
  holds one still needs an explicit order.
- A cgroup CPU quota can turn a marginal lock-ordering bug into a routine
  deadlock by widening the preemption window between two acquisitions;
  testing under a representative quota, not just on bare metal, matters.
