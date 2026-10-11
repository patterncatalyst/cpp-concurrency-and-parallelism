"""
sections_conc_100.py — slide content for deck 100: "Concurrency & Parallelism:
The Mental Model."

This is the general/introductory deck: diagram-forward, light on code, aimed
at engineers new to concurrency and tech leads scoping a project. It covers
the conceptual layer the book builds on — what concurrency and
parallelism actually mean, the hardware underneath, why shared state is hard,
how to reason about correctness and latency, and where the 101 (C++ toolkit)
and 201 (low-latency) decks pick up.

Loads the shared engine (build-pptx.py) only for its color tokens (C,
FontFam), so this deck's accent colors match the house palette defined there.
build-conc-100-pptx.py is the renderer; it feeds SECTIONS into
bp.build_section_divider / bp.render_slide.

Slide kinds used here: content | stat-row. No "code" slides — this deck is
diagram-forward and C++-light by design.
"""
import importlib.util
from pathlib import Path

from pptx.util import Pt
from pptx.enum.text import PP_ALIGN

_TOOLS = Path(__file__).resolve().parent


def _load_build_pptx():
    """Load build-pptx.py (hyphenated filename) as a module, for its color
    tokens only — this module does not use the engine's slide builders
    directly (the entry script does that)."""
    spec = importlib.util.spec_from_file_location(
        "build_pptx", _TOOLS / "build-pptx.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


_bp = _load_build_pptx()
C = _bp.C
FontFam = _bp.FontFam

DG = "/tmp/diagrams-png"  # converted JPGs live here


def dg(name):
    return f"{DG}/{name}.jpg"


def para(text, size=Pt(16), bold=False, italic=False,
         color=C.TEXT_DARK, bullet=False, align=PP_ALIGN.LEFT,
         space_before=None):
    d = dict(text=text, size=size, bold=bold, italic=italic,
              color=color, bullet=bullet, align=align)
    if space_before is not None:
        d["space_before"] = space_before
    return d


def bullet(text, size=Pt(16), color=C.TEXT_DARK, space_before=None):
    d = dict(text=text, size=size, bold=False, color=color, bullet=True)
    if space_before is not None:
        d["space_before"] = space_before
    return d


def heading(text, size=Pt(18), color=None):
    return dict(text=text, size=size, bold=True, color=color or C.TEXT_DARK)


SECTIONS = [

# ============================================================================
# §1 — Concurrency vs Parallelism
# ============================================================================
{
    "num": 1,
    "label": "§1",
    "title": "Concurrency vs Parallelism",
    "tagline": "Structure and execution are independent axes — and most sizing mistakes come from conflating them.",
    "divider_notes": (
        "This is the single most confused pair of words in the field, and the "
        "confusion costs real engineering time. Concurrency is a property of "
        "how a program is structured: how many units of work are outstanding "
        "at once. Parallelism is a property of how the machine executes it: "
        "how many of those units run at the same instant, on more than one "
        "core. Nothing requires the two to move together, and this section "
        "builds the shared vocabulary needed to keep them "
        "separate."
    ),
    "slides": [
        {
            "kind": "stat-row",
            "title": "Four Execution Models",
            "stats": [
                ("4", "execution models formed by crossing structure and execution", C.ACCENT_BLUE),
                ("0", "cores needed to be fully concurrent on a single CPU", C.ACCENT_GREEN),
                ("1", "statement can saturate every core with no visible task structure", C.ACCENT_CYAN),
                ("2", "independent questions behind every sizing decision", C.ACCENT_PURPLE),
            ],
            "notes": (
                "Four numbers to open the deck. Four execution models fall out "
                "of crossing two axes, not two models — sequential, concurrent "
                "alone, parallel alone, and both at once, and every one of them "
                "is a real, common shape of code. Zero cores beyond one are "
                "needed for a program to be fully concurrent: many tasks can "
                "queue and take turns on a single CPU, and that is still "
                "concurrency. A single statement, such as a standard-library "
                "call with an execution policy, can put every core on the box "
                "to work while reading as sequential code with no thread "
                "anywhere in sight. And underneath every sizing decision in "
                "this book sit two separate questions: how much independent "
                "work structure does the program need, and how much hardware "
                "is actually available to run it on."
            ),
        },
        {
            "kind": "content",
            "title": "The Execution Model Grid",
            "body": [
                heading("Structure and hardware, crossed", color=C.ACCENT_BLUE),
                bullet("Sequential — one task, one core, neither axis engaged"),
                bullet("Concurrent, not parallel — many tasks, deliberately pinned to one core"),
                bullet("Parallel, not concurrent — one logical operation, fanned across cores by the runtime"),
                bullet("Concurrent and parallel — more tasks than cores, unpinned, the ordinary shape of load"),
                para("Lock contention lives on the concurrency axis even when "
                     "both threads sit on the same core and never run in parallel for an instant.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("01-execution-models"),
            "notes": (
                "This grid is the vocabulary everything later in the book "
                "reaches for. Sequential is the baseline nobody argues about. "
                "Concurrent-not-parallel is structure with the hardware taken "
                "away on purpose — several runnable tasks pinned to one core, "
                "still taking turns. Parallel-not-concurrent is the opposite: "
                "almost no task structure visible in the source, yet every "
                "core on the box is busy, because the runtime supplied the "
                "parallelism without the caller writing any concurrent code "
                "at all. The fourth cell, both at once, is what an "
                "oversubscribed thread pool under real load actually looks "
                "like. The point worth landing here: sizing a thread pool is "
                "a parallelism decision, and deciding how many requests a "
                "handler can have outstanding is a concurrency decision — "
                "treating them as the same request is how a service ends up "
                "with far more threads than it has cores for."
            ),
        },
        {
            "kind": "content",
            "title": "Permission vs Outcome",
            "body": [
                heading("What the machine allows is not what it did", color=C.ACCENT_GREEN),
                bullet("hardware_concurrency() and sched_getaffinity report a permission"),
                bullet("Only sampling where threads actually ran reports an outcome"),
                bullet("A permission is not an outcome, and conflating them hides capacity-planning bugs inside what looks like a concurrency bug"),
                bullet("Measure execution with counts whose sign is stable across runs — distinct CPUs touched, an in-flight high-water mark — rather than wall-clock duration"),
            ],
            "notes": (
                "The core habit this slide tries to install: a core count or "
                "an affinity mask tells a program what it is allowed to do, "
                "never what it actually did. Only sampling which CPU a thread "
                "ran on, repeatedly across a run, tells you the outcome. "
                "Timing one execution model against another with a stopwatch "
                "is tempting and usually misleading, because wall-clock "
                "duration is sensitive to frequency scaling and whatever else "
                "is scheduled on the box at that moment. The fix the book "
                "uses throughout is to assert on counts that are reproducible "
                "in sign even when they are not reproducible in magnitude — "
                "how many distinct cores got touched, how many tasks were in "
                "flight at once. That habit of reaching for an observable "
                "outcome instead of a reported permission reappears every "
                "time a container or an orchestrator sits between the code "
                "and the hardware it assumes it has."
            ),
        },
    ],
},

# ============================================================================
# §2 — The Machine Underneath
# ============================================================================
{
    "num": 2,
    "label": "§2",
    "title": "The Machine Underneath",
    "tagline": "A core is not an interchangeable unit — it has siblings, a cache hierarchy, and a scheduler that charges for every handoff.",
    "divider_notes": (
        "Every later chapter talks about locks and atomics as if the machine "
        "were a uniform pool of execution units, and it isn't. A core shares "
        "its cache and execution ports with a sibling thread, sits at a "
        "measurably different distance from different banks of memory, and "
        "gets handed to another thread by a scheduler that charges real "
        "cycles for the privilege. None of that is optional background — it "
        "is why a correct, well-locked program can still run several times "
        "slower than it should, with every tool reporting no contention at "
        "all."
    ),
    "slides": [
        {
            "kind": "content",
            "title": "Cache Hierarchy and Coherence",
            "body": [
                heading("The 64-byte line, not the variable, is the unit", color=C.ACCENT_BLUE),
                bullet("L1 near 4 cycles, L2 near 12, shared L3 near 40, DRAM 100–300"),
                bullet("MESI keeps a cache line's copies consistent across cores — Modified, Exclusive, Shared, Invalid"),
                bullet("A write to a shared line invalidates every other core's copy of that line"),
                bullet("False sharing: two unrelated variables on one 64-byte line pay full cross-core traffic with no shared variable and no lock in sight"),
            ],
            "diagram": dg("02-cache-hierarchy-mesi"),
            "notes": (
                "The latency numbers matter less than the shape: roughly two "
                "orders of magnitude separate an L1 hit from a DRAM miss, and "
                "the coherence protocol that keeps caches consistent across "
                "cores operates on a 64-byte line, not on the variable a "
                "programmer declared. That distinction is what makes false "
                "sharing possible and hard to see: two threads can write to "
                "two variables that are logically unrelated, and if those "
                "variables happen to land on the same cache line, every write "
                "from either side invalidates the other's copy of the whole "
                "line. Nothing in the source code suggests contention, "
                "because there is no shared variable and no lock — the "
                "collision is physical, not logical, and a profiler that "
                "counts cache misses without attributing them to a struct "
                "layout can miss it entirely."
            ),
        },
        {
            "kind": "content",
            "title": "The Cost of a Switch",
            "body": [
                heading("Cheap to switch, expensive to resume", color=C.ACCENT_ORANGE),
                bullet("Saving registers and the stack pointer costs tens to a few hundred nanoseconds — cheap"),
                bullet("The real cost is indirect: the outgoing thread's cache working set gets evicted"),
                bullet("The incoming thread resumes into a cold cache and pays a string of misses it would not have paid otherwise"),
                bullet("End to end, a switch commonly costs low single-digit microseconds — for a request handled in tens of microseconds, that is most of the latency"),
                para("isolcpus and nohz_full remove the scheduler from the decision entirely, trading idle capacity for predictable tail latency.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("02-context-switch-anatomy"),
            "notes": (
                "This is the slide that reframes what a context switch "
                "actually costs. The mechanical part — saving one thread's "
                "state and loading another's — is nearly free, on the order "
                "of a function call. What makes an unplanned switch expensive "
                "is almost entirely indirect: the incoming thread wakes up "
                "into a cold cache and has to rebuild the working set the "
                "outgoing thread just evicted, and that rebuild is paid in "
                "the following microseconds, not in the switch itself. For a "
                "service handling requests at microsecond scale, one "
                "unplanned switch mid-request can dominate the whole latency "
                "budget. That is also the motivation behind isolating a core "
                "from the scheduler's normal rotation entirely — it is a "
                "direct, mechanical answer to a cost this slide just "
                "quantified, not a vague performance tweak."
            ),
        },
    ],
},

# ============================================================================
# §3 — Time, Timers, and Deadlines
# ============================================================================
{
    "num": 3,
    "label": "§3",
    "title": "Time, Timers, and Deadlines",
    "tagline": "Every timeout bug in production traces back to the wrong clock or a budget re-applied at every hop.",
    "divider_notes": (
        "A thread waiting on a lock, a socket, or a response needs to know "
        "how long it has been waiting, and it needs that answer to stay "
        "correct even while the wall clock is being corrected underneath it. "
        "This section fixes the clock choice once and shows the deadline "
        "discipline that every later timeout, in this book and in a real "
        "service, inherits from it."
    ),
    "slides": [
        {
            "kind": "content",
            "title": "Two Clocks, One Rule",
            "body": [
                heading("steady_clock never steps; system_clock can", color=C.ACCENT_BLUE),
                bullet("system_clock is wall time, disciplined by NTP, and can move backward between two reads"),
                bullet("steady_clock counts from an unspecified epoch and guarantees t1 >= t0, always"),
                bullet("Any duration or deadline is measured on steady_clock — never on system_clock"),
                bullet("high_resolution_clock carries no steadiness guarantee; some standard libraries alias it to system_clock"),
            ],
            "diagram": dg("03-clock-taxonomy"),
            "notes": (
                "This rule is absolute: a duration or a deadline is always "
                "measured on steady_clock, never on system_clock. system_clock "
                "is wall time, and wall time gets corrected by NTP, which "
                "means it can be stepped forward or backward by the system — "
                "a stored deadline computed from system_clock can recede into "
                "the future if the clock steps backward, and a dead peer "
                "looks alive a little longer than it should. steady_clock "
                "carries exactly the guarantee a timeout needs: it never "
                "steps, only slews gently, and two reads always satisfy "
                "t1 >= t0. The quiet trap in the family is "
                "high_resolution_clock — its name implies precision, not "
                "steadiness, and on some implementations it is simply an "
                "alias for system_clock, which makes it the wrong default "
                "whenever code is measuring an interval rather than "
                "displaying a timestamp."
            ),
        },
        {
            "kind": "content",
            "title": "One Deadline, Many Hops",
            "body": [
                heading("Pass a time_point, not a duration", color=C.ACCENT_GREEN),
                bullet("A naive design gives each layer its own fixed timeout, re-applied at every hop"),
                bullet("Three nested 500 ms timeouts can silently let a request run for 1.5 seconds"),
                bullet("The fix: compute one deadline at the top of the call chain, pass the same time_point down unchanged"),
                bullet("Every hop checks the shared deadline before starting work, and fails immediately if it has already passed"),
                para("The exact discipline behind HTTP request timeouts and gRPC deadline propagation.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("03-deadline-propagation"),
            "notes": (
                "This slide is the practical payoff of the clock discipline. "
                "A request rarely stays inside one function — it calls into "
                "a connection pool, which calls into a query executor, which "
                "calls into a retry loop — and if each layer independently "
                "applies its own timeout to be careful, the caller's actual "
                "budget gets silently multiplied by however many layers are "
                "in the chain. The fix is mechanical: compute a single "
                "absolute deadline once, at the top, and hand that same "
                "time_point down through every hop instead of a duration "
                "that gets re-applied. Every hop does the same two things — "
                "check whether the deadline has already passed before doing "
                "any work, and pass the identical value further down. No hop "
                "can silently extend the total budget, and a hop that is "
                "already out of time fails fast instead of starting work it "
                "cannot finish. This is not a theoretical pattern — it is "
                "exactly what an HTTP client's request timeout and a gRPC "
                "deadline are doing underneath."
            ),
        },
    ],
},

# ============================================================================
# §4 — Shared State and Locking
# ============================================================================
{
    "num": 4,
    "label": "§4",
    "title": "Shared State and Locking",
    "tagline": "A mutex is a futex underneath — and the expensive part was never the lock, it was the wait.",
    "divider_notes": (
        "This is the section where concurrency gets hard: more "
        "than one thread touching the same memory. The goal here is "
        "conceptual, not an API tour — what a lock actually is underneath "
        "the standard library, why an uncontended lock costs almost nothing, "
        "why a contended one costs orders of magnitude more, and why a "
        "deadlock produces no error at all, only a program that silently "
        "stops."
    ),
    "slides": [
        {
            "kind": "content",
            "title": "The Futex Underneath",
            "body": [
                heading("One word, one syscall, touched only on collision", color=C.ACCENT_BLUE),
                bullet("std::mutex is a thin wrapper over a 32-bit word plus the futex syscall"),
                bullet("Acquiring a free lock is one compare-and-swap, entirely in user space — no syscall, no scheduler involvement"),
                bullet("Only a lost compare-and-swap falls back to asking the kernel to park the thread"),
                bullet("Contention is what crosses into the kernel — the presence of a lock costs almost nothing by comparison"),
            ],
            "notes": (
                "The instinct that locks are expensive and worth minimizing "
                "measures the wrong variable. An uncontended std::mutex "
                "reduces to a single atomic compare-and-swap on a 32-bit "
                "word — no system call, no mode switch, no scheduler "
                "involvement, and an uncontended run's syscall profile looks "
                "identical to a program with no mutex at all. Only when that "
                "compare-and-swap loses, because another thread already holds "
                "the word, does the thread fall back to the futex syscall and "
                "ask the kernel to park it until woken. The practical "
                "takeaway: adding a mutex to data that is rarely contended "
                "costs one instruction and ownership of one cache line, "
                "indistinguishable in practice from no lock at all. What "
                "actually costs real cycles is waiting — contention is the "
                "thing worth minimizing, not the presence of synchronization."
            ),
        },
        {
            "kind": "content",
            "title": "The Mutex Family",
            "body": [
                heading("One default, three specific trades", color=C.ACCENT_GREEN),
                bullet("mutex — exclusive, non-recursive, the default for a reason"),
                bullet("recursive_mutex — for a call graph that must re-enter the same lock, not a convenience for unclear discipline"),
                bullet("timed_mutex — bounded-wait acquisition, trading correctness-under-contention for forward progress"),
                bullet("shared_mutex — readers run concurrently, writers exclusive; a real win only once reader concurrency is real"),
                para("RAII wrapper types tie lock lifetime to scope lifetime — the lock is acquired and released by construction and destruction, not by hand.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "notes": (
                "Each family member trades away some of the default mutex's "
                "simplicity for one specific capability, and reaching for "
                "the wrong one is a common source of subtle bugs. A "
                "recursive_mutex exists for a call graph that must "
                "re-enter the same lock, not as a way to avoid thinking "
                "about who already holds it — every recursive acquisition "
                "is a place where the invariant the lock protects might "
                "already be mid-violation by the outer call. A timed_mutex "
                "trades correctness-under-contention for liveness: a server "
                "thread that would rather answer busy than block forever. A "
                "shared_mutex is the one that changes the concurrency model "
                "rather than adding a timeout, turning serialized reader "
                "traffic into parallel reads — but it is strictly "
                "more expensive per operation under light contention, so the "
                "payoff needs to be measured, not assumed. Across every "
                "member of the family, RAII wrapper types are what make the "
                "lock-forever bug structurally unreachable: the lock is tied "
                "to a scope's lifetime, not to a pair of calls a future "
                "refactor can separate."
            ),
        },
        {
            "kind": "content",
            "title": "Deadlock and Lock Ordering",
            "body": [
                heading("No error, no exception — the program just stops", color=C.ACCENT_RED),
                bullet("Thread one locks a then b; thread two locks b then a; each now holds what the other needs"),
                bullet("A deadlocked program raises nothing — the only evidence is every thread parked, visible from outside the process"),
                bullet("Fix one: a global lock-ordering convention, prevents the circular wait from forming at all"),
                bullet("Fix two: scoped_lock's try-all, back-off algorithm — it does not care what order the arguments were written in"),
            ],
            "diagram": dg("06-lock-ordering-deadlock"),
            "notes": (
                "The textbook two-mutex deadlock needs only two threads "
                "acquiring the same two locks in opposite order, and the "
                "failure mode is worth naming precisely because it is so "
                "quiet: nothing raises an exception, returns an error code, "
                "or sets a flag. The two threads simply stop, forever, and "
                "the only external evidence is that every thread involved is "
                "parked waiting on a lock, visible only by inspecting the "
                "process from outside. There are two independent fixes, and "
                "they solve the problem differently. A global lock-ordering "
                "convention prevents the circular wait from ever forming, by "
                "requiring every thread to acquire shared locks in the same "
                "relative order — an organizational discipline, not a "
                "technical one, and it has to survive code review as new "
                "call sites appear. scoped_lock solves the same problem a "
                "different way: given two or more mutexes, it locks the "
                "first, attempts the rest, and backs off and retries from a "
                "different starting point if any attempt fails — the order "
                "the caller wrote the arguments in is not the order the "
                "implementation actually uses, so two threads naming the "
                "same two mutexes in opposite order cannot deadlock each "
                "other, not merely less often, but by construction."
            ),
        },
    ],
},

# ============================================================================
# §5 — Atomics and the Memory Model
# ============================================================================
{
    "num": 5,
    "label": "§5",
    "title": "Atomics and the Memory Model",
    "tagline": "Indivisibility and visibility are two separate guarantees, and only one of them is automatic.",
    "divider_notes": (
        "Every coordination primitive in the previous section is, "
        "underneath, built from two things: an atomic operation and a "
        "chosen ordering. This section is those two things directly — what "
        "std::atomic actually guarantees, what memory_order adds on top of "
        "that, and why the strongest ordering is not free on real hardware "
        "even though it is the easiest to reason about."
    ),
    "slides": [
        {
            "kind": "content",
            "title": "Atomic, Not Ordered",
            "body": [
                heading("Indivisible reads do not imply visible writes", color=C.ACCENT_BLUE),
                bullet("std::atomic<T> guarantees no thread ever observes a torn, partially written value"),
                bullet("A producer writes data, then writes a counter signaling it is ready — both atomic, both correct in isolation"),
                bullet("Nothing in program order alone guarantees the consumer sees the data write before it sees the counter"),
                bullet("The compiler and the CPU can reorder independent memory operations whenever the reordering is invisible to the thread that performed it"),
            ],
            "notes": (
                "This is the distinction the whole chapter turns on: "
                "atomicity and ordering are two separate guarantees, and "
                "atomicity alone does not hand you a correct handoff between "
                "threads. Consider a producer that writes a value into a "
                "slot and then writes a counter signaling the slot is ready "
                "— even if both operations are individually atomic, nothing "
                "about program order alone guarantees a consumer spinning on "
                "the counter actually sees the data write first. Both the "
                "compiler and the CPU are free to reorder independent memory "
                "operations as long as the reordering stays invisible to the "
                "thread that performed it, and a thread can never observe "
                "its own reordering by definition — the reordering only "
                "becomes visible to a different thread watching from "
                "another core, which is exactly the handoff situation this "
                "slide describes. A naive ring buffer built on plain atomic "
                "counters can exhibit this as a torn handoff that is "
                "intermittent, present only on the interleavings nobody's "
                "test happened to hit."
            ),
        },
        {
            "kind": "content",
            "title": "The Memory Order Spectrum",
            "body": [
                heading("From a global total order down to bare atomicity", color=C.ACCENT_GREEN),
                bullet("seq_cst — every operation participates in one global order every thread agrees on; the default"),
                bullet("acquire/release — one happens-before edge between exactly two threads at one synchronization point"),
                bullet("relaxed — atomicity only, correct only when some other synchronization already supplies the ordering"),
                bullet("On x86-64, acquire/release compiles to a plain move — seq_cst's extra guarantee costs a locked instruction on the store side"),
            ],
            "diagram": dg("08-memory-ordering"),
            "notes": (
                "Three points on a spectrum, each giving up guarantees for "
                "cost, or buying guarantees at a cost. Sequential "
                "consistency is the strongest and the default: every "
                "seq_cst operation in the program joins one global total "
                "order every thread agrees on, which is strictly easier to "
                "reason about than a web of pairwise edges. Acquire and "
                "release, paired, create exactly one happens-before edge "
                "between the two specific threads at the specific point "
                "where one releases and the other acquires — nothing more. "
                "Relaxed promises indivisibility and nothing about ordering "
                "relative to anything else, and is only correct when some "
                "other mechanism already supplies the edge a location needs "
                "— it is a scalpel for a proven case, never a default "
                "reached for because the ordering argument felt "
                "inconvenient. On x86-64, acquire and release ride the "
                "hardware's own store-ordering guarantee almost for free, "
                "compiling to a plain move with no lock prefix — the one "
                "place the cost shows up is a seq_cst store, which needs a "
                "locked instruction to close a gap the hardware would "
                "otherwise leave open. The practical guidance: default to "
                "seq_cst until profiling shows the ordering matters on a "
                "specific hot path, then weaken it there, with a comment "
                "stating which other synchronization supplies the edge."
            ),
        },
    ],
},

# ============================================================================
# §6 — Benchmarking Without Deception
# ============================================================================
{
    "num": 6,
    "label": "§6",
    "title": "Benchmarking Without Deception",
    "tagline": "A fast-looking number can still be a lie — warmup, coordinated omission, and percentiles are how a measurement earns trust.",
    "divider_notes": (
        "Several chapters in the book defer a performance claim to this "
        "methodology rather than to a single number, because the number "
        "depends on the host running it. The question this section answers "
        "is a prior one: when a measurement claims a path takes some number "
        "of nanoseconds, what has to be true for that claim to mean what it "
        "says."
    ),
    "slides": [
        {
            "kind": "content",
            "title": "Warmup and the Mean",
            "body": [
                heading("The first calls and the average both deceive", color=C.ACCENT_ORANGE),
                bullet("A cold first call pays allocator, branch-predictor, and cache costs a steady-state caller never pays"),
                bullet("A repeatable harness discards a fixed number of warmup iterations before the clock starts"),
                bullet("Latency distributions are heavy-tailed — the mean gets dragged toward outliers while hiding how bad the tail gets"),
                bullet("A mean of 200 ns is consistent with every call taking 200 ns, or with one call taking 160,000 ns — report a percentile instead"),
            ],
            "notes": (
                "Two separate deceptions on one slide. The first is temporal: "
                "the first several calls to almost any function are not "
                "representative of steady state, because the allocator has "
                "not carved out its arena yet, the branch predictor has not "
                "learned which way a check usually goes, and the caches are "
                "cold. A repeatable harness runs and discards a fixed number "
                "of throwaway iterations before timing anything, and the "
                "right count is the smallest one that makes reported "
                "percentiles stop drifting between runs. The second "
                "deception is statistical: latency distributions are "
                "heavy-tailed, most calls finishing in a narrow band with a "
                "small minority finishing orders of magnitude slower, and "
                "averaging those together drags the mean toward the tail "
                "while simultaneously hiding how bad the tail actually gets. "
                "A percentile answers a sharper question than a mean ever "
                "can — what latency do ninety-nine percent of calls beat — "
                "without blending the body and the tail into one misleading "
                "number."
            ),
        },
        {
            "kind": "content",
            "title": "Coordinated Omission",
            "body": [
                heading("The benchmark that forgets to measure its own stall", color=C.ACCENT_RED),
                bullet("A closed-loop timer does not start iteration N+1's clock until iteration N returns"),
                bullet("A single long stall — a page fault, a migration, a scheduler hiccup — produces exactly one recorded sample"),
                bullet("A real caller sending requests at a fixed rate experiences every request queued behind that stall"),
                bullet("The correction backfills synthetic samples for the requests the closed loop silently erased from the tail"),
            ],
            "diagram": dg("18-coordinated-omission"),
            "notes": (
                "This is the failure mode that makes an otherwise careful "
                "benchmark lie specifically about the tail, the part a "
                "reader most needs to trust. A benchmark's timed loop is "
                "almost always closed — one iteration finishes before the "
                "next starts its clock — and if one iteration stalls for a "
                "thousand times its usual cost, the closed loop records "
                "exactly one sample for that stall. A real caller sending "
                "requests at a fixed rate does not pause while that stall "
                "plays out: several more requests queue up behind it, each "
                "waiting its turn, each experiencing a delay close to the "
                "stall's own length. The closed loop did not merely "
                "under-measure the tail, it erased the part of the "
                "distribution the tail exists to describe. The correction "
                "is mechanical once the picture is clear: for every sample "
                "exceeding the expected per-operation interval, backfill "
                "synthetic samples standing in for the requests that would "
                "have queued, and the corrected percentile is always at "
                "least as large as the raw one from the same run — a cheap "
                "sanity check any harness can assert on itself."
            ),
        },
    ],
},

# ============================================================================
# §7 — Communication Models
# ============================================================================
{
    "num": 7,
    "label": "§7",
    "title": "Communication Models",
    "tagline": "Shared memory and message passing are the two families of inter-process communication, and the choice is about coupling, not just speed.",
    "divider_notes": (
        "Everything earlier in the deck assumed threads sharing one address "
        "space. This section steps outside that assumption to communication "
        "between separate processes, possibly on separate machines, where "
        "the memory model no longer reaches and every handoff crosses a "
        "boundary the kernel, or a network, has to mediate."
    ),
    "slides": [
        {
            "kind": "content",
            "title": "Two IPC Families",
            "body": [
                heading("Zero-copy and tight, or mediated and loose", color=C.ACCENT_BLUE),
                bullet("Shared memory maps the same pages into two address spaces — no copy, but no delivery guarantee at all"),
                bullet("Notification has to be built separately, typically a futex word plus a seqlock for torn-read detection"),
                bullet("Message passing moves discrete messages through a kernel-mediated channel — at least one copy, but ordering, delivery, and back-pressure come included"),
                bullet("Most real systems use both, at different layers, for different latency budgets"),
            ],
            "diagram": dg("22-communication-families"),
            "notes": (
                "The two families trade the same resource in opposite "
                "directions: coupling for throughput, or throughput for "
                "decoupling. Shared memory is the tightest possible coupling "
                "— both sides must agree on a byte-for-byte layout, must run "
                "on the same machine, and must build their own notification "
                "scheme on top, typically a futex word a reader sleeps on "
                "and a writer wakes, paired with a seqlock so an optimistic "
                "read can detect and retry if a writer raced it. Message "
                "passing instead hands the work to the kernel, which copies "
                "the data at least once but, in exchange, handles ordering "
                "and delivery and gives back-pressure for free — a full "
                "kernel buffer blocks the writer rather than requiring "
                "hand-rolled coordination. Most production systems use both "
                "at once: shared memory for the tightest same-host, "
                "latency-critical handoff, and message passing for anything "
                "that needs to cross a process or machine boundary, "
                "tolerate a restart on either side, or simply does not sit "
                "on a latency-critical path."
            ),
        },
        {
            "kind": "content",
            "title": "Choosing a Model",
            "body": [
                heading("The question behind every row is coupling", color=C.ACCENT_GREEN),
                bullet("Same host, lowest latency, coupling acceptable — shared memory, or a ring-buffer pattern"),
                bullet("Same host, decoupled processes, need file-descriptor or credential transfer — a UNIX domain socket"),
                bullet("Cross host, reliable byte stream — TCP with explicit length-prefix framing"),
                bullet("Local-segment discovery, loss-tolerant, one-to-many — UDP, multicast if the group is unknown in advance"),
                bullet("A control plane — configuration, status, service queries — a message bus, not a hand-rolled socket protocol"),
            ],
            "notes": (
                "This is the decision guide version of the previous slide, "
                "and the underlying question behind every row is the same "
                "one: how tightly can the two sides afford to be coupled, "
                "and how much of that coupling cost actually gets paid back "
                "in latency or throughput where it matters. A latency-"
                "critical, same-host handoff justifies shared memory's "
                "coupling cost. A control-plane query that runs once a "
                "second does not, and reaching for raw shared memory there "
                "trades real engineering risk for a performance gain nobody "
                "will ever observe. Every stream-based transport in this "
                "table — TCP, a pipe, a UNIX stream socket — has no built-in "
                "message boundaries, so a length-prefix convention, a fixed "
                "field in front of each message stating exactly how many "
                "bytes follow, is close to universal in binary protocols: it "
                "needs no escaping, and the reader's job stays mechanical."
            ),
        },
    ],
},

# ============================================================================
# §8 — Debugging Races and Deadlocks
# ============================================================================
{
    "num": 8,
    "label": "§8",
    "title": "Debugging Races and Deadlocks",
    "tagline": "A race explained in the abstract teaches nothing — a correct-looking run is evidence of nothing either.",
    "divider_notes": (
        "Races and deadlocks are scheduling-dependent by nature, which means "
        "a broken program can pass every plain run thrown at it. "
        "This section is about forcing a failure open on demand, rather than "
        "hoping the scheduler reproduces it, and then reading what a race "
        "detector actually says once it catches one."
    ),
    "slides": [
        {
            "kind": "content",
            "title": "Forcing the Bug Open",
            "body": [
                heading("Sometimes-broken is still broken", color=C.ACCENT_RED),
                bullet("Two unsynchronized accesses to the same object, at least one a write, is undefined behavior — independent of what any one run prints"),
                bullet("A plain run of a racy program can print the correct answer on one invocation and a corrupted one on the next"),
                bullet("The AB/BA deadlock can resolve favorably nine times out of ten on an idle, fast machine"),
                bullet("Forcing the acquisition window open deliberately — for example with a barrier both threads must cross before their second lock — turns sometimes into every run"),
            ],
            "notes": (
                "The trap worth naming directly: treating a clean-looking "
                "result as proof of correctness is exactly backwards for a "
                "race, because the absence of a symptom is not the absence "
                "of the defect. A race that happens to resolve favorably "
                "under today's scheduler, kernel, and core count can resolve "
                "unfavorably the moment any one of those three things "
                "changes, with no code change at all — and an optimizing "
                "compiler can make it worse by assuming the program is "
                "race-free and hoisting a read out of a loop entirely, so "
                "the symptom stops being a wrong number and becomes a thread "
                "that never observes another thread's writes at all. The "
                "same logic applies to the textbook two-mutex deadlock: both "
                "threads have to reach their second lock call while the "
                "other already holds its first, a timing window narrow "
                "enough that the program can appear to work most of the "
                "time. The fix for demonstrating either bug reliably is the "
                "same idea: force the dangerous window open deliberately, "
                "rather than hoping the scheduler lands on it, which turns "
                "an occasional failure into the only kind worth handing to a "
                "debugger or a CI gate."
            ),
        },
        {
            "kind": "content",
            "title": "Reading a Race Report",
            "body": [
                heading("What a race detector actually observed", color=C.ACCENT_PURPLE),
                bullet("The two conflicting accesses, with full call stacks to the exact source lines"),
                bullet("The raced-on location — a global, a heap allocation, or a class member, traced back to its allocation site"),
                bullet("Each thread's own creation site, so a worker from a pool still names a meaningful origin"),
                bullet("Derived from a per-thread vector clock, updated at every mutex unlock, atomic release, and join"),
                para("Dynamic analysis: a clean run proves only that this interleaving was race-free, never that the program contains no race.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("27-tsan-report-anatomy"),
            "notes": (
                "Each section of a race-detector report maps onto a "
                "specific fact the instrumentation observed during the one "
                "execution it actually ran. The two conflicting-access "
                "blocks are the heart of the report — both writes, in the "
                "common read-modify-write case, each with the full call "
                "stack that reached it. Naming the raced-on location matters "
                "more once the report involves a heap allocation rather than "
                "an obviously-named global, since the tool can trace that "
                "location back to which object's instance was involved. The "
                "deeper mechanism is a per-thread vector clock, updated at "
                "every synchronization point, tracking precisely which other "
                "threads' prior writes a given access is guaranteed to have "
                "observed — two accesses to the same location, at least one "
                "a write, with no happens-before relationship found between "
                "them, is the detector's working definition of a race, "
                "checked against the one interleaving the instrumented "
                "binary actually hit. That is also the report's sharpest "
                "limitation: this is dynamic analysis, so a clean run proves "
                "the exercised schedule and inputs hit no race, never that "
                "the program contains none."
            ),
        },
    ],
},

# ============================================================================
# §9 — Concurrency in Containers
# ============================================================================
{
    "num": 9,
    "label": "§9",
    "title": "Concurrency in Containers",
    "tagline": "The kernel interface a program queries for core count and the control that actually throttles it are two different mechanisms.",
    "divider_notes": (
        "Every thread pool and polling loop so far assumed a program could "
        "see the machine it was actually running on. Inside a container "
        "that assumption breaks in a specific, mechanical way: a time "
        "budget and a fixed core set are configured from the same resource "
        "request but enforced by unrelated code paths in the kernel, and a "
        "pool sized correctly under one is badly oversized under the other."
    ),
    "slides": [
        {
            "kind": "content",
            "title": "Quota vs Cpuset",
            "body": [
                heading("A time budget and a fixed core set are not the same limit", color=C.ACCENT_BLUE),
                bullet("cpu.max is a time budget — two numbers, microseconds of CPU time allowed per period, across every visible core"),
                bullet("cpuset.cpus is a fixed set of core IDs — no period, no throttling, just cores that are off-limits entirely"),
                bullet("The same --cpus=2 request can map to either control, or both at once, depending on what sits underneath"),
                bullet("A quota-only container can land on any of eight cores while burning only two cores' worth of time per period — throttled hard and often"),
            ],
            "diagram": dg("32-quota-vs-cpuset"),
            "notes": (
                "Two independent cgroup controls, easy to confuse because "
                "they are set from the same flag or the same resource block, "
                "but enforced by unrelated code paths. A time budget says "
                "nothing about which physical cores the cgroup's threads may "
                "use — they remain free to run on any core the scheduler "
                "picks, and the quota taxes total CPU-seconds, not core "
                "count, so eight threads spread across eight cores exhaust "
                "a two-core budget exactly as fast as two threads running "
                "flat out on two cores. A fixed core set is the opposite "
                "kind of control: a thread spinning continuously on one of "
                "its cores just keeps running there, with no time accounting "
                "to exhaust at all. Both configurations can describe two "
                "cores to a person reading the resource request, and they "
                "behave completely differently under load — one throttles "
                "in bursts, the other never throttles because there is no "
                "time budget to exceed in the first place."
            ),
        },
        {
            "kind": "content",
            "title": "A Core Count That Lies",
            "body": [
                heading("hardware_concurrency() reflects the affinity mask, not the quota", color=C.ACCENT_ORANGE),
                bullet("A cpuset restriction is reflected correctly — a container pinned to two cores reports two"),
                bullet("A quota has no effect on the affinity mask at all — the cores remain reachable, only the time is limited"),
                bullet("A container capped to two cores' worth of time on a sixteen-core host still reports sixteen"),
                bullet("Size every pool from the tighter of the cpuset count and the quota, or an orchestrator-supplied limit — never from hardware_concurrency() alone"),
            ],
            "notes": (
                "This is the trap worth building a mental alarm around. "
                "hardware_concurrency() answers a specific question — how "
                "many cores can a thread here be scheduled onto — and it "
                "answers that question correctly even inside a container, "
                "because a cpuset restriction does shrink the "
                "affinity mask the function reads. A time-based quota does "
                "nothing to that mask at all: it does not remove any core "
                "from the set a thread may run on, it only limits how much "
                "aggregate time the cgroup's threads may consume before "
                "being paused. A container given a two-core time budget on "
                "an unrestricted sixteen-core host will report sixteen, "
                "faithfully, because sixteen cores really are reachable. A "
                "program that sizes a thread pool from that number alone "
                "spins up far more threads than the time budget can run "
                "concurrently, and every one of them now competes for a "
                "slice that was never going to stretch that far. The fix is "
                "mechanical: read the actual constraint, the smaller of the "
                "cpuset-visible count and the quota, and prefer an "
                "orchestrator-supplied limit outright when one is present, "
                "since the orchestrator already knows the real allocation."
            ),
        },
        {
            "kind": "content",
            "title": "Pinning Under Orchestration",
            "body": [
                heading("Pinning stops migration — it does not grant time", color=C.ACCENT_GREEN),
                bullet("Under a pure time quota, pinning eliminates migration jitter but does nothing to protect against throttling"),
                bullet("A pinned, busy thread under a tight quota still burns the whole cgroup's time budget and still gets throttled"),
                bullet("Under a fixed core set, pinning composes cleanly — the kernel grants exclusive, unthrottled cores"),
                bullet("This is the shape a static CPU-manager policy produces for a guaranteed-quality pod with an integer core request"),
            ],
            "notes": (
                "The two interactions here are not symmetric, and knowing "
                "which one applies changes what pinning actually buys. Under "
                "a pure time quota with no core restriction, pinning a "
                "thread still works mechanically — it stops "
                "migrating — but it does nothing to protect that thread from "
                "being throttled, because the quota is accounted across the "
                "whole cgroup regardless of which cores its threads happen "
                "to be pinned to. A pinned thread spinning under a tight "
                "quota burns through the entire budget by itself and gets "
                "throttled exactly as it would unpinned; pinning buys cache "
                "locality there, not additional time. Under a fixed core "
                "set, pinning composes the way intuition expects, because "
                "the orchestrator has already removed those cores from the "
                "node's shared pool and granted them exclusively — the "
                "shape a guaranteed-quality pod with an integer core request "
                "produces under a static scheduling policy. The practical "
                "rule for a latency-sensitive workload follows directly: "
                "request whole cores under a policy that yields exclusive "
                "pinning, not a shared time budget, and watch the "
                "cgroup's own throttling counter as the clearest available "
                "signal when that is not possible."
            ),
        },
    ],
},

# ============================================================================
# §10 — Where to Go Next
# ============================================================================
{
    "num": 10,
    "label": "§10",
    "title": "Where to Go Next",
    "tagline": "This deck sold the mental model. The next two decks build the toolkit and tune it for the microsecond scale.",
    "divider_notes": (
        "Everything in this deck has been conceptual on purpose — what "
        "concurrency and parallelism mean, what the hardware actually "
        "provides, why shared state is hard, how to measure what is true. "
        "The two companion decks pick up exactly where this one stops: one "
        "builds the concrete C++ toolkit that implements these ideas, and "
        "the other tunes that toolkit for low-latency, high-throughput "
        "systems where microseconds are the unit that matters."
    ),
    "slides": [
        {
            "kind": "content",
            "title": "Next: the C++ Toolkit",
            "body": [
                heading("The 101 deck — concrete mechanisms", color=C.ACCENT_BLUE),
                bullet("Threads, jthread, and cooperative cancellation with stop_token"),
                bullet("Coroutines, futures, and promises — the language's two answers to asynchronous work"),
                bullet("Lock-free data structures and the reclamation schemes that make them safe"),
                bullet("Parallel algorithms and execution policies — hardware without hand-written thread code"),
            ],
            "notes": (
                "This deck deliberately stayed light on code, because the "
                "point was the mental model, not the API surface. The 101 "
                "deck is where that model gets concrete: every idea "
                "introduced here, the four execution models, the futex "
                "underneath a mutex, the memory-order spectrum, maps onto a "
                "specific standard-library mechanism a C++ engineer reaches "
                "for directly. Threads and jthread give structure, "
                "coroutines and futures give two different shapes of "
                "asynchronous work, lock-free structures put the memory "
                "model from this deck to direct use, and the parallel "
                "algorithms turn hardware into completed work without "
                "hand-written thread management at all. Anyone who leaves "
                "this deck with the vocabulary should leave the 101 deck "
                "able to reach for the right tool, not just name it."
            ),
        },
        {
            "kind": "content",
            "title": "Next: Low Latency",
            "body": [
                heading("The 201 deck — tuning for microseconds", color=C.ACCENT_PURPLE),
                bullet("Mechanical sympathy, NUMA-aware placement, and SIMD data parallelism"),
                bullet("Lock-free messaging and the disruptor pattern for the tightest same-host handoffs"),
                bullet("Benchmarking discipline pushed to the microsecond scale, with the coordinated-omission correction as a hard requirement, not an option"),
                bullet("The fast path: core pinning, zero-allocation hot loops, and the busy-poll-versus-block trade-off"),
            ],
            "notes": (
                "The 201 deck is for the reader building something closer "
                "to an exchange matching engine or another low-latency, "
                "high-throughput system, where the concepts from this deck "
                "stop being background and become the daily unit of "
                "reasoning. Mechanical sympathy and NUMA-aware placement "
                "extend the machine-underneath material from this deck into "
                "an explicit allocation and pinning strategy. The disruptor "
                "pattern is the shared-memory, lock-free end of the "
                "communication-models spectrum taken as far as it goes on a "
                "single host. And the benchmarking discipline from this "
                "deck stops being a methodology chapter and becomes the "
                "baseline every claim in that deck has to clear, including "
                "the coordinated-omission correction, because at microsecond "
                "scale a benchmark that lies about its own tail is worse "
                "than no benchmark at all. Read the 101 deck first if the "
                "toolkit itself still feels unfamiliar — the 201 deck "
                "assumes it."
            ),
        },
    ],
},

]
