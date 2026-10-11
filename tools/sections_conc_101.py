"""
sections_conc_101.py -- slide content for the C++ CONCURRENCY 101 deck
("The Modern C++ Concurrency Toolkit").

A code-heavy tour of the C++20/23/26 concurrency toolkit for practicing C++
developers: threads and cooperative cancellation, mutexes and lock types,
coordination primitives, atomics and the memory model, lock-free structures,
futures and coroutines, async runtimes, fibers, parallel algorithms, and
thread pools. Twelve sections, one per source chapter (04 through 15).

Same schema and renderer as the shared engine (tools/build-pptx.py). Colors
and fonts come from the engine's own C/F/FontFam tokens (loaded here via the
same importlib trick the entry script uses) so this content module stays in
the house palette rather than inventing its own.

Slide kinds used here: content-code (primary), diagram, stat-row.
Code is taken from the book's _docs chapters, trimmed to fit the engine's
code-block budget (<=28 lines, ~70 cols).
"""
import importlib.util
from pathlib import Path

TOOLS = Path(__file__).resolve().parent


def _load_bp():
    spec = importlib.util.spec_from_file_location(
        "build_pptx", TOOLS / "build-pptx.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


bp = _load_bp()
C, F, FontFam = bp.C, bp.F, bp.FontFam

DIAGRAMS = Path("/tmp/diagrams-png")


def d(name: str) -> str:
    return str(DIAGRAMS / f"{name}.jpg")


def para(text, size=F.BODY, bold=False, italic=False,
         color=C.TEXT_DARK, bullet=False, space_before=None):
    p = dict(text=text, size=size, bold=bold, italic=italic,
              color=color, bullet=bullet)
    if space_before is not None:
        p["space_before"] = space_before
    return p


def bullet(text, size=F.BODY_SMALL, color=C.TEXT_DARK):
    return dict(text=text, size=size, bold=False, color=color, bullet=True)


def heading(text, size=F.BODY_LARGE, color=None):
    return dict(text=text, size=size, bold=True, color=color or C.TEXT_DARK)


SECTIONS = [

# ============================================================================
# Section 1 -- Threads and Cooperative Cancellation (ch. 04)
# ============================================================================
{
    "num": 1,
    "label": "§1",
    "title": "Threads and Cooperative Cancellation",
    "tagline": "std::jthread closes the one gap in std::thread that actually caused outages: the forgotten join.",
    "divider_notes": (
        "This section opens the toolkit tour with the thread type most code "
        "should reach for by default: std::jthread. The spine of the section "
        "is one contrast -- a std::thread destroyed while still joinable "
        "calls std::terminate(), while a jthread's destructor requests a "
        "stop and joins, unconditionally, with no way to opt out short of "
        "detaching first.\n\n"
        "The gotcha to land before the code: stop_token is cooperative. A "
        "thread parked in a blocking syscall or an untimed condition-"
        "variable wait never notices request_stop(). The standards delta is "
        "C++20 for the whole mechanism; C++23 only widens what a jthread can "
        "own via move_only_function."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "jthread: the destructor does the join",
            "body": [
                heading("The problem jthread closes", color=C.ACCENT_RED),
                bullet("std::thread, destroyed while still joinable, calls std::terminate() -- no unwind, nothing"),
                bullet("Every early return and every exception is a live grenade if the matching join() is missed"),
                bullet("jthread's destructor requests a stop, then joins -- unconditionally, on every exit path"),
                para("A function with five return paths needs five matching "
                     "joins with std::thread. It needs none with jthread.",
                     size=F.BODY_SMALL, italic=True, color=C.TEXT_MUTED,
                     space_before=F.BODY_SMALL),
            ],
            "code": """#include <thread>
#include <stop_token>
#include <chrono>
#include <atomic>

void worker(std::stop_token tok,
            std::atomic<long>& loops) {
    while (!tok.stop_requested()) {
        loops.fetch_add(1, std::memory_order_relaxed);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
}

void run_cooperative() {
    std::atomic<long> loops{0};
    std::jthread t(worker, std::ref(loops));
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
}
// ~jthread(): request_stop() then join() -- every path is safe""",
            "notes": (
                "What the code shows: worker polls a stop_token instead of a "
                "hand-rolled atomic<bool> flag. The jthread owns a "
                "stop_source internally and threads a stop_token into the "
                "callable's first parameter automatically -- nothing in "
                "run_cooperative() calls request_stop() or join() by hand, "
                "and the destructor does both when the scope ends.\n\n"
                "The gotcha: cancellation here is cooperative. The worker "
                "only stops because it polls stop_requested() in its own "
                "loop. A thread blocked in read(2), or waiting on a "
                "condition variable with no timeout, never notices a "
                "request_stop() call no matter how many times it's made -- "
                "stop_token does not interrupt a blocking syscall, and does "
                "not claim to.\n\n"
                "Standards delta: std::jthread, stop_token, stop_source, and "
                "stop_callback all arrive together in C++20. Nothing in "
                "C++23 or the C++26 draft changes this contract."
            ),
        },
        {
            "kind": "content-code",
            "title": "Cancellation that owns non-copyable state",
            "body": [
                heading("What changes by standard", color=C.ACCENT_PURPLE),
                bullet("C++20: the whole mechanism above -- jthread, stop_token, stop_source, stop_callback"),
                bullet("C++23: no new cancellation API -- move_only_function widens what a jthread's callable can own"),
                bullet("C++26 (proposed, P2300): inplace_stop_source trades jthread's heap-allocated state for stack-resident state in a sender pipeline"),
                para("A std::function could not hold a closure that owns a "
                     "unique_ptr without smuggling it through a shared_ptr "
                     "first. move_only_function drops that requirement.",
                     size=F.BODY_SMALL, italic=True, color=C.TEXT_MUTED,
                     space_before=F.BODY_SMALL),
            ],
            "code": """// C++23: move_only_function widens what a jthread can run
void run_with_owned_state(std::unique_ptr<int> state) {
    std::move_only_function<void(std::stop_token)> task =
        [state = std::move(state)](std::stop_token tok) {
            while (!tok.stop_requested()) {
                *state += 1;
            }
        };
    std::jthread t(std::move(task));   // std::function can't hold this
}   // same destructor contract as before: request_stop() then join()""",
            "notes": (
                "What the code shows: the callable captures a unique_ptr by "
                "move, something std::function's copy-constructibility "
                "requirement would have forced into a shared_ptr workaround. "
                "move_only_function has no such requirement, so the closure "
                "stores directly.\n\n"
                "The gotcha: this is an ergonomics change, not a new "
                "cancellation primitive. The stop_token contract -- poll it, "
                "it never interrupts a blocking call -- is identical to the "
                "previous slide.\n\n"
                "Standards delta, stated precisely: C++26's proposed "
                "std::execution introduces inplace_stop_source and "
                "inplace_stop_token as a lower-level sibling -- the state "
                "lives wherever its owner places it instead of behind an "
                "atomically refcounted heap allocation, at the cost of a "
                "stricter lifetime contract (the source must outlive every "
                "token derived from it). As of this writing no mainline "
                "compiler ships a complete std::execution implementation; "
                "the ordinary stop_token path remains the one to use."
            ),
        },
        {
            "kind": "diagram",
            "title": "jthread's owned stop_source",
            "diagram": d("04-jthread-stop-token"),
            "caption": "Figure 4.1 -- jthread's owned stop_source, the stop_token handed to the worker, and the destructor's automatic request_stop-then-join",
            "notes": (
                "What the diagram shows: a jthread owns a stop_source "
                "internally and hands a stop_token to the worker via "
                "get_token(). The destructor fires two ordered steps -- "
                "request_stop() on the source, then join() waiting on the "
                "worker -- and both happen whether or not the caller ever "
                "calls either by hand.\n\n"
                "The gotcha: compare the dashed box on the side. A plain "
                "std::thread that is still joinable when its destructor "
                "runs goes straight to std::terminate(), with no unwind. "
                "jthread is not a performance optimization over thread; it "
                "is a correctness fix for exactly this failure mode.\n\n"
                "Standards delta: this entire diagram is C++20 vocabulary. "
                "Nothing in C++23 or C++26 changes the shape of it; C++26's "
                "inplace_stop_source (previous slide) is a different type "
                "with the same request_stop()/stop_requested() contract, "
                "not a replacement for what's drawn here."
            ),
        },
        {
            "kind": "content-code",
            "title": "detach() gives up the join",
            "body": [
                heading("Ownership follows the join discipline", color=C.ACCENT_BLUE),
                bullet("A detached thread's captured references dangle the moment the spawning frame returns"),
                bullet("No destructor is left anywhere to catch the mistake -- it crashes somewhere unrelated, later"),
                bullet("jthread's blocking destructor makes the frame's lifetime visibly bound the thread's lifetime"),
                para("Reviewing a thread's captures and reviewing its join "
                     "discipline are the same review.",
                     size=F.BODY_SMALL, italic=True, color=C.TEXT_MUTED,
                     space_before=F.BODY_SMALL),
            ],
            "code": """// detach(): nothing is left to wait for the thread
void start_worker_unsafe() {
    int local = 42;
    std::thread t([&local] { use(local); });
    t.detach();
}   // local destroyed here -- t may already be reading freed memory

// jthread: the destructor blocks until the worker finishes
void start_worker_safe() {
    int local = 42;
    std::jthread t([&local] { use(local); });
}   // the frame cannot unwind until t's destructor returns""",
            "notes": (
                "What the code shows: identical capture-by-reference in "
                "both functions. The only difference is detach() versus "
                "jthread's implicit join on scope exit, and that difference "
                "is the entire gap between a dangling reference and a "
                "correct program.\n\n"
                "The gotcha: detach() severs the connection outright -- the "
                "object becomes non-joinable immediately, and nothing in the "
                "program retains a way to wait for the thread, cancel it, or "
                "learn when it exits. In service code, where a shutdown path "
                "is supposed to be clean, detach() is close to never the "
                "right call.\n\n"
                "Standards delta: none specific to detach()/join() across "
                "C++20/23/26. The practical fix this chapter recommends -- "
                "prefer jthread so the join happens whether or not the "
                "author remembered to ask for it -- is a C++20-and-later "
                "habit, not a new language feature on its own."
            ),
        },
    ],
},

# ============================================================================
# Section 2 -- The Futex Underneath the Mutex (ch. 05)
# ============================================================================
{
    "num": 2,
    "label": "§2",
    "title": "The Futex Underneath the Mutex",
    "tagline": "An uncontended lock never enters the kernel; a contended one costs two orders of magnitude more.",
    "divider_notes": (
        "This section explains what std::mutex actually is on Linux: a "
        "32-bit word plus one syscall, futex(2), that the kernel touches "
        "only when two threads collide over it. Every lock reduces to a "
        "single compare-and-swap; only a lost compare-and-swap falls back "
        "to asking the kernel to park the thread.\n\n"
        "The gotcha to land: glibc's default std::mutex does not spin in "
        "userspace before calling into the kernel -- that's "
        "PTHREAD_MUTEX_ADAPTIVE_NP, not the default. Most contended "
        "acquisitions still avoid the syscall because critical sections are "
        "short enough that the lock is usually free again by the time a "
        "second thread's CAS runs. The standards delta is C++20's "
        "atomic<T>::wait/notify, which gives the futex a portable name."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "One word, one syscall, two paths",
            "body": [
                heading("futex: fast userspace mutex", color=C.ACCENT_BLUE),
                bullet("A free lock is one atomic cmpxchg -- no syscall, no mode switch, no scheduler involvement"),
                bullet("Only a lost compare-and-swap calls futex(FUTEX_WAIT), parking the thread on a kernel wait queue"),
                bullet("On unlock: no waiter means a plain store, still in user space; a waiter means futex(FUTEX_WAKE)"),
                para("lock_guard, unique_lock, and scoped_lock all bottom "
                     "out at this same word -- none of them add a second "
                     "mechanism underneath.",
                     size=F.BODY_SMALL, italic=True, color=C.TEXT_MUTED,
                     space_before=F.BODY_SMALL),
            ],
            "code": """std::atomic<int> flag{0};
std::jthread waiter([&] {
    flag.wait(0);          // futex(FUTEX_WAIT) while flag == 0
    process(flag.load());
});
flag.store(7);
flag.notify_one();         // futex(FUTEX_WAKE) if anyone is parked
waiter.join();""",
            "notes": (
                "What the code shows: wait(0) reads as 'sleep while the "
                "value is still 0' -- the FUTEX_WAIT contract with the "
                "syscall plumbing removed. The expected value travels with "
                "the wait request specifically so the kernel can re-check it "
                "atomically against the act of sleeping, which is what "
                "closes the lost-wakeup race.\n\n"
                "The gotcha: condition_variable, std::latch, std::barrier, "
                "std::counting_semaphore, and atomic::wait/notify all reduce "
                "to this same pair of calls on Linux. They look like five "
                "facilities; underneath, a thread that must sleep until "
                "another thread acts has exactly one way to be descheduled, "
                "and that way is always a syscall.\n\n"
                "Standards delta: C++20 gives this mechanism a portable "
                "name directly -- atomic<T>::wait/notify_one/notify_all. "
                "C++23 adds no new blocking primitive; the synchronization "
                "toolkit was essentially complete after C++20."
            ),
        },
        {
            "kind": "diagram",
            "title": "Fast path, slow path",
            "diagram": d("05-futex-fast-slow-path"),
            "caption": "Figure 5.1 -- one lock word, two paths: the uncontended compare-exchange never leaves user space; only a lost compare-exchange descends into the kernel",
            "notes": (
                "What the diagram shows: the upper band is entirely user "
                "space -- a single cmpxchg instruction acquiring a free "
                "lock. The lower band is the kernel, entered only after a "
                "lost compare-exchange, via FUTEX_WAIT and, on unlock, "
                "FUTEX_WAKE.\n\n"
                "The gotcha: the footer note matters more than it looks -- "
                "'uncontended: compare-exchange succeeds, nothing below this "
                "line runs.' The instinct that 'locks are expensive, "
                "minimize them' measures the wrong variable. Adding a mutex "
                "to data touched by more than one thread, if contention is "
                "rare, costs one atomic instruction and one cache line, not "
                "a syscall.\n\n"
                "Standards delta: this fast/slow split is the Linux futex "
                "implementation underneath std::mutex since C++11; nothing "
                "in C++20/23/26 changes the mechanism. C++26's proposed "
                "hazard pointers and RCU (next section) are the first "
                "standard mechanism that lets a reader skip this path "
                "entirely for read-mostly structures."
            ),
        },
        {
            "kind": "stat-row",
            "title": "Uncontended vs. contended, by the shape",
            "stats": [
                ("1", "futex call across 200,000 uncontended\nlock/unlock pairs -- matches the no-mutex baseline", C.ACCENT_BLUE),
                ("~2,360", "futex calls once those same 200,000\nincrements are split across 8 threads sharing one mutex", C.ACCENT_RED),
                (">100x", "the typical gap between uncontended and\ncontended futex counts -- the shape holds, not any one run's number", C.ACCENT_ORANGE),
            ],
            "notes": (
                "What the numbers show: an uncontended run's futex call "
                "count matches a program with no mutex at all -- both show "
                "exactly one futex call, and it belongs to the dynamic "
                "loader's process startup, not to any lock operation. "
                "Splitting the same work across eight threads sharing one "
                "mutex pushes the count into the low thousands.\n\n"
                "The gotcha: measure the shape of the comparison, not a "
                "single run's exact count. Contended futex counts are "
                "scheduling-dependent and will differ run to run on "
                "identical hardware -- 'more than two orders of magnitude "
                "between uncontended and contended' holds up every time; "
                "the precise figure from one run does not belong in a test "
                "assertion or a mental model.\n\n"
                "Standards delta: none here -- this is a measurement of "
                "glibc's pthread_mutex implementation on Linux, unchanged by "
                "any C++ standard. What C++20 adds is the portable name "
                "(atomic::wait/notify) for the same underlying syscalls."
            ),
        },
    ],
},

# ============================================================================
# Section 3 -- Mutexes, RAII Locks, and Lock Ordering (ch. 06)
# ============================================================================
{
    "num": 3,
    "label": "§3",
    "title": "Mutexes, RAII Locks, and Lock Ordering",
    "tagline": "scoped_lock doesn't require every caller to agree on an order -- it doesn't care about order at all.",
    "divider_notes": (
        "This section covers the mutex family (mutex, recursive_mutex, "
        "timed_mutex, shared_mutex), the RAII wrapper types built on top of "
        "them, and the two independent fixes for the textbook two-mutex "
        "deadlock: a global lock-ordering convention, and std::scoped_lock's "
        "try-all-and-back-off algorithm.\n\n"
        "The gotcha to land: scoped_lock's deadlock-avoidance guarantee "
        "covers the mutexes named in one construction. It says nothing "
        "about a thread that holds a lock from one scoped_lock and then "
        "acquires a second one, separately, inside that scope. The "
        "standards delta here is mostly about what sits alongside locking "
        "-- jthread for clean shutdown, move_only_function for a smaller "
        "critical section."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "scoped_lock: order stops mattering",
            "body": [
                heading("The mutex family, briefly", color=C.ACCENT_BLUE),
                bullet("mutex: the default -- non-recursive, exclusive, cheap when uncontended"),
                bullet("recursive_mutex: only for call graphs that re-enter the same lock"),
                bullet("timed_mutex: bounded-wait acquisition when a thread must make forward progress"),
                bullet("shared_mutex: concurrent readers, exclusive writers -- measure before assuming it wins"),
            ],
            "code": """void transfer(Account& from, Account& to, long amount) {
    std::scoped_lock lock(from.mutex, to.mutex);
    from.balance -= amount;
    to.balance += amount;
}   // both released here; argument order does not matter

// scoped_lock(a, b) on one thread and scoped_lock(b, a) on another,
// run concurrently and indefinitely, cannot deadlock each other --
// not "rarely," but cannot, because the order in the argument list
// is not the order the implementation actually acquires in.""",
            "notes": (
                "What the code shows: two accounts locked together through "
                "one scoped_lock construction. Given two or more mutexes, "
                "scoped_lock locks the first, attempts the rest, and if any "
                "attempt fails, releases everything acquired so far and "
                "retries -- the same algorithm std::lock() exposes directly.\n\n"
                "The gotcha: this guarantee's scope is narrow. It covers "
                "the mutexes named in one scoped_lock call. A thread that "
                "holds a lock from one scoped_lock and then, inside that "
                "scope, acquires a second mutex outside of a single call "
                "naming both, has reopened the exact ordering problem "
                "scoped_lock was solving for its own argument list.\n\n"
                "Standards delta: scoped_lock is C++17, not new to this "
                "book's C++20-and-later window. What C++20 adds alongside "
                "it is jthread and stop_token, which make a background "
                "updater holding a shared_mutex briefly in exclusive mode "
                "straightforward to shut down cleanly."
            ),
        },
        {
            "kind": "content-code",
            "title": "RAII locking is not a style preference",
            "body": [
                heading("A bare lock()/unlock() pair is a finding", color=C.ACCENT_RED),
                bullet("Correct only until the first exception, early return, or break between the two calls"),
                bullet("A lock_guard, unique_lock, or scoped_lock costs nothing beyond lock/unlock -- the compiler inlines it away"),
                bullet("A reviewer can reason about a critical section's extent by reading the scope, not tracing every exit by hand"),
            ],
            "code": """// flagged in review: every exit path must be re-checked by hand
void withdraw_unsafe(Account& acct, long amount) {
    acct.mutex.lock();
    if (amount > acct.balance) {
        throw std::runtime_error("insufficient funds");
    }
    acct.balance -= amount;
    acct.mutex.unlock();   // never reached if the throw fires
}

// the RAII version: the same exception now releases the lock
void withdraw(Account& acct, long amount) {
    std::lock_guard lock(acct.mutex);
    if (amount > acct.balance) {
        throw std::runtime_error("insufficient funds");
    }
    acct.balance -= amount;
}""",
            "notes": (
                "What the code shows: the only difference between the two "
                "functions is an RAII wrapper. withdraw_unsafe() locks "
                "forever, silently, the moment a bounds check throws between "
                "lock() and unlock() -- a mistake invisible at the call "
                "site that introduced it.\n\n"
                "The gotcha: this works today and is one refactor away from "
                "not working. The function that called this safely for two "
                "years breaks the moment someone adds a throwing check "
                "inside the critical section. A bare lock()/unlock() pair, "
                "outside the narrow cases unique_lock's adopt_lock "
                "needs, is a legitimate code-review finding, not a style "
                "preference.\n\n"
                "Standards delta: C++23's move_only_function lets a writer "
                "build a completion closure owning non-copyable state while "
                "holding the lock, store it, release the lock, and invoke "
                "the closure afterward -- shrinking the critical section to "
                "exactly the work that needs the lock."
            ),
        },
        {
            "kind": "diagram",
            "title": "Two locks, opposing order",
            "diagram": d("06-lock-ordering-deadlock"),
            "caption": "Figure 6.1 -- the same opposing acquisition order, fatal with lock_guard and safe with scoped_lock",
            "notes": (
                "What the diagram shows: the upper band is the textbook "
                "deadlock -- thread one locks a then b, thread two locks b "
                "then a, each ends up holding what the other needs. Nothing "
                "raises an exception or sets errno; the threads stop "
                "producing observable behavior, forever.\n\n"
                "The gotcha: a deadlocked program is not a failing program "
                "in any sense a monitoring system typically catches. The "
                "only external evidence is every involved thread's "
                "/proc/<pid>/task/*/wchan reading the kernel's futex-parked "
                "function, from chapter 5's mechanism applied to a stuck "
                "wait exactly as it applies to any other one.\n\n"
                "Standards delta: the lower band's fix, scoped_lock, is "
                "C++17. The other fix -- a documented, total lock order -- "
                "is organizational, not a language feature, and has to "
                "survive code review as new call sites appear across every "
                "standard version."
            ),
        },
    ],
},

# ============================================================================
# Section 4 -- Coordination Primitives (ch. 07)
# ============================================================================
{
    "num": 4,
    "label": "§4",
    "title": "Coordination Primitives",
    "tagline": "A mutex answers who may touch this data; a coordination primitive answers has this happened yet.",
    "divider_notes": (
        "This section covers condition_variable's predicate idiom, C++20's "
        "latch (single-use countdown) and barrier (reusable phased "
        "rendezvous with a completion function), and counting_semaphore for "
        "bounding concurrency without a mutex's ownership discipline.\n\n"
        "The gotcha to land up front: a bare cv.wait(lk) with no predicate "
        "compiles, runs, and fails intermittently in production, because "
        "spurious wakeups are part of the specified contract, not an edge "
        "case to defend against. All four primitives in this section are "
        "C++20 arrivals with no C++17 fallback worth reimplementing."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "The predicate form is not optional",
            "body": [
                heading("wait() has no memory of its own", color=C.ACCENT_RED),
                bullet("A bare wait(lk) can return with no call to notify_one() or notify_all() -- a spurious wakeup"),
                bullet("The predicate loop re-checks state under the lock on every wake and on first entry"),
                bullet("notify_one() wakes one waiter; notify_all() is required when the predicate differs per waiter"),
            ],
            "code": """std::unique_lock lk(m);
cv.wait(lk, [&] { return ready; });   // re-checks under the lock

// equivalent, spelled out:
while (!ready) {
    cv.wait(lk);
}""",
            "notes": (
                "What the code shows: wait's predicate overload reacquires "
                "the lock before testing the predicate, loops back to sleep "
                "if it's still false, and returns holding the lock once it's "
                "true. It also absorbs a second hazard beyond spurious "
                "wakeup -- a notification that arrives before the waiter has "
                "even started waiting is not lost, because the predicate "
                "check at the top of the loop catches the already-true "
                "state on first entry.\n\n"
                "The gotcha: the predicate must read state protected by the "
                "same mutex the lock holds. A condition variable is purely a "
                "wakeup channel layered over state tracked separately -- it "
                "remembers nothing on its own.\n\n"
                "Standards delta: C++20 adds condition_variable_any's "
                "stop_token-aware overload, wait(lock, stop_token, "
                "predicate), which returns early on a cooperative stop "
                "request without hand-rolling a cancellation flag alongside "
                "the data predicate."
            ),
        },
        {
            "kind": "content-code",
            "title": "latch and barrier: one-shot vs. reusable",
            "body": [
                heading("Two shapes of rendezvous", color=C.ACCENT_GREEN),
                bullet("std::latch: single-use countdown -- spent once it hits zero, no reset"),
                bullet("std::barrier: reusable, phased -- the count resets automatically after each round"),
                bullet("barrier's completion function runs exactly once per phase, after everyone arrives and before anyone is released"),
            ],
            "code": """std::latch startup_done(3);

auto worker = [&](int id) {
    initialize_subsystem(id);
    startup_done.count_down();
    startup_done.wait();   // all three finish before any proceeds
    run_subsystem(id);
};

std::barrier sync_point(num_workers, [] {
    merge_phase_results();   // once per phase, before release
});""",
            "notes": (
                "What the code shows: latch for a one-time rendezvous -- "
                "'wait for N subsystems to finish initializing' -- and "
                "barrier for a loop where the same group of threads "
                "rendezvous once per phase, repeatedly. The completion "
                "function is barrier's distinguishing feature: it's the "
                "natural place to merge per-thread partial results or swap "
                "double-buffered state.\n\n"
                "The gotcha: reinventing either from a raw condition_"
                "variable and a hand-counted integer gets right the first "
                "time and wrong the second time a phase "
                "count changes. arrive_and_drop() lets a thread leave a "
                "barrier's group permanently without blocking the rest on a "
                "count it can no longer satisfy.\n\n"
                "Standards delta: both are C++20, with no C++17 "
                "equivalent. C++23 changed nothing in their public "
                "interface; several implementations tightened the "
                "underlying futex-wait paths, which needs no source change "
                "to benefit from."
            ),
        },
        {
            "kind": "content-code",
            "title": "counting_semaphore: permits, not ownership",
            "body": [
                heading("No owning thread", color=C.ACCENT_ORANGE),
                bullet("Any thread may release(), including one that never called acquire() -- a mutex forbids that"),
                bullet("A counting_semaphore bounds concurrency directly: up to N, where a mutex only ever bounds to 1"),
                bullet("No FIFO fairness is guaranteed -- build an explicit queue if acquisition order matters"),
            ],
            "code": """std::counting_semaphore<8> connection_slots(8);

void handle_request() {
    connection_slots.acquire();
    struct ReleaseGuard {
        std::counting_semaphore<8>& sem;
        ~ReleaseGuard() { sem.release(); }
    } guard{connection_slots};
    do_work_with_bounded_concurrency();
}""",
            "notes": (
                "What the code shows: eight threads can be inside "
                "do_work_with_bounded_concurrency() at once; the ninth "
                "blocks in acquire() until one of the eight releases. A "
                "mutex can only express up to 1 -- this expresses up to 8, "
                "with no owning-thread discipline to get in the way of a "
                "producer releasing permits a different consumer acquired.\n\n"
                "The gotcha: on Linux, the fast path is a lock-free atomic "
                "decrement; only the blocking path touches the futex, the "
                "same two-tier design as std::mutex. The LeastMaxValue "
                "template parameter is a hint for a cheaper internal "
                "representation, not a runtime ceiling -- release() calls "
                "past it are still well-defined within the type's range.\n\n"
                "Standards delta: counting_semaphore and binary_semaphore "
                "(an alias for counting_semaphore<1>) are both C++20. The "
                "rule of thumb for the whole section: 'may I touch this "
                "data' means mutex; 'has this happened yet' means one of "
                "these three."
            ),
        },
        {
            "kind": "content",
            "title": "Choosing the right primitive",
            "body": [
                heading("A decision guide", color=C.ACCENT_BLUE),
                bullet("Wait for a state change, re-check under a lock -> condition_variable (predicate form)"),
                bullet("Wait for N one-time events, then proceed -> std::latch"),
                bullet("Repeated phased rendezvous across a fixed group -> std::barrier"),
                bullet("Bound concurrent access to a resource pool -> std::counting_semaphore"),
                bullet("Signal a single event, thread to thread -> std::binary_semaphore"),
                bullet("Protect a critical section -> std::mutex / std::shared_mutex"),
                para("Mixing the mutex question with the coordination "
                     "question produces code that works on today's "
                     "scheduler and stops working on tomorrow's.",
                     size=F.BODY_SMALL, italic=True, color=C.TEXT_MUTED,
                     space_before=F.BODY_SMALL),
            ],
            "notes": (
                "What the table shows: every primitive from this section "
                "mapped to the pattern it exists for. The dividing line that "
                "resolves most ambiguity is the question each one answers -- "
                "'may I touch this data' versus 'has this happened yet, or "
                "have enough of us arrived.'\n\n"
                "The gotcha: two anti-patterns recur. Reinventing latch or "
                "barrier from a raw condition_variable and a counter, and "
                "using a condition_variable's bare wait() because 'this path "
                "only ever has one notifier' -- a claim usually true until a "
                "refactor adds a second one. Neither fails review by "
                "inspection; both pass until the exact interleaving that "
                "exposes them shows up on a production host months later.\n\n"
                "Standards delta: all four primitives in this table that "
                "aren't the mutex family are C++20, introduced together as "
                "one standardization wave alongside jthread. C++26 extends "
                "coordination in a different direction entirely -- lock-free "
                "reclamation (next section) -- not new rendezvous types."
            ),
        },
    ],
},

# ============================================================================
# Section 5 -- Atomics and the Memory Model (ch. 08)
# ============================================================================
{
    "num": 5,
    "label": "§5",
    "title": "Atomics and the Memory Model",
    "tagline": "Indivisibility is necessary but not sufficient -- ordering is the separate guarantee a hand-off needs.",
    "divider_notes": (
        "This section separates two guarantees that std::atomic bundles "
        "together: indivisibility (no thread observes a torn read or write) "
        "and ordering (what a memory_order argument buys relative to other "
        "memory operations). The running example is the single-producer/"
        "single-consumer ring buffer's release/acquire hand-off.\n\n"
        "The gotcha to land: on x86-64 TSO, acquire/release and relaxed "
        "both compile to a plain mov. seq_cst's extra guarantee -- one "
        "global total order every thread agrees on -- costs a locked "
        "instruction on the store side. That's a real, measurable cost "
        "under contention, not a reason to default away from seq_cst "
        "without profiling first."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "release/acquire: one happens-before edge",
            "body": [
                heading("Atomicity is not ordering", color=C.ACCENT_BLUE),
                bullet("Both operations atomic says nothing about whether the consumer sees the slot write before the counter write"),
                bullet("release on a store publishes every ordinary write before it, to any thread that later acquires the value"),
                bullet("Paired release/acquire form exactly one happens-before edge -- nothing more, nothing less"),
            ],
            "code": """// Producer (writes tail, only reads head)
buf[t % cap] = value;
tail.store(t + 1, std::memory_order_release);

// Consumer (writes head, only reads tail)
while (h == tail.load(std::memory_order_acquire)) {
    // spin: empty
}
auto v = buf[h % cap];   // sees the published write""",
            "notes": (
                "What the code shows: tail.store(..., release) publishes "
                "buf[t % cap] = value, which precedes it in program order. "
                "tail.load(..., acquire), once it observes the new value, "
                "is guaranteed to also observe that slot write. The two "
                "threads share no lock -- exactly one happens-before edge, "
                "created once per hand-off.\n\n"
                "The gotcha: relaxed on the slot values themselves would "
                "also be correct here, but only because the release/acquire "
                "pair on tail already supplies the ordering those values "
                "need. relaxed is a scalpel for a happens-before edge "
                "proved present by other means, never a default reached for "
                "because reasoning about ordering is inconvenient.\n\n"
                "Standards delta: relaxed, acquire, release, acq_rel, and "
                "seq_cst are all C++11. What's new in this book's "
                "window is C++20's atomic_ref and atomic<T>::wait/notify, "
                "covered on the next slide."
            ),
        },
        {
            "kind": "diagram",
            "title": "Three orderings, one hand-off",
            "diagram": d("08-memory-ordering"),
            "caption": "Figure 8.1 -- the same producer/consumer hand-off under three orderings: seq_cst's global total order, acquire/release's single happens-before edge, and relaxed's bare atomicity",
            "notes": (
                "What the diagram shows: the same two-thread hand-off drawn "
                "three ways. seq_cst gives every thread one agreed-on global "
                "order. acquire/release gives exactly one pairwise edge, "
                "crossing only at the store/load pair that needs it. "
                "relaxed gives atomicity with no ordering promise of its own "
                "-- correct in this diagram only because the edge above it "
                "already covers the visibility the ring buffer needs.\n\n"
                "The gotcha: seq_cst's global-order guarantee is strictly "
                "more than a two-thread hand-off needs. It subsumes "
                "acquire/release (a seq_cst store is also a release, a "
                "seq_cst load is also an acquire) plus a cross-thread "
                "agreement guarantee the ring buffer never uses.\n\n"
                "Standards delta: memory_order_consume, formally part of "
                "the standard since C++11, has been treated as a synonym "
                "for acquire by every major implementation for years and "
                "should be treated as deprecated in practice -- acquire is "
                "the weaker-than-seq_cst load ordering to reach for."
            ),
        },
        {
            "kind": "content-code",
            "title": "seq_cst's cost is on the store side",
            "body": [
                heading("What a locked instruction buys", color=C.ACCENT_ORANGE),
                bullet("x86-64 TSO already orders store-to-store and load-to-load -- release/acquire compiles to a plain mov"),
                bullet("seq_cst cannot be a plain store -- it needs a lock-prefixed instruction to drain the store buffer first"),
                bullet("Under tight contention the gap between acquire/release and seq_cst is commonly 10-20%, paid at the store"),
            ],
            "code": """// x86-64 disassembly of the ring buffer's producer:
mov    (%rax),%rdx        ; head.load(acquire)
mov    %rsi,(%rax,%rdx,8) ; buf[t % cap] = value
mov    %rsi,(%rax)        ; tail.store(t + 1, release)
// no lock, no mfence -- seq_cst would add one here

// C++20: atomic_ref makes existing storage atomic, no type change
int legacy_counter = 0;
std::atomic_ref<int> counter_ref(legacy_counter);
counter_ref.fetch_add(1, std::memory_order_relaxed);""",
            "notes": (
                "What the code shows: no lock prefix and no mfence anywhere "
                "in the disassembled producer. The release store and "
                "acquire load are both plain movs on this architecture -- "
                "the entire cost difference for seq_cst shows up as one "
                "additional locked instruction, typically xchg or an "
                "explicit mfence, on the publishing store.\n\n"
                "The gotcha: this is not an argument for defaulting to "
                "relaxed. Default to seq_cst (the type's own default) until "
                "profiling shows atomic-operation overhead on a specific hot "
                "path, then weaken it there with a comment stating which "
                "other synchronization supplies the edge the weaker "
                "ordering assumes.\n\n"
                "Standards delta: C++20 adds atomic_ref<T> (atomic access "
                "to existing, non-atomic storage you don't own the type of) "
                "and atomic<T>::wait/notify, which avoids spurious wakeups "
                "the way condition_variable does not. C++23 adds no new "
                "ordering primitive; C++26's lock-free story moves to "
                "reclamation instead, covered next."
            ),
        },
    ],
},

# ============================================================================
# Section 6 -- Lock-Free Structures and the ABA Problem (ch. 09)
# ============================================================================
{
    "num": 6,
    "label": "§6",
    "title": "Lock-Free Structures and the ABA Problem",
    "tagline": "A CAS compares a value, not a history -- and a location that cycles A to B back to A fools it completely.",
    "divider_notes": (
        "This section builds a single-producer/single-consumer ring buffer "
        "safe without a lock because each counter has exactly one writer, "
        "then shows exactly what breaks moving toward multi-producer/multi-"
        "consumer: a second writer per counter reopens compare-and-swap, "
        "and CAS reopens the ABA problem.\n\n"
        "The gotcha to land: SPSC never faces ABA structurally, not by "
        "careful coding -- its counters are monotonic for the life of the "
        "run and there is no CAS anywhere in it. The moment a second writer "
        "touches a shared location, the reclamation problem (hazard "
        "pointers or RCU) becomes necessary, and C++26 proposes to "
        "standardize both, though no compiler ships either yet."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "SPSC: one writer per counter, no lock",
            "body": [
                heading("Why no lock is needed here", color=C.ACCENT_GREEN),
                bullet("The producer writes tail and only reads head; the consumer writes head and only reads tail"),
                bullet("No location is ever written by two threads -- there's no write-write race to arbitrate"),
                bullet("Moving to multi-producer/multi-consumer breaks this at the root: tail now needs a CAS loop per push"),
            ],
            "code": """std::uint64_t t = 0;
for (std::uint64_t i = 0; i < items; ++i) {
    while (t - head.load(std::memory_order_acquire) == capacity) {
        // spin: ring full
    }
    buf[t % capacity] = i;
    ++t;
    tail.store(t, std::memory_order_release);
}""",
            "notes": (
                "What the code shows: the same release/acquire hand-off "
                "from the atomics section, turned into a persistent, "
                "reusable structure. The release store on tail publishes "
                "the slot write that precedes it, exactly as before -- this "
                "is that single hand-off, repeated.\n\n"
                "The gotcha: moving toward multi-producer/multi-consumer "
                "breaks the one-writer-per-counter property at its root. A "
                "single tail.store() no longer suffices because two "
                "producers racing to increment tail could both read the "
                "same old value and compute the same slot -- the fix is a "
                "compare-exchange_weak retry loop, which reintroduces "
                "exactly the hazard SPSC avoided by construction.\n\n"
                "Standards delta: nothing here is new to C++20/23/26 -- "
                "this is C++11 atomics applied. What's new in this chapter's "
                "window is the standardized reclamation vocabulary, covered "
                "next, for the CAS-based structures MPMC requires."
            ),
        },
        {
            "kind": "diagram",
            "title": "ABA: a value recurs, a history doesn't",
            "diagram": d("09-aba-problem"),
            "caption": "Figure 9.1 -- T1 reads head=A and computes new_head=A->next, is preempted, T2 pops A and B and pushes a new node that reuses address A, and T1's CAS succeeds against a head value that is numerically A but semantically a different stack",
            "notes": (
                "What the diagram shows: thread T1 reads head=A and "
                "computes new_head=A->next, then is preempted before its "
                "CAS runs. While suspended, T2 pops A, pops the node after "
                "it, frees A, and pushes a freshly allocated node that lands "
                "at the same address -- common allocator behavior. T1 "
                "resumes and its CAS succeeds, because head is numerically "
                "A again.\n\n"
                "The gotcha: the CAS did exactly what it was asked. It "
                "compared head against old_head and found them equal. The "
                "equality was real; the state it certified was not. "
                "new_head now points into memory T2 already popped, "
                "possibly freed -- corruption with a passing compare.\n\n"
                "Standards delta: two mitigations are standard today -- a "
                "tagged pointer pairing the pointer with a generation count, "
                "or a hazard-pointer/RCU scheme that prevents reuse rather "
                "than detecting it. C++26 proposes std::hazard_pointer and "
                "std::rcu to standardize the second family directly, "
                "labeled experimental -- no shipping compiler implements "
                "either as of this writing."
            ),
        },
        {
            "kind": "content-code",
            "title": "Reclamation, not detection",
            "body": [
                heading("The trade-off that follows from ABA", color=C.ACCENT_PURPLE),
                bullet("Hazard pointers pay on every read -- publish before dereferencing -- to keep reclamation prompt"),
                bullet("RCU pays on every delete -- a grace-period wait -- to keep reads nearly free"),
                bullet("C++26 proposes std::hazard_pointer and std::rcu; neither ships in a mainstream compiler yet"),
            ],
            "code": """// ABA-prone: a CAS compares a value, not a history
Node* old_head = head.load();
Node* new_head;
do {
    if (!old_head) return std::nullopt;
    new_head = old_head->next;
} while (!head.compare_exchange_weak(old_head, new_head));

// C++26 (proposed): hazard pointer sidesteps reclamation, not ABA
std::hazard_pointer hp = std::make_hazard_pointer();
Node* node = hp.protect(shared_atomic_ptr);
if (node) use(*node);   // safe: node can't be reclaimed while protected""",
            "notes": (
                "What the code shows: the canonical ABA-prone pop above the "
                "line, and the proposed C++26 hazard-pointer protection "
                "below it. protect() publishes the pointer into a well-"
                "known slot other threads inspect before reclaiming "
                "anything, so a thread that wants to free a node first "
                "scans every reader's slot.\n\n"
                "The gotcha: hazard pointers and RCU solve safe reclamation "
                "-- never freeing a node a reader might still dereference -- "
                "but on opposite sides of the cost ledger. A read-mostly "
                "structure (a routing table, a config snapshot) favors RCU; "
                "a structure updated and read at comparable rates, or with "
                "latency-sensitive deletes, favors hazard pointers' more "
                "predictable per-operation cost.\n\n"
                "Standards delta: both hazard_pointer and rcu are proposed "
                "for C++26 (P2530, P2545) and labeled experimental -- the "
                "interface shown reflects the proposal shape and may still "
                "change. Hand-rolled versions remain the only production "
                "option until a compiler ships either."
            ),
        },
    ],
},

# ============================================================================
# Section 7 -- Futures, Promises, and Packaged Tasks (ch. 10)
# ============================================================================
{
    "num": 7,
    "label": "§7",
    "title": "Futures, Promises, and Packaged Tasks",
    "tagline": "An unnamed std::async temporary is a hidden synchronization point -- fire-and-forget that blocks instead.",
    "divider_notes": (
        "This section covers std::async's launch policies and the default "
        "policy's surprise (the implementation may pick deferred, running "
        "on no new thread at all, until get() or wait() forces it), the "
        "promise/future pair std::async is built on, packaged_task as the "
        "usual unit of work for a hand-rolled pool, and how exceptions "
        "cross the async boundary.\n\n"
        "The gotcha to land: a future from std::async with the async "
        "policy blocks in its destructor if the task hasn't finished -- an "
        "unnamed temporary turns what reads like fire-and-forget into a "
        "blocking call with the work's name chosen to look otherwise. "
        "Nothing in this family's public interface changes across "
        "C++20/23/26; coroutines, next, exist to fix what it lacks."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "The default policy's surprise",
            "body": [
                heading("async or deferred -- the implementation chooses", color=C.ACCENT_RED),
                bullet("The default policy's only guarantee: the result is ready by the time get() returns"),
                bullet("It is not a guarantee of concurrency -- a saturated thread pool can conform by running everything deferred"),
                bullet("Pass std::launch::async explicitly whenever concurrent execution is the point"),
            ],
            "code": """// default policy: implementation picks async or deferred
std::future<int> f = std::async([] { return compute(); });
int result = f.get();   // only guarantee: ready by the time get() returns

// hidden sync point: a temporary future blocks in its destructor
std::async(std::launch::async, [] { slow_io(); });
log("submitted");   // does NOT run until slow_io() finishes""",
            "notes": (
                "What the code shows: two traps in one slide. The first is "
                "the default launch policy silently degrading three "
                "meant-to-overlap calls to fully sequential execution on a "
                "conforming implementation, with no diagnostic. The second "
                "is the temporary future's destructor -- special to "
                "std::async with the async policy -- blocking until the "
                "task completes.\n\n"
                "The gotcha: binding the result to a named variable doesn't "
                "change the second trap; the block still happens, at the "
                "variable's own destruction instead. A related trap: "
                "wait_for/wait_until on a deferred-policy future reports "
                "std::future_status::deferred forever -- polling code that "
                "treats it like timeout and retries spins indefinitely.\n\n"
                "Standards delta: none -- std::async, future, promise, "
                "packaged_task, and shared_future are all pre-C++20 and "
                "unchanged through the C++26 draft. What changes is the "
                "vocabulary around them, starting with coroutines next."
            ),
        },
        {
            "kind": "content-code",
            "title": "promise/future is the general primitive",
            "body": [
                heading("What std::async is built on", color=C.ACCENT_BLUE),
                bullet("Reach for promise/future directly when the producer isn't a callable you launch through std::async yourself"),
                bullet("packaged_task wraps a callable so invoking it routes the return (or exception) into its own future automatically"),
                bullet("packaged_task is itself callable -- the usual unit of work for a hand-rolled pool, which std::async can't be"),
            ],
            "code": """std::promise<int> prom;
std::future<int> fut = prom.get_future();
std::thread producer([p = std::move(prom)]() mutable {
    p.set_value(do_work());
});
int value = fut.get();
producer.join();

std::packaged_task<int(int,int)> task(
    [](int a, int b) { return a + b; });
std::future<int> fut2 = task.get_future();
std::thread worker(std::move(task), 3, 4);
int sum = fut2.get();   // 7
worker.join();""",
            "notes": (
                "What the code shows: promise/future split std::async's two "
                "halves -- describing the work and running it -- apart, "
                "which is what lets the producing side be a thread pool, a "
                "hardware callback, or any execution context std::async's "
                "interface doesn't reach. packaged_task then wraps a "
                "callable so it's both invocable and carries its own "
                "future, which is why it's the building block for hand-"
                "rolled pools rather than std::async.\n\n"
                "The gotcha: each std::launch::async call is free to spawn "
                "a new OS thread, and a tight loop issuing "
                "thousands of them can exhaust the process thread limit, "
                "surfacing as std::system_error from std::async itself. A "
                "fixed-size pool consuming packaged_tasks caps OS threads "
                "at the pool's size regardless of task volume.\n\n"
                "Standards delta: none in this family's interface across "
                "C++20/23/26 -- same shape since C++11."
            ),
        },
        {
            "kind": "content-code",
            "title": "Exceptions cross the boundary intact",
            "body": [
                heading("One hop, no continuation", color=C.ACCENT_ORANGE),
                bullet("The producer's exception is stored in shared state and rethrown, intact, at the consumer's first get()"),
                bullet("shared_future::get() returns const T& and can be called repeatedly from multiple threads"),
                bullet("No .then(), no combinator for 'whichever finishes first' -- chaining means blocking the chaining thread on get()"),
            ],
            "code": """std::future<int> f = std::async(std::launch::async,
    [] () -> int { throw std::runtime_error("failed"); });

try {
    f.get();   // rethrows here, on the calling thread, at first get()
} catch (const std::runtime_error& e) {
    log(e.what());
}

// shared_future: many waiters, const T& on every get()
std::shared_future<Config> cfg = prom2.get_future().share();
auto worker = [cfg] { use(cfg.get()); };   // callable repeatedly""",
            "notes": (
                "What the code shows: the same exception object, not a "
                "serialized description of it, crosses the thread boundary "
                "and surfaces exactly once, at the first get(). "
                "shared_future rethrows a copy of the stored exception at "
                "each caller's own get(), so every waiter observes the same "
                "failure.\n\n"
                "The gotcha: if no one ever calls get(), the exception is "
                "never observed at all -- there is no equivalent of an "
                "uncaught-exception-on-a-detached-thread crash for a future "
                "nobody collected. This model is sufficient for one async "
                "operation with one eventual result, and strained by "
                "almost anything more structured than that.\n\n"
                "Standards delta: this one-hop exception model is unchanged "
                "across C++20/23/26. C++20's coroutines (next section) keep "
                "the same exception-propagation guarantee while removing "
                "the blocking get() -- co_await is a non-blocking "
                "continuation over the identical contract."
            ),
        },
    ],
},

# ============================================================================
# Section 8 -- Coroutines in Depth (ch. 11)
# ============================================================================
{
    "num": 8,
    "label": "§8",
    "title": "Coroutines in Depth",
    "tagline": "HALO is a permission the standard grants, not a guarantee any particular compiler exercises.",
    "divider_notes": (
        "This section walks the compiler-generated coroutine machinery: "
        "the frame, promise_type, and the await_ready/await_suspend/"
        "await_resume triad; symmetric transfer, which keeps a long chain "
        "of resumptions from growing the stack; HALO, the heap-allocation "
        "elision the standard permits but never guarantees; C++23's "
        "std::generator; and the lifetime trap around references held past "
        "a suspension point.\n\n"
        "The gotcha to land hardest: a coroutine is the one place a "
        "function body can outlive the call that started it, which makes a "
        "reference parameter unsafe in a way it never is in an ordinary "
        "function. The standards delta is C++20 for the whole machinery, "
        "C++23 for std::generator, and C++26's proposed senders/receivers "
        "as the eventual composition answer."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "promise_type: the customization point",
            "body": [
                heading("What the compiler needs from you", color=C.ACCENT_BLUE),
                bullet("Any function containing co_await, co_yield, or co_return is a coroutine, rewritten into a state machine"),
                bullet("get_return_object() builds the value the caller actually receives from calling the coroutine"),
                bullet("initial_suspend()/final_suspend() decide whether the body starts and ends immediately or stays suspended"),
            ],
            "code": """struct Task {
    struct promise_type {
        Task get_return_object() {
            return Task{std::coroutine_handle<promise_type>
                        ::from_promise(*this)};
        }
        std::suspend_always initial_suspend() noexcept { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        void return_void() {}
        void unhandled_exception() { std::terminate(); }
    };
    std::coroutine_handle<promise_type> handle;
};""",
            "notes": (
                "What the code shows: the nested promise_type the compiler "
                "looks up via std::coroutine_traits on the coroutine's "
                "return type. The storage holding locals, the current "
                "suspension point, and bookkeeping is the coroutine frame -- "
                "almost always heap-allocated, and never a type you write "
                "or take sizeof of directly.\n\n"
                "The gotcha: unhandled_exception() runs from inside a catch "
                "block the compiler generates around the whole body, if the "
                "coroutine throws and never catches internally. Getting "
                "this wrong (calling std::terminate() here, as shown, "
                "versus storing the exception for later rethrow) is a "
                "design decision this type has to make explicitly.\n\n"
                "Standards delta: co_await, co_yield, co_return, "
                "promise_type, and coroutine_handle all ship in C++20 with "
                "no standard-library coroutine type at all -- a Task like "
                "this must be hand-written, which every coroutine tutorial "
                "does before it hands you a coroutine body."
            ),
        },
        {
            "kind": "content-code",
            "title": "await_suspend and symmetric transfer",
            "body": [
                heading("The three-call protocol", color=C.ACCENT_GREEN),
                bullet("await_ready, await_suspend, await_resume -- in that order, every co_await"),
                bullet("await_suspend hands an external source a handle to resume later -- the bridge to a reactor or a scheduler"),
                bullet("Returning a handle instead of calling .resume() is a tail call -- no stack frame accumulates across a long chain"),
            ],
            "code": """struct ReadAwaitable {
    Reactor& reactor;
    int fd;
    bool await_ready() noexcept { return false; }
    void await_suspend(std::coroutine_handle<> h) {
        reactor.wait_readable(fd, h);   // parks h
    }
    void await_resume() noexcept {}
};

// symmetric transfer: return a handle, don't call .resume() yourself
std::coroutine_handle<> await_suspend(
        std::coroutine_handle<promise_type> h) noexcept {
    auto c = h.promise().continuation;
    return c ? c : std::noop_coroutine();
}""",
            "notes": (
                "What the code shows: ReadAwaitable hands the reactor a "
                "handle and returns, blocking no one, while the reactor "
                "calls .resume() on it later. The second function shows "
                "symmetric transfer -- returning a coroutine_handle from "
                "await_suspend instead of calling .resume() directly, which "
                "the compiler performs as a jump rather than a nested call.\n\n"
                "The gotcha: a naive 'resume the awaiter directly' "
                "implementation grows the call stack by one frame per link "
                "in a chain of coroutines awaiting each other -- exactly "
                "the shape a coroutine pipeline produces, and it overflows "
                "despite every function having long since 'returned' in the "
                "coroutine sense.\n\n"
                "Standards delta: both the awaitable protocol and symmetric "
                "transfer are C++20 language features, unchanged through "
                "C++23 and the C++26 draft -- std::noop_coroutine() is the "
                "handle to use when there's nothing left to resume."
            ),
        },
        {
            "kind": "diagram",
            "title": "HALO: permitted, not guaranteed",
            "diagram": d("11-halo-permission-not-guarantee"),
            "caption": "Figure 11.1 -- HALO is a permission, not a guarantee: identical source at an identical optimization level can allocate on one toolchain and elide entirely on another, both conforming",
            "notes": (
                "What the diagram shows: the standard's wording in "
                "[dcl.fct.def.coroutine] is 'may,' not 'shall' -- a license "
                "granted to the optimizer when it can prove a frame's "
                "lifetime is bounded by the call, exercised at the "
                "optimizer's discretion. The lower band shows two compilers "
                "disagreeing on the easiest possible elision case, at the "
                "same source and the same optimization level.\n\n"
                "The gotcha: 'the optimizer will remove it' is a claim "
                "about a toolchain, not the language. It compiles cleanly, "
                "passes every test, and is wrong only in its performance "
                "model. The only way to know what a given toolchain does is "
                "to measure it -- overload operator new inside promise_type "
                "and count calls.\n\n"
                "Standards delta: HALO's wording is unchanged from C++20 "
                "through the current C++26 working draft. Frame size is a "
                "function of what's live across a suspension point, not a "
                "flat overhead, which is a separate fact from whether the "
                "allocation happens at all."
            ),
        },
        {
            "kind": "content-code",
            "title": "std::generator and the lifetime trap",
            "body": [
                heading("C++23 standardizes the generator", color=C.ACCENT_PURPLE),
                bullet("An infinite co_yield loop consumed finitely by views::take is not a leak -- destroying it runs destructors in scope"),
                bullet("coroutine_handle owns nothing -- only a wrapper's destructor calling .destroy() frees the frame"),
                bullet("A reference parameter used after a suspension point can dangle -- the caller may have returned by then"),
            ],
            "code": """std::generator<std::uint64_t> fibonacci() {
    std::uint64_t a = 0, b = 1;
    while (true) {
        co_yield a;
        const std::uint64_t next = a + b;
        a = b; b = next;
    }
}
for (auto v : fibonacci() | std::views::take(10)) use(v);

// lifetime trap: a reference outliving the call that produced it
Task use_dangling_ref(const std::string& name) {
    co_await something();   // suspends; caller may now return
    log(name);               // UB if the caller's `name` is gone
}""",
            "notes": (
                "What the code shows: an infinite Fibonacci generator "
                "consumed through ten values and then destroyed mid-"
                "co_yield -- well-defined, not a leak. The second function "
                "shows the lifetime trap: a plain function's reference "
                "parameter is safe because the function runs to completion "
                "before the caller can destroy its locals; a coroutine is "
                "the one place that invariant breaks.\n\n"
                "The gotcha: nothing about co_await warns you when the "
                "caller's local goes out of scope before the coroutine "
                "resumes and reads it. The rule that generalizes: anything "
                "needed after the first suspension point must be owned by "
                "the frame (by value, or a moved local), not borrowed from "
                "a caller the coroutine has no visibility into.\n\n"
                "Standards delta: std::generator<T> is C++23, "
                "standardizing the most common hand-rolled coroutine type "
                "from C++20 code. C++26's proposed std::execution senders "
                "and receivers answer composition -- chaining, combining, "
                "cancelling -- layered on top of this unchanged machinery, "
                "not replacing it."
            ),
        },
    ],
},

# ============================================================================
# Section 9 -- Async Runtimes and Event Loops (ch. 12)
# ============================================================================
{
    "num": 9,
    "label": "§9",
    "title": "Async Runtimes and Event Loops",
    "tagline": "A mutex blocks a thread; a strand defers a handler -- correct either way, reaching the kernel far less often.",
    "divider_notes": (
        "This section puts the previous section's ReadAwaitable on a real "
        "epoll reactor, then covers Boost.Asio's io_context (whose run() "
        "returns immediately on no outstanding work, not on 'done'), the "
        "work guard that keeps it alive, and the strand as an executor that "
        "serializes handlers without a lock.\n\n"
        "The gotcha to land: a handler is not thread-safe merely because "
        "Asio handed it to you. The same handler body is race-free under "
        "one io_context shape and a live data race under another, and the "
        "only thing that changed is how many threads called run(). "
        "C++26's proposed scheduler/sender vocabulary generalizes what's "
        "already here rather than replacing it."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "epoll_wait resumes the exact handle",
            "body": [
                heading("The whole reactor", color=C.ACCENT_BLUE),
                bullet("EPOLLONESHOT disarms a descriptor the instant it fires -- exactly one resume per readiness event"),
                bullet("The run loop's h.resume() is a plain function call into the frame -- nothing about the thread blocks on it"),
                bullet("One epoll instance, one map from fd to handle, and a resume call -- no thread pool, no scheduler abstraction"),
            ],
            "code": """void Reactor::wait_readable(int fd, std::coroutine_handle<> h) {
    waiters_[fd] = h;
    epoll_event ev{};
    ev.events = EPOLLIN | EPOLLONESHOT;
    ev.data.fd = fd;
    ::epoll_ctl(epfd_, EPOLL_CTL_ADD, fd, &ev);
}

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
}""",
            "notes": (
                "What the code shows: the previous section's "
                "ReadAwaitable::await_suspend meets the kernel here. "
                "waiters_[fd] is the map from a watched descriptor back to "
                "the exact coroutine frame parked on it; the run loop's "
                "single epoll_wait call blocks one thread until at least "
                "one watched descriptor is ready, then resumes exactly "
                "those coroutines.\n\n"
                "The gotcha: await_resume() stays void here -- nothing "
                "about resumption tells the coroutine anything happened; "
                "the actual bytes come from calling recv again once "
                "resumed, which is why the retry loop lives in the "
                "coroutine body, not the awaitable.\n\n"
                "Standards delta: epoll and EPOLLONESHOT are Linux kernel "
                "features, not C++ standard ones -- nothing here changes "
                "across C++20/23/26. What C++20 contributes is the "
                "coroutine machinery this reactor is wired into, from the "
                "previous section."
            ),
        },
        {
            "kind": "content-code",
            "title": "io_context: a refcount, not a loop you wrote",
            "body": [
                heading("run() returns on no work, not on done", color=C.ACCENT_RED),
                bullet("A freshly constructed io_context has nothing queued -- run() returns the moment it finds no outstanding work"),
                bullet("executor_work_guard is a claim against that refcount, independent of whether any work has been posted yet"),
                bullet("Releasing the guard is how a program tells its io_context threads to drain and exit, without cutting off work mid-flight"),
            ],
            "code": """asio::io_context ioc;
auto guard = asio::make_work_guard(ioc);
asio::post(ioc, [&guard] {
    do_startup_work();
    guard.reset();   // release the claim; run() may now return
});
std::thread t([&ioc] { ioc.run(); });   // blocks until reset()""",
            "notes": (
                "What the code shows: a work guard taken before anything "
                "is posted, so a lull with zero connections in flight -- "
                "zero outstanding work, by the io_context's own accounting "
                "-- doesn't make run() walk off the end of the thread "
                "that's supposed to keep serving.\n\n"
                "The gotcha: a hand-rolled reactor's lifetime is the while "
                "loop you wrote; an io_context's lifetime is a refcount on "
                "pending operations, and that refcount can legitimately hit "
                "zero before the async work you meant to start has even "
                "been posted. A server accepting connections for its whole "
                "lifetime typically holds a guard for exactly that long.\n\n"
                "Standards delta: Boost.Asio's own API tracked this "
                "without waiting for the standard -- co_spawn/awaitable/"
                "use_awaitable already express C++20's coroutine column in "
                "shipping code years ahead of any standard networking "
                "facility reaching the same point."
            ),
        },
        {
            "kind": "content-code",
            "title": "A strand defers; a mutex blocks",
            "body": [
                heading("Serialization without a lock", color=C.ACCENT_GREEN),
                bullet("Handlers posted through a strand never run concurrently with each other, no matter how many threads call run()"),
                bullet("An unsynchronized counter, incremented 2,000 times by 8 threads through a strand, lands on exactly 2,000, every time"),
                bullet("Posted straight to the io_context instead, the same counter comes back short -- only the executor changed"),
            ],
            "code": """asio::strand<asio::io_context::executor_type>
    strand(ioc.get_executor());
long counter = 0;   // deliberately unsynchronized
for (int i = 0; i < 2000; ++i) {
    asio::post(strand, [&counter] { ++counter; });
}
// 8 threads drain the queue: counter == 2000, every time
// a mutex blocks a thread; a strand defers a handler instead""",
            "notes": (
                "What the code shows: a strand wraps another executor with "
                "one guarantee -- handlers posted through it serialize "
                "regardless of how many threads service the underlying "
                "io_context. A contended std::mutex falls back to "
                "futex(FUTEX_WAIT) and parks a thread that someone has to "
                "wake; a strand never puts a thread to sleep at all -- a "
                "handler that can't run right now is queued, and the thread "
                "that would have run it goes back to pick up other work.\n\n"
                "The gotcha: a strand's guarantee is narrower than it "
                "sounds -- it says nothing about a thread touching the same "
                "data outside a handler, and nothing about handlers posted "
                "through a different strand. It's a serialization domain "
                "for one piece of shared state, not a blanket lock over the "
                "whole program.\n\n"
                "Standards delta: strand and io_context are Asio library "
                "concepts, not standard C++. C++26's proposed std::"
                "execution generalizes the executor/strand vocabulary into "
                "schedulers and senders -- additive, not a replacement, and "
                "not yet implemented by any shipping compiler."
            ),
        },
    ],
},

# ============================================================================
# Section 10 -- Fibers and Stackful Coroutines (ch. 13)
# ============================================================================
{
    "num": 10,
    "label": "§10",
    "title": "Fibers and Stackful Coroutines",
    "tagline": "Cost and capability move together: a thread's stack, a fiber's stack, and a coroutine's frame, in that order.",
    "divider_notes": (
        "This section contrasts stackful fibers (boost::fiber, each with a "
        "real stack and cooperative user-space scheduling) against the "
        "previous sections' stackless coroutines, whose state lives in a "
        "compiler-sized heap frame. The motivating problem is function "
        "coloring: a suspending function infects every caller above it, "
        "and a fiber sidesteps that by never asking the compiler for "
        "anything.\n\n"
        "The gotcha to land: a fiber buys the ability to suspend from "
        "inside foreign, non-rewritable blocking code -- at a real, "
        "measured memory cost between a thread's stack and a coroutine's "
        "frame. No C++ standard through the C++26 draft provides a "
        "stackful-coroutine type."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "Suspend from an ordinary function",
            "body": [
                heading("Sidestepping function coloring", color=C.ACCENT_BLUE),
                bullet("co_await only ever suspends the coroutine that contains it -- a non-coroutine link anywhere breaks the chain"),
                bullet("A fiber's context switch is a handful of registers saved to one stack and restored from another, in user space"),
                bullet("Yielding never asks the compiler for anything -- it works inside code the compiler has never heard of"),
            ],
            "code": """void leaf() {
    boost::this_fiber::yield();   // suspend from an ORDINARY function
}

void middle(int depth) {
    if (depth == 0) leaf();
    else middle(depth - 1);       // five ordinary stack frames deep
}

// called from the fiber's own entry function:
middle(5);""",
            "notes": (
                "What the code shows: neither leaf() nor middle() is a "
                "coroutine in any sense the compiler recognizes -- neither "
                "contains co_await. yield() works anyway, because it asks "
                "boost::context to save the current stack pointer and "
                "registers and switch to a different stack, a mechanism "
                "with no idea what function it was standing in.\n\n"
                "The gotcha: this is the entire difference from a "
                "stackless coroutine -- it can suspend only "
                "where the compiler built a state machine to suspend from; "
                "a fiber can suspend anywhere a function call is legal, "
                "because suspension never touched the compiler at all.\n\n"
                "Standards delta: Boost.Fiber is not, and as of the C++26 "
                "working draft is not becoming, part of the C++ standard. "
                "There is no std::fiber in C++20, C++23, or the C++26 "
                "draft -- the cross-standard difference is how "
                "awkward the workaround for not having one is to write."
            ),
        },
        {
            "kind": "diagram",
            "title": "Three ways to pause",
            "diagram": d("13-three-ways-to-pause"),
            "caption": "Figure 13.1 -- three ways to hold a paused computation: a thread's kernel-visible stack, a fiber's user-space stack, and a coroutine's heap frame, in decreasing cost and increasing restriction on where they may suspend",
            "notes": (
                "What the diagram shows: three orders of magnitude apart "
                "at each step -- a thread stack of several MiB, a fiber "
                "stack around a hundred-odd KiB, a coroutine frame from "
                "tens of bytes up to whatever it carries live across a "
                "suspension. Many fibers fit in one thread's stack; many "
                "coroutine frames fit in one fiber's stack.\n\n"
                "The gotcha: that ordering is directionally solid, not a "
                "constant to memorize -- the same caution HALO raised. A "
                "fiber earns its stack specifically where the call chain "
                "between the suspension point and the fiber's entry is "
                "deep, or where part of it is foreign code with no natural "
                "co_await points -- a vendor library, a recursive parser, a "
                "blocking C API.\n\n"
                "Standards delta: none of these three facilities changed "
                "shape across C++20/23/26 -- the ordering in this figure "
                "describes current mainstream toolchains, worth checking on "
                "your own rather than trusting as a fixed number."
            ),
        },
        {
            "kind": "content-code",
            "title": "The guard page, and the scheduler choice",
            "body": [
                heading("One page of determinism", color=C.ACCENT_RED),
                bullet("protected_fixedsize_stack maps one extra PROT_NONE page -- an overrun faults immediately instead of corrupting silently"),
                bullet("round_robin never migrates a fiber off its creating thread -- a lock-free programming model between yields"),
                bullet("shared_work spreads fibers across threads for parallelism, and makes thread_local a latent migration bug"),
            ],
            "code": """boost::context::protected_fixedsize_stack alloc(65536);
// 65536 usable bytes + one PROT_NONE guard page

boost::fibers::use_scheduling_algorithm<
    boost::fibers::algo::shared_work>();
// a fiber can now resume on a different thread than it suspended on""",
            "notes": (
                "What the code shows: a stack allocator with a guard page, "
                "and the one-line scheduler switch from round_robin to "
                "shared_work. A fiber that stays inside its allotted "
                "bytes never touches the guard; one that recurses past the "
                "end walks straight into the PROT_NONE mapping and faults "
                "immediately, SIGSEGV at the exact overrun, rather than "
                "corrupting whatever page sits next.\n\n"
                "The gotcha: the guard buys determinism about when an "
                "overflow is caught, not protection against every way a "
                "stack can be mis-sized -- a single frame larger than one "
                "page can step clean over it. And migrating under "
                "shared_work means a thread_local read before yielding and "
                "after resuming can silently read two different threads' "
                "copies.\n\n"
                "Standards delta: none -- Boost.Fiber's scheduler API is "
                "library-level, with no standard equivalent through C++26. "
                "fiber_specific_ptr is Boost's answer for state that must "
                "travel with the fiber rather than the thread."
            ),
        },
    ],
},

# ============================================================================
# Section 11 -- Parallel Algorithms and Execution Policies (ch. 14)
# ============================================================================
{
    "num": 11,
    "label": "§11",
    "title": "Parallel Algorithms and Execution Policies",
    "tagline": "par_unseq may interleave iterations within one thread -- a lock inside its callable can deadlock against itself.",
    "divider_notes": (
        "This section covers the three C++17 execution policies -- seq, "
        "par, and par_unseq -- the guarantees each relaxes and what each "
        "forbids inside its callable, the parallel STL algorithms built on "
        "them, and a cost model for when converting a loop to one actually "
        "pays off.\n\n"
        "The gotcha to land: par_unseq's 'may interleave within one "
        "thread' permission makes locking or allocating inside its "
        "callable not merely slow but potentially self-deadlocking -- two "
        "iterations that need to rendezvous may be the same hardware "
        "thread, and one of them never gets a turn. seq/par/par_unseq are "
        "C++17, refined rather than introduced across C++20/23/26."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "par relaxes order; par_unseq forbids blocking",
            "body": [
                heading("What each policy permits and forbids", color=C.ACCENT_ORANGE),
                bullet("par: the callable must be safe to invoke concurrently -- a mutex inside it is perfectly legal"),
                bullet("par_unseq: the library may interleave iterations within a single thread for vectorization"),
                bullet("A lock inside a par_unseq callable can deadlock against itself -- not a race, a self-deadlock"),
            ],
            "code": """std::vector<int> data(1'000'000);
std::atomic<long> sum{0};
std::for_each(std::execution::par, data.begin(), data.end(),
              [&sum](int x) {
                  sum.fetch_add(x, std::memory_order_relaxed);
              });

// WRONG under par_unseq: a lock can deadlock against itself
std::mutex m;
std::for_each(std::execution::par_unseq, v.begin(), v.end(),
    [&](int& x) {
        std::lock_guard<std::mutex> lock(m);   // forbidden
        x = transform(x);
    });""",
            "notes": (
                "What the code shows: the par example is unremarkable -- "
                "an atomic accumulator, safe to call from multiple threads "
                "concurrently. The par_unseq example is the trap: a vector "
                "unit executing several logical iterations as one SIMD "
                "operation cannot context-switch between them the way the "
                "OS scheduler switches threads, so a lock acquired by one "
                "'iteration' may never be released by whichever other "
                "iteration is sharing its hardware thread.\n\n"
                "The gotcha: the standard's own phrasing forbids "
                "'vectorization-unsafe' operations under par_unseq -- "
                "acquiring a lock, allocating through a non-lock-free "
                "allocator, or anything else that could legally block.\n\n"
                "Standards delta: seq, par, and par_unseq are C++17, not "
                "new to this book's C++20 window -- attributing them "
                "correctly matters for the rest of this section."
            ),
        },
        {
            "kind": "content-code",
            "title": "reduce needs a weaker operation, not more threads",
            "body": [
                heading("Policy-parameterized vs. order-sensitive", color=C.ACCENT_BLUE),
                bullet("Most parallel algorithms are the sequential one plus a leading policy argument -- sort, for_each, transform"),
                bullet("reduce looks like accumulate but drops its strict left-to-right requirement -- it needs associative, usually commutative"),
                bullet("Floating-point reduce is not UB, but trades a reproducible rounding result for a different, also-valid one"),
            ],
            "code": """std::sort(std::execution::par, v.begin(), v.end());

// reduce: associative + commutative required, order not fixed
std::transform_reduce(std::execution::par,
    in.begin(), in.end(), 0.0,
    std::plus<>{}, [](double x) { return x * x; });""",
            "notes": (
                "What the code shows: transform_reduce composing map-then-"
                "fold in one pass, specifically so an implementation isn't "
                "forced to materialize the intermediate transformed range "
                "first -- the same fusion motivation range adaptors bring "
                "to sequential code.\n\n"
                "The gotcha: a parallel reduction needs the freedom to "
                "combine partial sums from different threads in whatever "
                "order they finish, so the standard requires the combining "
                "operation to be associative and commutative. Ordinary "
                "integer addition qualifies; floating-point addition does "
                "not strictly qualify, because reordering changes "
                "accumulated rounding error -- worth knowing before a test "
                "expects bit-for-bit agreement against an accumulate "
                "baseline.\n\n"
                "Standards delta: reduce, transform_reduce, and the scan "
                "algorithms are C++17. C++20's only addition to the policy "
                "set is a fourth value, unseq -- vectorization permitted, "
                "cross-thread parallelism not."
            ),
        },
        {
            "kind": "content-code",
            "title": "Parallelism pays off past a crossover",
            "body": [
                heading("N x w versus the dispatch cost c", color=C.ACCENT_PURPLE),
                bullet("A trivial per-element callable on a bandwidth-bound loop can lose to the sequential version once dispatch cost is added back"),
                bullet("The win shows up on large N with nontrivial per-element work -- not the small, tight loops a profiler flags as hot"),
                bullet("A standard library without a conforming parallel backend linked in may silently execute par as if seq had been requested"),
            ],
            "code": """// C++20 adds unseq: vectorize only, no cross-thread parallelism
std::for_each(std::execution::unseq, v.begin(), v.end(),
              [](double& x) { x = std::sqrt(x); });

// parallelism pays off once N * w comfortably exceeds the fixed
// dispatch cost c -- a single-multiply transform is bandwidth-
// bound long before it is compute-bound; measure before converting.""",
            "notes": (
                "What the code shows: unseq, C++20's one addition to the "
                "policy set, for a loop safe to auto-vectorize but whose "
                "callable is unsafe to run concurrently across threads for "
                "some unrelated reason.\n\n"
                "The gotcha: a standard library that accepts "
                "std::execution::par without a conforming parallel backend "
                "linked in (libstdc++'s is layered on a separate library) "
                "is permitted to execute the algorithm as if seq had been "
                "requested -- compiles, runs, produces a correct but "
                "non-parallel result with no diagnostic that anything was "
                "skipped.\n\n"
                "Standards delta: C++23 changes nothing about any of the "
                "four policies. C++26's proposed std::execution bulk/"
                "scheduler model is a strictly richer vocabulary layered "
                "alongside the existing policies, not a fifth policy value "
                "-- experimental, with no shipping compiler support."
            ),
        },
    ],
},

# ============================================================================
# Section 12 -- Thread Pools and Work Scheduling (ch. 15)
# ============================================================================
{
    "num": 12,
    "label": "§12",
    "title": "Thread Pools and Work Scheduling",
    "tagline": "hardware_concurrency() reports the host's hardware, not the slice the container was actually given.",
    "divider_notes": (
        "This closing section establishes a sizing rule for a thread pool "
        "from the workload rather than a guess (cores for CPU-bound work, "
        "a wait-to-compute ratio for I/O-bound work), compares a single "
        "shared queue against work-stealing deques, and makes the pool "
        "size cgroup-aware so it reflects the container's quota rather "
        "than the host's core count.\n\n"
        "The gotcha to land: a single shared queue's lock becomes the "
        "pool's throughput ceiling at scale, because every worker and "
        "producer funnels through it regardless of idle capacity "
        "elsewhere. This closes the toolkit tour before the 201 deck turns "
        "to applying all of it under a latency budget."
    ),
    "slides": [
        {
            "kind": "content-code",
            "title": "Size from the workload, not a guess",
            "body": [
                heading("Two sizing rules, one cgroup check", color=C.ACCENT_BLUE),
                bullet("CPU-bound: one thread per core the workload may actually use concurrently -- no more"),
                bullet("I/O-bound: threads ~= cores x (1 + wait_time / compute_time)"),
                bullet("hardware_concurrency() reads the host's topology, not the container's cpu.max quota -- read the cgroup first"),
            ],
            "code": """// CPU-bound: one thread per core the workload may actually use
// I/O-bound: threads ~= cores * (1 + wait_time / compute_time)

// read cpu.max before trusting hardware_concurrency()
std::ifstream f("/sys/fs/cgroup/cpu.max");
long quota, period;
f >> quota >> period;   // "max" period means unlimited
unsigned cores = quota > 0 ? quota / period
                           : std::thread::hardware_concurrency();""",
            "notes": (
                "What the code shows: the two sizing formulas from the "
                "chapter, and the cgroup v2 read that should gate "
                "hardware_concurrency() rather than replace it -- a quota "
                "of 'max' means no limit, in which case the pool should "
                "fall back to hardware_concurrency(), not treat an absent "
                "quota as zero.\n\n"
                "The gotcha: a pool sized off hardware_concurrency() on a "
                "sixty-four-core host, running inside a container capped at "
                "two cores, builds sixty-four threads' worth of pool for "
                "two cores' worth of hardware -- more time-slicing, not "
                "more throughput. Mixed workloads are usually better split "
                "into two pools sized by their own rules than compromised "
                "into one size for both.\n\n"
                "Standards delta: C++20's jthread and stop_token give a "
                "pool a cleaner worker and shutdown path -- a worker loop "
                "can thread a stop_token through its wait predicate so a "
                "shutdown wakes a thread blocked waiting for the next task."
            ),
        },
        {
            "kind": "diagram",
            "title": "Work-stealing: owner and thief, opposite ends",
            "diagram": d("15-work-stealing-deque"),
            "caption": "Figure 15.1 -- a work-stealing pool: each worker pops its own freshly pushed work from the bottom of its deque, and an idle worker steals the oldest task from the top of a busy neighbor's deque",
            "notes": (
                "What the diagram shows: each worker treats its own deque "
                "as a LIFO stack, popping the most recently pushed (and "
                "most cache-hot) task from the bottom. An idle worker steals "
                "from the opposite end, the top, taking the oldest task in "
                "a busy neighbor's queue instead.\n\n"
                "The gotcha: stealing from the far end is the design's "
                "central trick -- a thief and the owner only contend when "
                "the deque holds exactly one item, since every other access "
                "touches opposite ends. A single shared queue, by contrast, "
                "becomes a serialization point every worker and producer "
                "funnels through, capping throughput below hardware "
                "capacity at a number set by lock overhead.\n\n"
                "Standards delta: work-stealing deques (the Chase-Lev "
                "algorithm most implementations trace to) are a library and "
                "runtime pattern, not a C++ standard type. C++26's proposed "
                "std::execution exposes a thread_pool-style scheduler as "
                "the first standard vocabulary for this area."
            ),
        },
        {
            "kind": "content-code",
            "title": "A jthread pool with cooperative shutdown",
            "body": [
                heading("Join discipline, built into the pool", color=C.ACCENT_GREEN),
                bullet("The destructor is implicit -- each jthread requests a stop and joins automatically"),
                bullet("cv_.wait(lk, st, predicate) wakes on either new work or a cooperative stop request"),
                bullet("move_only_function (C++23) drops the queue element's copyability requirement the pool never actually needed"),
            ],
            "code": """class ThreadPool {
public:
    explicit ThreadPool(unsigned n) {
        for (unsigned i = 0; i < n; ++i)
            workers_.emplace_back([this](std::stop_token st) { run(st); });
    }
    void submit(std::function<void()> task) {
        { std::lock_guard lk(mtx_);
          queue_.push_back(std::move(task)); }
        cv_.notify_one();
    }
private:
    void run(std::stop_token st) {
        while (true) {
            std::unique_lock lk(mtx_);
            cv_.wait(lk, st, [&] { return !queue_.empty(); });
            if (st.stop_requested() && queue_.empty()) return;
            auto task = std::move(queue_.front());
            queue_.pop_front();
            lk.unlock();
            task();
        }
    }
    std::mutex mtx_;
    std::condition_variable_any cv_;
    std::deque<std::function<void()>> queue_;
    std::vector<std::jthread> workers_;
};""",
            "notes": (
                "What the code shows: a complete, minimal pool using only "
                "this section's own tools -- jthread for workers, a "
                "stop_token threaded through the wait predicate so a "
                "shutdown request wakes a thread that's blocked waiting for "
                "the next task rather than leaving it to notice only after "
                "another task arrives.\n\n"
                "The gotcha: before C++20, this same pool needed an "
                "explicit atomic shutdown flag every worker's loop checked, "
                "plus careful ordering between setting that flag and "
                "calling join() on each std::thread by hand -- all of that "
                "collapses into the implicit jthread destructor here.\n\n"
                "Standards delta: C++23's move_only_function (not shown) "
                "would replace this queue's std::function element type, "
                "since std::function's copy-constructibility requirement "
                "forces a task capturing a unique_ptr into an unnecessary "
                "shared_ptr wrapper nothing in the pool ever needed. C++26's "
                "proposed senders/receivers standardize scheduling itself; "
                "no mainstream standard library ships a complete "
                "implementation as of this writing."
            ),
        },
    ],
},

]
