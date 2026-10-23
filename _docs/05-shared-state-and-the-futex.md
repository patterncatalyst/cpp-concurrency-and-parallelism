---
title: "Shared State and the Futex"
order: 5
layout: tutorial
sectionid: docs
part: shared-state-and-synchronization
description: "What a mutex actually is underneath the standard library: the futex syscall, and the cost difference between an uncontended and a contended lock."
duration: "15 min"
---

<!-- PROVENANCE: SEED from linux-systems-programming/_docs/25-shared-state-and-the-futex.md | anchor books: Williams, Tanenbaum -->

## Learning objectives

By the end of this chapter you can:

- Explain what a Linux `std::mutex` actually is underneath the standard library: a 32-bit word plus the `futex(2)` syscall.
- Trace the futex fast path (a single userspace compare-and-swap) and slow path (`FUTEX_WAIT`/`FUTEX_WAKE`), and identify which one a given acquisition takes.
- Quantify the cost gap between an uncontended lock and a contended one using futex call counts and voluntary context switches.
- Distinguish kernel-space work from user-space work during lock acquisition and release.
- Account for how containerization (ptrace restrictions, cgroup CPU quotas) changes what you can observe about futex behavior without changing the mechanism itself.

## Why this matters

Most engineers carry a rule of thumb that locks are expensive, so the instinct is to minimize their use. That rule measures the wrong variable: an uncontended `std::mutex` costs one atomic instruction and ownership of one cache line, not a syscall. Understanding the futex mechanism replaces that vague caution with a precise one: contention is what is expensive, not the presence of a lock.

This matters directly for debugging and capacity planning. When a service stalls under load, knowing that only a lost compare-and-swap ever touches the kernel tells you exactly where to look: futex call counts and voluntary context switches, not a profiler guess. The same mechanism also underlies every other coordination primitive in this book, so the fast-path/slow-path split introduced here reappears, unchanged, in condition variables, latches, barriers, and semaphores.

## What we'll cover

- Show that a Linux mutex is, underneath, a fast userspace path backed by the futex syscall.
- Explain the futex fast path and slow path, and when the kernel actually gets involved.
- Quantify the cost difference between an uncontended lock acquisition and a contended one that blocks in the kernel.
- Separate what happens in kernel space from what happens in user space during lock acquisition and release.

## What a Lock Is Underneath

`std::mutex` on Linux is a thin wrapper over `pthread_mutex_t`, which is in
turn a thin wrapper over a **futex**: a 32-bit word in your process's address
space, plus exactly one syscall, `futex(2)`, that the kernel only touches when
two threads actually collide over it. The name is a contraction of "fast
userspace mutex," and the "fast" is not marketing: the entire point of the
design is that acquiring an uncontended lock never crosses into the kernel at
all.

Every lock operation reduces to a single compare-and-swap on that word. If the
word reads `0` (free), the acquiring thread atomically writes `1` and
proceeds; that one `cmpxchg` instruction executes entirely in user space, with
no mode switch and no scheduler involvement, and the kernel never learns a
lock was taken. Only when the compare-and-swap loses, because the word is
already `1` and someone else holds it, does the thread fall back to asking
the kernel to park it. `std::lock_guard`, `std::unique_lock`, and
`std::scoped_lock` all bottom out at this same word through
`pthread_mutex_lock`; none of them add a second mechanism underneath.

{% include excalidraw.html name="05-futex-fast-slow-path" caption="Figure 5.1: one lock word, two paths: the uncontended compare-exchange never leaves user space; only a lost compare-exchange descends into the kernel" %}
<!-- DIAGRAM SPEC: bespoke palette cream #fdfbf7 bg, blue #4a73b8, green #5a8870, red #c0392b, orange #a06030. Upper band labeled "user space (glibc pthread / libstdc++ std::mutex)": a green box "lock word == 0" with an arrow labeled "cmpxchg 0 -> 1 (one instruction)" into a blue box "lock held, no syscall". Lower band labeled "kernel (entered only on a lost compare-exchange)": a red box "lock word == 1, CAS fails" with an orange arrow labeled "futex(FUTEX_WAIT, &word, 1)" descending into a red "wait queue keyed by address" box; a second orange arrow labeled "futex(FUTEX_WAKE, &word)" rising from an "unlock()" box back up to the wait queue, with a dashed arrow returning the woken thread to user space. Footer note: "uncontended: compare-exchange succeeds, nothing below this line runs." -->

## The Futex: Fast Path and Slow Path

The fast path is the compare-and-swap described above, and it is worth being
precise about why it is cheap: a single atomic instruction, retiring in a few
nanoseconds, touching one cache line. No system call, no context switch, no
involvement from the scheduler. This is the path every uncontended
`lock()`/`unlock()` pair takes, and under light contention it is also the path
most *contended* acquisitions take, not because glibc's default mutex spins
in userspace before falling back (it doesn't: `std::mutex` maps to
`PTHREAD_MUTEX_NORMAL`, whose glibc implementation performs exactly one
compare-and-swap and, on failure, goes straight to `__lll_lock_wait`, the
futex path; adaptive userspace spinning is a property of
`PTHREAD_MUTEX_ADAPTIVE_NP`, which is not the default `std::mutex` uses).
Most contended acquisitions still avoid the syscall for a simpler reason:
critical sections are typically so brief that the lock is usually already
free again by the time a second thread's compare-and-swap runs.

The slow path begins only when that compare-and-swap also fails: the thread calls
`futex(FUTEX_WAIT, &word, expected)`, which asks the kernel to suspend the
calling thread on a wait queue keyed by the physical address of `word`, but
only if the word's current value still matches `expected`. That
re-check-before-sleeping is not incidental; it is what closes the **lost
wakeup** race, where a thread decides to sleep, gets preempted before it
actually parks, and the unlocking thread's wake arrives in the gap and is
lost forever. By passing the expected value into the same syscall that does
the parking, the kernel can verify the precondition and commit to sleeping as
one atomic step, with nothing before it for a stray write to slip into.

On the unlocking side, a thread that finds no one is waiting on the word
clears it and returns, still entirely in user space. Only when the
unlocking thread knows (or the futex's internal bookkeeping believes) a
waiter exists does it call `futex(FUTEX_WAKE, &word)`, which moves one parked
thread back onto the run queue. Condition variables, `std::latch`,
`std::barrier`, `std::counting_semaphore`, and `std::atomic<T>::wait`/
`notify_one` all reduce to this same pair of calls on Linux. They look like
five distinct facilities: underneath, a thread that must sleep until some
other thread acts has exactly one way to be descheduled, and that way is a
syscall, because only the kernel can take a thread off the CPU.

```cpp
std::atomic<int> flag{0};
std::jthread waiter([&] {
    flag.wait(0);              // futex(FUTEX_WAIT) while flag == 0
    process(flag.load());
});
flag.store(7);
flag.notify_one();             // futex(FUTEX_WAKE) if anyone is parked
waiter.join();
```

`wait(0)` reads as "sleep while the value is still 0," and that is the
`FUTEX_WAIT` contract with the syscall plumbing removed: the expected value
travels with the wait request specifically so the kernel can re-check it
atomically against the act of sleeping.

## Uncontended vs Contended Cost

The claim that an uncontended lock is cheap understates it. A `strace -c
-e trace=futex` across 200,000 `lock_guard` acquisitions and releases on a
single thread would show the futex call count coming back identical to a
version of the same program with no mutex at all: both report a single
`futex` call, and that one call belongs to the dynamic loader starting the
process, not to any lock operation. The full syscall profile of such an
uncontended run is on the order of sixty calls total: `execve`, `mmap`,
`openat`, `read`, and `close`, every one of them process startup. Two
hundred thousand lock/unlock pairs contribute nothing measurable to it.

Split the same 200,000 increments across eight threads sharing one mutex, and
the picture changes by more than two orders of magnitude. The futex count
rises into the low thousands, varying run to run with scheduling (one
reference measurement put it at 2,360), because now the compare-and-swap
fails often enough to send threads into the kernel to sleep and
wake each other. Breaking that count down by operation shows the mechanism
described above actually at work: in that same reference measurement, only
on the order of a few hundred of the 200,000 lock operations under
contention ever reached an actual `FUTEX_WAIT` sleep. The rest found the
compare-and-swap already succeeding (the lock had already been released by
the time they attempted it), and never left user space at all. Contention
raises the cost by orders of magnitude and the kernel still handles only a
small minority of the operations involved.

The number that matters here is the *shape* of the comparison, not any single
run's count; futex counts under contention are scheduling-dependent and will
differ from one run to the next on the same machine. "More than two orders of
magnitude between uncontended and contended" is a statement that holds up
every time; the exact figure from one run is not a thing to hard-code into a
test or a mental model.

What this inverts is a common instinct about locking cost. "Locks are
expensive, minimize them" measures the wrong variable. Adding a mutex to a
data structure that is touched by more than one thread only rarely does not
cost syscalls; it costs one atomic instruction and ownership of one cache
line, indistinguishable in practice from not locking at all. The accurate
version of the advice is narrower and more useful: *waiting* is expensive,
and the thing worth minimizing is contention, not the presence of a lock.

## Kernel Space vs User Space

Collecting the boundary in one place: the compare-and-swap that acquires an
uncontended lock and the compare-and-swap that releases it when no one is
waiting both run entirely in user space, touching no kernel data structure
and costing no mode switch; the default `std::mutex` does not spin in
userspace beyond that single compare-and-swap attempt before falling to the
futex path. The kernel enters the picture in exactly two
calls: `futex(FUTEX_WAIT, ...)` when a thread must sleep, and
`futex(FUTEX_WAKE, ...)` when an unlocking thread must wake one back up. Both
exist because descheduling a thread is something only the kernel's scheduler
can actually do; no amount of userspace cleverness can take a thread off a
CPU it has been given.

An independent way to see the same boundary is to count **voluntary context
switches**, which `getrusage` (and therefore `/usr/bin/time -v`) reports per
process and which the kernel also exposes live per thread under
`/proc/<pid>/task/*/status`. Every `FUTEX_WAIT` that actually parks a thread
is one voluntary context switch: the thread choosing to give up the CPU
rather than being preempted from it. An uncontended run produces a context
switch count in the low hundreds, almost entirely startup and teardown; the
same work made heavily contended across eight threads can push that count
into six figures. The scaling in context switches and the scaling in futex
calls are two measurements of one underlying fact: contention is what moves
work from user space into the kernel, and nothing else does.

The runnable version of this comparison lives in
`examples/concurrency/05-futex-cost/`.

<!-- EXAMPLE SPEC: a program that performs the same fixed number of increments three ways -- no mutex, an uncontended single-thread mutex, and the same total split across N threads sharing one mutex -- and reports the futex call count for each via strace, proving the uncontended case matches the no-mutex baseline and the contended case exceeds it by orders of magnitude. Docker via lgtm-docker-stack (strace available in the image). Verified by a Lua verify.lua asserting futex(uncontended) == futex(baseline) and futex(contended) > futex(uncontended) * 100. -->

## Running in a container

`strace`'s ability to count these calls at all depends on `ptrace`, and a
container is the one place that permission is routinely missing. A default
`docker run` grants `CAP_SYS_PTRACE` to a process tracing its own children,
but many hardened runtimes drop it, and Kubernetes' default `seccomp`
profile, plus `securityContext.allowPrivilegeEscalation: false` on a locked-down
pod, can leave `strace -f` unable to attach at all. The futex mechanism
itself is unaffected either way, since nothing about the mutex changes. Only
your ability to *watch* it from outside the process does. A verification harness
that depends on `strace` needs to detect that case and skip the gate
explicitly rather than reporting a false pass; `/proc/<pid>/task/*/wchan`
reading `futex_wait` (or an equivalent kernel symbol) while a thread is
parked is a cheaper, usually-unrestricted fallback that needs no `ptrace`
permission at all, since it is a plain read of a procfs file.

A cgroup CPU quota changes the *measured* contention without touching the
futex mechanism either. Throttle a container to a fraction of a core and a
thread that held a lock for what should have been a few hundred nanoseconds
can instead be preempted mid-critical-section when its quota runs out for
the period, stretching the window during which every other thread's
compare-and-swap fails. The futex call count goes up, the voluntary-context-
switch count goes up, and neither number is lying: contention
increased. But the cause is scheduling pressure from the quota, not a
change in the workload or the lock itself. Reading `cpu.stat`'s
`nr_throttled` and `throttled_usec` alongside a futex-count comparison is
what tells the two apart: a quota-starved container shows both climbing
together, while a workload that has grown more contended on its own shows the
futex count rising with `nr_throttled` flat at zero.

## Standards: C++20 / C++23 / C++26

**C++20** is the standard that first gives the futex a portable name in the
language itself: `std::atomic<T>::wait`, `notify_one`, and `notify_all` are a
direct, standardized expression of `FUTEX_WAIT`/`FUTEX_WAKE` on a bare atomic,
with none of the platform-specific syscall plumbing exposed. `std::latch`,
`std::barrier`, and `std::counting_semaphore` also land in C++20, and on
Linux every one of them is this same mechanism wearing a different type name:
each is a shape of "block until another thread acts," and that shape has
exactly one implementation available to it.

**C++23** adds no new blocking primitive and changes nothing about the futex
contract described above; the synchronization toolkit the standard offers was
essentially complete after C++20. What follows from that: a reader who
understands `std::atomic::wait`/`notify` and the mutex-family types already
has C++23's full vocabulary for this topic.

{% include codetabs.html langs="C++20|C++23|C++26" %}

```cpp
// C++20
#include <atomic>
#include <thread>

std::atomic<int> ready{0};

void waiter() {
    ready.wait(0);              // blocks via futex(FUTEX_WAIT) while ready == 0
}

void signaler() {
    ready.store(1);
    ready.notify_one();         // futex(FUTEX_WAKE) if a waiter is parked
}
```

```cpp
// C++23 -- identical contract; no new wait/notify primitive shipped
#include <atomic>
#include <thread>

std::atomic<int> ready{0};

void waiter() {
    ready.wait(0);              // same futex(FUTEX_WAIT) path as C++20
}

void signaler() {
    ready.store(1);
    ready.notify_one();
}
```

```cpp
// C++26 (proposed, P2530/P2545 -- hazard pointers and RCU; not yet shipping
// in mainline GCC or clang as of this writing)
#include <hazard_pointer>   // proposed header name, subject to change

int read_without_blocking(std::atomic<Node*>& head) {
    std::hazard_pointer hp = std::make_hazard_pointer();
    Node* n = hp.protect(head);   // reader never calls futex(2) at all
    return n ? n->value : -1;
}
```

**C++26** does not change the futex-backed toolkit either, but it adds a
reclamation mechanism that sidesteps it for a specific, important case:
`std::hazard_pointer` and the RCU facilities from P2530 and P2545 let a
reader traverse a shared, concurrently-mutated structure without taking any
lock and without ever reaching `futex(2)`: the protection comes from
deferring reclamation of memory a reader might still be looking at, not from
excluding other threads. This does not replace `std::mutex` for the general
case; it targets read-mostly data structures where even an uncontended
mutex's single atomic instruction, paid on every read, is one instruction too
many. As of this writing it is proposed and experimental: the header name and
exact API are not finalized, and no mainline compiler ships a complete
implementation.

## What we learned

- `std::mutex` is a futex: a 32-bit word plus one syscall the kernel touches
  only on contention. Acquiring a free lock is a single atomic
  compare-and-swap that never leaves user space.
- The fast path is the common case even under moderate contention, because
  critical sections are typically so brief that the lock is usually already
  free again by the time a second thread's compare-and-swap runs, not
  because glibc's default mutex spins in userspace before calling into the
  kernel (that's `PTHREAD_MUTEX_ADAPTIVE_NP`, not the `std::mutex` default).
- An uncontended lock's futex call count matches a program with no mutex at
  all; the cost of adding a rarely-contended mutex is one atomic instruction
  and one cache line, not a syscall.
- Contention is what crosses into the kernel: a contended lock's futex count
  and voluntary-context-switch count both rise by orders of magnitude over
  the uncontended case, even though most contended acquisitions still resolve
  in user space because the critical section was already free again by the
  time the compare-and-swap ran.
- Measure the *shape* of a comparison (orders of magnitude), not a single
  run's exact count; contended futex counts are scheduling-dependent and
  will vary between runs on identical hardware.
- `FUTEX_WAIT` re-checks the expected value as part of the same syscall that
  parks the thread, closing the lost-wakeup race; `std::atomic<T>::wait(old)`
  standardizes exactly that contract.
- `latch`, `barrier`, `counting_semaphore`, and `atomic::wait` are five type
  names for one mechanism: a thread that must sleep until notified can only
  be descheduled by the kernel, so every one of them reaches `futex(2)`.
- C++26's hazard pointers and RCU (proposed, experimental) are the first
  standard mechanism that lets a reader skip the futex entirely for
  read-mostly shared state, rather than making the futex path cheaper.
