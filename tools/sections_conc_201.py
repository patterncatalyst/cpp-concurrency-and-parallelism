"""
sections_conc_201.py — slide content for the 201 LOW-LATENCY & HIGH-THROUGHPUT
deep-dive deck (cpp-concurrency-and-parallelism).

Companion content module to tools/build-conc-201-pptx.py. Same schema as the
cpp-statelessness compendium deck: SECTIONS is a list of section dicts, each
with num/label/title/tagline/divider_notes/slides[]. Slide kinds: content |
content-code | diagram | stat-row | demo-cue — rendered by tools/build-pptx.py.

Content source: _docs/16 through _docs/33 (NUMA through the full example).
Diagrams come from diagrams/*.svg, converted to /tmp/diagrams-png/<name>.jpg
by tools/convert-diagrams.sh. Demo cues reference examples/concurrency/*.

Human-edited prose; build-conc-201-pptx.py is the renderer.
"""
from pptx.dml.color import RGBColor
from pptx.util import Pt
from pptx.enum.text import PP_ALIGN


class C:
    ACCENT_CYAN    = RGBColor(0x00, 0xBC, 0xD4)
    ACCENT_BLUE    = RGBColor(0x1E, 0x6F, 0xC8)
    ACCENT_GREEN   = RGBColor(0x27, 0xAE, 0x60)
    ACCENT_RED     = RGBColor(0xE8, 0x48, 0x55)
    ACCENT_ORANGE  = RGBColor(0xF5, 0xA6, 0x23)
    ACCENT_PURPLE  = RGBColor(0x9B, 0x59, 0xB6)
    TEXT_DARK      = RGBColor(0x1A, 0x2B, 0x3C)
    TEXT_MUTED     = RGBColor(0x90, 0xA4, 0xAE)
    BG_CARD_LIGHT  = RGBColor(0xEC, 0xF0, 0xF1)
    BG_CARD_SOFT   = RGBColor(0xE0, 0xE8, 0xF0)


DG = "/tmp/diagrams-png"  # converted JPGs live here


def para(text, size=Pt(16), bold=False, italic=False,
         color=C.TEXT_DARK, bullet=False, align=PP_ALIGN.LEFT):
    return dict(text=text, size=size, bold=bold, italic=italic,
                color=color, bullet=bullet, align=align)


def bullet(text, size=Pt(15)):
    return dict(text=text, size=size, bold=False, color=C.TEXT_DARK,
                bullet=True)


def heading(text, size=Pt(18), color=None):
    return dict(text=text, size=size, bold=True, color=color or C.TEXT_DARK)


def dg(name):
    return f"{DG}/{name}.jpg"


REPO = "github.com/patterncatalyst/cpp-concurrency-and-parallelism"


def demo_url(path):
    return f"{REPO}/tree/main/examples/concurrency/{path}"


SECTIONS = [

# ============================================================================
# §1 — NUMA, Affinity, and Data Locality (ch16)
# ============================================================================
{
    "num": 1,
    "label": "§1",
    "title": "NUMA, affinity, and data locality",
    "tagline": "Pinning a thread solves half the locality problem; first-touch decides the other half.",
    "divider_notes": (
        "This section opens the deep-dive compendium at chapter 16. The "
        "thesis: a multi-socket server, or a single chip built from several "
        "dies, gives every core a fast path to its own local memory and a "
        "slower one to every other node's. Pinning a thread to a node and "
        "placing its memory on that same node are two separate problems, "
        "and getting only one of them right still leaves the remote-access "
        "penalty in place.\n\n"
        "The running example provisions a disposable KVM guest with a real "
        "two-node topology, because the remote-latency gap this chapter "
        "measures cannot be reproduced truthfully inside an ordinary "
        "container on a single-node host."),
    "slides": [
        {
            "kind": "content",
            "title": "First-touch: the bug with no allocation call",
            "body": [
                heading("Linux binds a page to a node on first write", color=C.ACCENT_BLUE),
                bullet("malloc reserves address space; the kernel binds a physical page to a node only when it's first written"),
                bullet("a startup loop that zero-initializes a buffer on the main thread binds every page to that thread's node"),
                bullet("workers on other nodes then pay the remote penalty on every touch, for the buffer's entire lifetime"),
                para("Fix: numa_alloc_onnode when the target node is known up front, or let each worker first-touch its own slice.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("16-first-touch-misplacement"),
            "notes": (
                "First-touch placement is the default allocation policy on every mainstream "
                "Linux distribution, and it's easy to get backwards: the thread that writes "
                "a page first determines which node's physical memory backs it, regardless "
                "of which thread allocated it or which thread does the bulk of the work "
                "afterward.\n\n"
                "The bug shape is specific and common: a reasonable-looking init loop on the "
                "main thread binds a buffer to the wrong node before it's ever handed to the "
                "worker pool that actually owns it. Nothing in the source names the mistake "
                "directly; there's no visible allocation call on the wrong node, just an "
                "initialization loop that ran before anyone decided which thread should own "
                "which memory. The fix is either explicit (numa_alloc_onnode) or structural "
                "(each worker touches its own slice first, so first-touch does the right "
                "thing by construction)."),
        },
        {
            "kind": "stat-row",
            "title": "The cost of getting locality wrong",
            "stats": [
                ("10", "a node's relative distance to itself, by numactl --hardware convention", C.ACCENT_BLUE),
                ("20s", "typical relative distance to a remote socket on current platforms", C.ACCENT_ORANGE),
                ("30-60%", "remote access latency premium over a local one, platform-dependent", C.ACCENT_RED),
                ("64B", "the cache line both false sharing and NUMA cost compound across", C.ACCENT_PURPLE),
            ],
            "notes": (
                "Four numbers to anchor the chapter. numactl's relative distance matrix is a "
                "proxy for the real latency gap, not the gap itself; a remote access "
                "routinely costs thirty to sixty percent more than a "
                "local one, and the exact figure is worth measuring on the target platform "
                "rather than assumed from a vendor spec sheet.\n\n"
                "The cache line number matters because the two costs compound: a line "
                "bounced between cores on the same node pays only the coherence cost, while "
                "the identical false-sharing pattern across nodes pays that cost plus the "
                "cross-node interconnect latency, because invalidating a remote core's "
                "cached copy is itself a message that crosses the same interconnect a remote "
                "read would. Padding fixes the coherence half; node-local placement fixes "
                "the other half, and a design needs both to close the gap completely."),
        },
        {
            "kind": "content-code",
            "title": "Pinning reaches through native_handle()",
            "body": [
                heading("No standard affinity API exists at C++20, 23, or 26", color=C.ACCENT_GREEN),
                bullet("jthread::native_handle() is the only portable path to pthread_setaffinity_np"),
                bullet("sysconf(_SC_NPROCESSORS_ONLN) counts cores system-wide, ignoring any affinity mask already in place"),
                bullet("a cpuset.cpus and cpuset.mems pair have to agree: one constrains cores, the other constrains memory nodes"),
            ],
            "code": (
                "void pin_to_node0(std::jthread& t, int core_in_node0) {\n"
                "    cpu_set_t set;\n"
                "    CPU_ZERO(&set);\n"
                "    CPU_SET(core_in_node0, &set);\n"
                "    ::pthread_setaffinity_np(t.native_handle(),\n"
                "                              sizeof(set), &set);\n"
                "}\n"
                "\n"
                "void* alloc_local(std::size_t bytes, int node) {\n"
                "    // libnuma, not the standard library\n"
                "    return numa_alloc_onnode(bytes, node);\n"
                "}"
            ),
            "notes": (
                "Pinning and NUMA placement are reached the same way at every standard this "
                "book tracks, through a jthread's native_handle() plus a POSIX or libnuma "
                "call underneath. The standard library gives cooperative cancellation; it "
                "gives no node-aware allocator and no affinity API of its own, at C++20, "
                "C++23, or C++26.\n\n"
                "A subtler container trap worth naming here: a cpuset that restricts cores "
                "but leaves cpuset.mems open to every node reintroduces exactly the "
                "remote-access penalty this chapter spends two sections eliminating, because "
                "nothing told the kernel to prefer the container's own node for its memory. "
                "A process inside a cpuset-restricted container that calls numa_alloc_onnode "
                "for an excluded node doesn't fail loudly either; it silently falls back to "
                "an allowed node, which is a second, quieter way the same misconfiguration "
                "surfaces."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 16,
            "demo_name": "First-touch placement and cpuset fallback",
            "demo_command": "cd examples/concurrency/16-numa-affinity-and-data-locality && ./demo.sh",
            "demo_description": (
                "Provisions a disposable KVM guest with a real two-NUMA-node topology and "
                "runs a benchmark there: numa_alloc_onnode placing pages on a requested "
                "node, first-touch binding a plain allocation to the thread that writes it "
                "first, and — confined to a cpuset whose cpuset.mems excludes the requested "
                "node — numa_alloc_onnode silently falling back to an allowed node."
            ),
            "demo_url": demo_url("16-numa-affinity-and-data-locality"),
            "notes": (
                "This is the one demo in the deck that runs in a KVM lab rather than a "
                "plain container, and that choice is itself the point worth making out "
                "loud: NUMA placement and real local-versus-remote latency cannot be "
                "reproduced truthfully inside an ordinary container on a single-node host, "
                "so the example provisions a disposable guest instead of working around the "
                "limitation.\n\n"
                "What to show: the guest's verify.lua reads back the actual node of every "
                "page with get_mempolicy and confirms the placement and fallback behaviors "
                "directly rather than asserting them from the side. Flag the demo's own "
                "caveat too: on a host with only one physical NUMA node the guest's "
                "second node is emulated, so placement and fallback are real and verified, "
                "but the remote-latency penalty itself isn't reproduced on that topology. "
                "No host-level NUMA, governor, or isolcpus setting is ever touched; only the "
                "disposable guest's configuration moves."),
        },
    ],
},

# ============================================================================
# §2 — SIMD and Data Parallelism (ch17)
# ============================================================================
{
    "num": 2,
    "label": "§2",
    "title": "SIMD and data parallelism",
    "tagline": "One instruction, several lanes, inside a single core — with none of a thread's coordination cost.",
    "divider_notes": (
        "SIMD parallelizes inside a single thread, across data, rather than "
        "across independent execution units. The two forms of parallelism "
        "are complementary: a thread pool divides work across cores, and "
        "each thread's share of that work can itself be vectorized. Almost "
        "every SIMD failure mode comes down to the compiler being unable to "
        "prove something about the data that the programmer already knows "
        "to be true — aliasing, a data-dependent branch, or a layout that "
        "scatters the one field a vector load actually wants."),
    "slides": [
        {
            "kind": "content",
            "title": "Layout decides whether vectorization is even possible",
            "body": [
                heading("Array-of-structs vs struct-of-arrays", color=C.ACCENT_BLUE),
                bullet("AoS: one particle's fields contiguous, then the next — a stride-16-read-4 pattern that defeats a vector load"),
                bullet("SoA: every particle's x contiguous in its own array — exactly the contiguous run a vector load wants"),
                bullet("three source patterns reliably block autovectorization: aliasing, data-dependent branches, gather/scatter access"),
                para("restrict (or __restrict) is a promise the compiler trusts without verifying — violate it and the result is undefined.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("17-aos-vs-soa"),
            "notes": (
                "The autovectorizer declines rather than guesses whenever it can't prove a "
                "transformation preserves observable behavior — pointer aliasing, a branch "
                "that picks a different computation per lane, or a gather/scatter access "
                "pattern all trip the same silent fallback to a scalar loop, with no "
                "diagnostic unless one is explicitly requested.\n\n"
                "Layout is usually decided long before the hot loop is written, in the "
                "struct definition, and it matters more than any compiler flag: SoA turns a "
                "scattered, gap-filled access pattern into the contiguous run a vector load "
                "needs, at the cost of four separate lookups for code that wants one whole "
                "entity at a time. The usual resolution keeps SoA for anything running "
                "through a hot, vectorizable loop and tolerates the extra indirection "
                "elsewhere."),
        },
        {
            "kind": "content-code",
            "title": "std::experimental::simd is the production option today",
            "body": [
                heading("C++26's std::simd is accepted, not yet shipping", color=C.ACCENT_GREEN),
                bullet("hand-written intrinsics give full control, tied to one instruction-set extension"),
                bullet("std::experimental::simd (Parallelism TS v2) maps the same source onto the target's native width"),
                bullet("std::simd, proposed via P1928 for C++26, is the eventual replacement — treat it as not yet shippable"),
            ],
            "code": (
                "#include <experimental/simd>\n"
                "namespace stdx = std::experimental;\n"
                "\n"
                "void add(const float* __restrict a,\n"
                "         const float* __restrict b,\n"
                "         float* __restrict out, int n) {\n"
                "    using V = stdx::native_simd<float>;\n"
                "    int width = V::size();\n"
                "    int i = 0;\n"
                "    for (; i + width <= n; i += width) {\n"
                "        V va(a + i, stdx::element_aligned);\n"
                "        V vb(b + i, stdx::element_aligned);\n"
                "        (va + vb).copy_to(out + i,\n"
                "                           stdx::element_aligned);\n"
                "    }\n"
                "    for (; i < n; ++i) out[i] = a[i] + b[i];\n"
                "}"
            ),
            "notes": (
                "Three ways to get vectorized code exist today, trading portability, "
                "control, and maintenance cost differently. Trusting the autovectorizer "
                "costs nothing in code complexity and is the right default for most code; "
                "hand-written intrinsics are the right tool only once the autovectorizer "
                "provably can't produce what's needed.\n\n"
                "std::experimental::simd sits between the two — write the width-agnostic "
                "operation once, and the library maps it onto the target's actual register "
                "width, with a correct scalar fallback anywhere nothing matches. C++26's "
                "std::simd targets the identical API shape but ships in no mainstream "
                "standard library as of this writing; the experimental header is the stable, "
                "usable predecessor to reach for in production code, not a stand-in to "
                "migrate away from casually once the real thing ships."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 17,
            "demo_name": "Scalar, intrinsics, and std::experimental::simd",
            "demo_command": "cd examples/concurrency/17-simd && ./demo.sh",
            "demo_description": (
                "Drives a particle-update kernel through three variants — array-of-structs "
                "scalar, struct-of-arrays scalar, and struct-of-arrays std::experimental::"
                "simd — and asserts the three produce bit-identical final positions, then "
                "reports (as a soft signal) whether the explicit SIMD path ran faster."
            ),
            "demo_url": demo_url("17-simd"),
            "notes": (
                "Lead with the correctness assertion before the performance one: all three "
                "update variants have to produce bit-identical positions, which is the "
                "demo's way of proving a layout or instruction-set change never alters the "
                "computed result, only its cost.\n\n"
                "The speed comparison is reported as information, not a hard pass/fail gate, "
                "because SIMD throughput depends on the CPU features actually present on the "
                "machine running the demo. Report this to the room: a binary built with -march=native on one host and shipped to a "
                "fleet with older CPUs doesn't run slower, it faults outright on the first "
                "instruction the hardware doesn't have."),
        },
    ],
},

# ============================================================================
# §3 — Benchmarking Without Deception (ch18)
# ============================================================================
{
    "num": 3,
    "label": "§3",
    "title": "Benchmarking without deception",
    "tagline": "Every performance claim later in this deck defers to this chapter's methodology.",
    "divider_notes": (
        "Not a specific result, but the discipline that makes any result in "
        "this book trustworthy: discard the cold calls, correct for "
        "coordinated omission, report a percentile instead of a mean, "
        "measure wall-clock time on a monotonic clock, and keep the "
        "compiler from deleting the very thing being measured. Everything "
        "that follows answers one question — when a measurement says a "
        "path takes 47 nanoseconds, what has to be true for that number to "
        "mean what it claims."),
    "slides": [
        {
            "kind": "content",
            "title": "Coordinated omission erases the tail it exists to describe",
            "body": [
                heading("A closed-loop timer hides queued requests behind a stall", color=C.ACCENT_RED),
                bullet("iteration N+1 doesn't start its clock until iteration N returns — the natural, and deceptive, loop shape"),
                bullet("a single stalled iteration records one sample; a fixed-rate caller actually experiences several queued behind it"),
                bullet("the fix: backfill synthetic samples down to the expected interval for every raw sample that exceeds it"),
                para("co_p99 is always >= the raw p99 from the same run — the cheapest sanity check a harness can assert on itself.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("18-coordinated-omission"),
            "notes": (
                "A benchmark's timed loop is almost always closed: one iteration finishes "
                "before the next begins. A real caller sending requests at a fixed rate "
                "doesn't pause while a stall plays out; five or ten more requests queue up "
                "behind it, each paying a delay close to the stall's own length, and a "
                "closed-loop timer records exactly one sample for the whole event.\n\n"
                "Gil Tene's name for this, coordinated omission, is precise: the benchmark "
                "didn't just under-measure the tail, it erased the part of the distribution "
                "the tail exists to describe. The correction is mechanical once the picture "
                "is clear — backfill v-E, v-2E, and so on down to E for every sample "
                "exceeding the expected interval, capped so one pathological stall can't "
                "grow the array without limit."),
        },
        {
            "kind": "content",
            "title": "Percentiles over the mean, and a clock that can't lie",
            "body": [
                heading("A mean of 200ns describes two very different systems", color=C.ACCENT_BLUE),
                bullet("999 calls at 40ns and one at 160,200ns average to the same 200ns as every call taking 200ns flat"),
                bullet("std::chrono::steady_clock is the right clock — monotonic, immune to NTP jumps, counts blocked time too"),
                bullet("the CPU frequency governor has to be pinned for a run's duration, or variance in clock rate lands in the tail"),
                bullet("the compiler will delete a loop whose result is never observed — accumulate into a checksum the program reads back"),
            ],
            "notes": (
                "Latency distributions are heavy-tailed, and averaging a heavy tail drags "
                "the mean toward exactly the outliers a reader most needs to see reported "
                "accurately, while hiding how bad the tail actually gets. A percentile "
                "answers a sharper question — what latency do ninety-nine percent of calls "
                "beat — without blending the tail into the body.\n\n"
                "The compiler-deletion trap has nothing to do with clocks: if a timed "
                "iteration's result is never read, the optimizer is entitled to remove the "
                "computation entirely, leaving an accurate measurement of an empty loop. "
                "Folding every iteration's output into a running checksum the program prints "
                "at the end defeats that, and doubles as a correctness check — a diverging "
                "checksum across two runs signals a logic bug, not measurement noise."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 18,
            "demo_name": "The chapter's benchmarking harness",
            "demo_command": "cd examples/concurrency/18-benchmarking-without-deception && ./demo.sh",
            "demo_description": (
                "Runs an atomic fetch_add workload through the full harness — warmup, "
                "percentile reporting, coordinated-omission correction, checksum — and "
                "asserts co_p99_ns >= p99_ns and checksum correctness, then drives a "
                "--naive mode that skips warmup and prints no percentile field at all."
            ),
            "demo_url": demo_url("18-benchmarking-without-deception"),
            "notes": (
                "The point of the --naive mode is pedagogical: it makes the methodology gap "
                "visible in the program's own output rather than only in prose. A naive, "
                "unwarmed single-sample timing has no p50, no p99, and nothing to assert "
                "against — it simply doesn't produce the vocabulary a trustworthy benchmark "
                "needs.\n\n"
                "Every later chapter in this deck that cites a performance number is leaning "
                "on exactly this harness rather than re-deriving its own, so this is worth "
                "treating as the deck's foundation demo, not a one-off. Watch co_p99 track "
                "visibly above the raw p99 once the workload includes any scheduling noise "
                "at all."),
        },
    ],
},

# ============================================================================
# §4 — The Low-Latency Fast Path (ch19)
# ============================================================================
{
    "num": 4,
    "label": "§4",
    "title": "The low-latency fast path",
    "tagline": "Three moves shrink the tail; none of them is free, and applying them without a reason is worse than skipping them.",
    "divider_notes": (
        "Once a p99 can be trusted, the next question is how to make it "
        "small. The answer on Linux is a short, specific list: pin a core, "
        "reuse one buffer, decide busy-poll versus block — each targeted at "
        "removing one concrete source of the multi-microsecond stalls the "
        "previous chapter's corrected percentile exists to surface. A fast "
        "path isn't the code with no cost; it's the code whose cost has "
        "been moved somewhere predictable and paid for on purpose."),
    "slides": [
        {
            "kind": "content",
            "title": "Three moves that shrink the tail",
            "body": [
                heading("Pin, reuse, busy-poll — each removes one jitter source", color=C.ACCENT_BLUE),
                bullet("pin to one CPU: a migrated thread loses its warm cache and, across a NUMA boundary, local memory access"),
                bullet("reuse one buffer: a freshly allocated read buffer pays an allocator cost that's small on average, variable in the tail"),
                bullet("busy-poll: spins on a non-blocking read instead of sleeping, trading a whole core for eliminating the wakeup round trip"),
                para("Right for a dedicated latency-critical thread; wrong for a general worker pool that benefits from load balancing.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("19-fastpath-datapath"),
            "notes": (
                "Each move targets a specific line item in a latency budget and is worthless, "
                "or harmful, applied without a reason. A thread pinned to a single core that "
                "then blocks on a lock has nowhere else to run once runnable again — pinning "
                "a thread that isn't actually CPU-bound just reproduces, on purpose, the "
                "bottleneck the scheduler's default migration would otherwise relieve.\n\n"
                "The workloads that benefit are the ones the scheduler actively hurts by "
                "moving: a tight polling loop, a hot path with a resident working set a "
                "migration would evict, or a pipeline stage whose pinned neighbors depend on "
                "this one holding steady timing. isolcpus at boot removes cores from the "
                "kernel's normal rotation entirely, so pinning plus isolation together give "
                "a latency-critical thread a core the rest of the system has agreed to leave "
                "alone."),
        },
        {
            "kind": "content-code",
            "title": "Pinning and an efficient (not a busy) wait",
            "body": [
                heading("atomic wait/notify is a blocking wait, not a spin substitute", color=C.ACCENT_GREEN),
                bullet("sysconf(_SC_NPROCESSORS_ONLN) is the right call to validate a pin target — it ignores any affinity mask already in place"),
                bullet("wait/notify parks on a futex without a condvar's mutex pairing, but it's still a kernel wakeup"),
                bullet("a hybrid is common in practice: spin for a short window after the last message, then fall back to blocking"),
            ],
            "code": (
                "void pin_to_cpu(std::jthread& t, int cpu) {\n"
                "    cpu_set_t set;\n"
                "    CPU_ZERO(&set);\n"
                "    CPU_SET(cpu, &set);\n"
                "    ::pthread_setaffinity_np(t.native_handle(),\n"
                "                              sizeof(set), &set);\n"
                "}\n"
                "\n"
                "// efficient blocking wait -- NOT a busy-poll substitute\n"
                "std::atomic<bool> data_ready{false};\n"
                "void waiting_consumer() {\n"
                "    data_ready.wait(false);   // parks on a futex\n"
                "    process_message();\n"
                "}"
            ),
            "notes": (
                "A careless implementation of the affinity-count check quietly breaks under a "
                "container: a count that reflects the current affinity mask instead of the "
                "system-wide core count rejects a valid pin target the moment something "
                "upstream has already narrowed the mask — the identical bug shape "
                "hardware_concurrency() has when it reads a cgroup quota instead of the "
                "host's real core count, reached through a different door.\n\n"
                "Zero-allocation hot paths generalize past the obvious inbound-buffer case: "
                "any container growth on the path — a vector reallocating because capacity "
                "wasn't reserved, a string built incrementally — reintroduces the same "
                "variable cost less visibly. reserve() ahead of the loop closes that door at "
                "compile time rather than relying on every call site remembering not to "
                "trigger a reallocation."),
        },
        {
            "kind": "content",
            "title": "What's left once the big three are settled",
            "body": [
                heading("Syscalls, locks, branches — then kernel bypass", color=C.ACCENT_ORANGE),
                bullet("a syscall's mode-transition cost is smaller than a scheduler round trip but still non-zero and not fully predictable"),
                bullet("a lock's danger isn't acquisition cost — it's the possibility of blocking on another thread's schedule"),
                bullet("a mispredicted branch costs a pipeline flush; put the common case first once the bigger costs are addressed"),
                bullet("kernel bypass removes the kernel crossing entirely — the next tier past a busy-poll loop, at a real operational cost"),
            ],
            "notes": (
                "Order matters here: optimizing a branch before pinning, allocation, and "
                "blocking behavior are settled spends effort on a cost an order of magnitude "
                "smaller than the ones still sitting unaddressed. A single-producer/single-"
                "consumer handoff can usually avoid a lock entirely by construction, using "
                "two atomics the way the disruptor pattern in the next section does.\n\n"
                "Kernel-bypass networking maps a network interface's queues directly into "
                "userspace, removing the per-packet kernel transition a busy-poll loop still "
                "pays. The cost is a large jump in operational complexity — no ordinary "
                "socket tooling, no kernel firewall rules, a driver model specific to the "
                "bypass framework — which is why this deck treats it as the tier to reach "
                "for only once a standard busy-poll path has been measured and found "
                "insufficient, not a default starting point."),
        },
    ],
},

# ============================================================================
# §5 — Mechanical Sympathy (ch20)
# ============================================================================
{
    "num": 5,
    "label": "§5",
    "title": "Mechanical sympathy",
    "tagline": "Two threads that share no data still serialize, because the cache invalidates whole lines, not bytes.",
    "divider_notes": (
        "Once a hot path allocates nothing and touches a fixed set of "
        "memory on every iteration, that memory's own layout matters as "
        "much as whether it's allocated at all. A CPU cache moves fixed-"
        "size 64-byte lines, not individual bytes, and false sharing is "
        "the resulting failure: two logically unrelated variables land on "
        "the same line, and every write by either thread evicts the "
        "other's cached copy of the whole line."),
    "slides": [
        {
            "kind": "content",
            "title": "False sharing looks like contention with no shared data",
            "body": [
                heading("Two atomics eight bytes apart, same cache line", color=C.ACCENT_RED),
                bullet("each thread's fetch_add is uncontended in the sense a programmer means — no other thread touches that value"),
                bullet("and yet each write invalidates the line the other thread just cached, forcing a fresh fetch on the very next access"),
                bullet("alignas(std::hardware_destructive_interference_size) is the portable fix — padding to a reported line size, not a guess"),
                para("hardware_constructive_interference_size names the opposite goal: packing together data that is used together onto one line on purpose.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("20-false-sharing"),
            "notes": (
                "The shape is easy to construct by accident: two std::atomic<uint64_t> "
                "counters declared adjacently in a struct, each incremented by its own "
                "dedicated thread, sit well within a single 64-byte line with nothing "
                "logically connecting them, yet behave from a cache-traffic perspective "
                "exactly like one atomic under contention.\n\n"
                "Struct layout should follow who writes a field, not what reads naturally "
                "together semantically — hot, writer-owned fields each get their own padded "
                "line, while cold, read-mostly fields can safely share one, since nobody is "
                "contending to write them. A container's CPU quota or cpuset changes nothing "
                "about this; cache-line granularity is a hardware property no cgroup "
                "touches. NUMA placement is what compounds with it — a false-sharing pair "
                "split across nodes pays the coherence cost and the cross-node interconnect "
                "penalty together."),
        },
        {
            "kind": "content-code",
            "title": "A hot atomic never wins once contention is real",
            "body": [
                heading("Per-thread shards, summed only on read", color=C.ACCENT_PURPLE),
                bullet("padding separates independent atomics from each other — it does nothing when multiple threads write the same logical counter"),
                bullet("the fix is architectural: each thread writes a plain, uncontended local; the aggregate is computed only when needed"),
                bullet("the right trade whenever writes vastly outnumber reads — millions of increments a second, one read per metrics scrape"),
            ],
            "code": (
                "struct alignas(std::hardware_destructive_interference_size)\n"
                "PaddedCounter {\n"
                "    std::uint64_t value{0};  // owned by one thread only\n"
                "};\n"
                "\n"
                "class ShardedCounter {\n"
                "public:\n"
                "    explicit ShardedCounter(std::size_t n) : shards_(n) {}\n"
                "\n"
                "    void increment(std::size_t i) {\n"
                "        ++shards_[i].value;  // no atomic, no contention\n"
                "    }\n"
                "\n"
                "    std::uint64_t total() const {\n"
                "        std::uint64_t sum = 0;\n"
                "        for (const auto& s : shards_) sum += s.value;\n"
                "        return sum;\n"
                "    }\n"
                "\n"
                "private:\n"
                "    std::vector<PaddedCounter> shards_;\n"
                "};"
            ),
            "notes": (
                "This turns N threads contending on one hot atomic into N threads each "
                "writing a plain, non-atomic local variable, with the summation cost paid "
                "once per read rather than once per write. A single hot atomic every thread "
                "contends on is never faster than this shape once contention is real; it's "
                "only simpler to write.\n\n"
                "The shard count itself is a tuning parameter, not a fixed answer — too few "
                "shards and contention returns, too many and the read-time summation cost "
                "grows for no benefit. The crossover point where one atomic "
                "outperforms the sharding bookkeeping is worth confirming with the Chapter "
                "18 benchmark methodology rather than assumed."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 20,
            "demo_name": "Padded vs unpadded counters, pinned apart",
            "demo_command": "cd examples/concurrency/20-mechanical-sympathy && ./demo.sh",
            "demo_description": (
                "Two pinned threads each fetch_add their own counter through several trials "
                "of --pad off and --pad on. Correctness holds in every trial regardless of "
                "padding; the padded run's average elapsed time comes in measurably lower, "
                "which is the signal that false sharing is real, not hypothetical."
            ),
            "demo_url": demo_url("20-mechanical-sympathy"),
            "notes": (
                "Lead with the correctness invariant: both counts equal N exactly in every "
                "trial, padded or not, because false sharing is a performance bug, never a "
                "correctness bug. That's the detail that makes it insidious in production — "
                "a service can run false-shared counters for months with every test passing "
                "and no symptom visible anywhere except a latency number nobody is watching "
                "closely enough.\n\n"
                "What to show live: taskset pins the two threads to separate physical cores "
                "so the comparison isolates cache-line placement from scheduler noise, and "
                "an optional perf stat invocation surfaces L1-dcache-load-misses directly, "
                "turning the abstract coherence-traffic argument into a number on the "
                "screen."),
        },
    ],
},

# ============================================================================
# §6 — Lock-Free Messaging and the Disruptor (ch21)
# ============================================================================
{
    "num": 6,
    "label": "§6",
    "title": "Lock-free messaging and the Disruptor",
    "tagline": "Every mutable location has exactly one writer — that single property removes the lock entirely.",
    "divider_notes": (
        "This builds directly on the SPSC ring from earlier in the book and "
        "the cache-line discipline from Mechanical Sympathy. Neither "
        "introduces anything new on its own: the ring is the same "
        "structure, and the cursor tracking a consumer's read position is "
        "exactly the kind of hot, frequently-written word false sharing "
        "destroys if it lands on the wrong line. What the Disruptor pattern "
        "adds is a way to fan a single ring out to multiple independent "
        "consumers without reintroducing a lock."),
    "slides": [
        {
            "kind": "content",
            "title": "Sequence barriers coordinate fan-out without a lock",
            "body": [
                heading("A published sequence, and consumers that trail it", color=C.ACCENT_BLUE),
                bullet("each consumer owns an atomic sequence counter recording the last slot it has fully processed"),
                bullet("a consumer never coordinates with its peers directly — it compares its own sequence against the published one"),
                bullet("a dependent stage gates on both the producer's sequence and an upstream consumer's — ordering with no lock at all"),
                para("Back-pressure falls out of the same gating sequence: the producer can't overwrite a slot the slowest consumer hasn't read.",
                     size=Pt(14), italic=True, color=C.TEXT_MUTED),
            ],
            "diagram": dg("21-disruptor-ring"),
            "notes": (
                "Looked at as a messaging substrate rather than a generic container, the "
                "ring earns a different vocabulary: a producer doesn't push a value, it "
                "claims the next slot, writes into the object already sitting there, and "
                "publishes the slot as ready. Nothing is allocated or freed on the hot path, "
                "because nothing needs to be — capacity is fixed at construction and every "
                "slot is reused forever.\n\n"
                "Contrast this with a lock-based queue built on an unbounded container: a "
                "slow consumer there doesn't block the producer at all, the queue grows "
                "unchecked until something else makes the cost visible, usually at the worst "
                "possible moment. The ring's fixed capacity turns an invisible, unbounded "
                "liability into a visible, bounded one — back-pressure is loud and immediate "
                "rather than silent and deferred."),
        },
        {
            "kind": "content-code",
            "title": "Batching amortizes the synchronization cost",
            "body": [
                heading("Read the published sequence once, process every slot between", color=C.ACCENT_GREEN),
                bullet("one sequence-barrier read picks up ten queued events instead of ten separate reads"),
                bullet("the busier the producer, the larger the batches — the mechanism costs nothing extra at light load"),
                bullet("atomic wait/notify gives a cheap blocking fallback with no condition variable or futex wrapper to hand-roll"),
            ],
            "code": (
                "std::atomic<std::uint64_t> published{0};\n"
                "\n"
                "// Consumer: spin briefly, then block cheaply if\n"
                "// nothing new has arrived.\n"
                "std::uint64_t seen =\n"
                "    published.load(std::memory_order_acquire);\n"
                "published.wait(seen, std::memory_order_acquire);\n"
                "// returns when value != seen"
            ),
            "notes": (
                "The single-writer principle is why a single-producer Disruptor ring beats "
                "a lock-based queue on tail latency, not just average throughput. A mutex-"
                "protected queue serializes every producer and consumer through one critical "
                "section, and contention is exactly what happens under the bursty load "
                "patterns that matter in practice — a convoy effect where one slow operation "
                "under the lock delays everyone else waiting on it.\n\n"
                "Core placement dominates a Disruptor pipeline's measured performance inside "
                "a container: a busy-spin wait strategy under a CFS cpu.max quota exhausts "
                "its slice and gets throttled well before nproc-based assumptions suggest, "
                "visible directly as cpu.stat's throttled_usec. Pin the producer and each "
                "consumer to distinct physical cores, and avoid placing two of them on "
                "sibling hyperthreads of the same physical core."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 21,
            "demo_name": "A journal stage and a dependent business-logic stage",
            "demo_command": "cd examples/concurrency/21-lock-free-messaging-and-the-disruptor && ./demo.sh",
            "demo_description": (
                "A single-producer ring feeds two independent consumers, with the second "
                "gated on the first's sequence. Asserts every published event is consumed "
                "exactly once, in order, by both stages, that the dependent stage never "
                "reads past the journal's sequence, and that back-pressure actually engages."
            ),
            "demo_url": demo_url("21-lock-free-messaging-and-the-disruptor"),
            "notes": (
                "The ordering assertion is the one worth walking the room through: the "
                "business-logic stage must never read a slot the journal stage hasn't "
                "cleared, and that invariant is enforced by nothing but an atomic load and a "
                "comparison, with no lock anywhere in the pipeline.\n\n"
                "The 2011 LMAX whitepaper reported sustained throughput above twenty-five "
                "million messages per second against a lock-based queue roughly a thousand "
                "times slower on the hardware available at the time — worth citing as a "
                "data point about the shape of the win, not a number to expect on today's "
                "hardware. This example is where a reader measures their own numbers instead "
                "of trusting that one."),
        },
    ],
},

# ============================================================================
# §7 — Communication Models, Actors, and Channels (ch22 + ch23)
# ============================================================================
{
    "num": 7,
    "label": "§7",
    "title": "Communication models, actors, and channels",
    "tagline": "Shared memory buys throughput and pays in coupling; message passing buys isolation and pays in copies.",
    "divider_notes": (
        "Stepping outside a single address space: communication between "
        "separate processes, possibly separate machines, where the memory "
        "model no longer reaches and every hand-off crosses a boundary the "
        "kernel or a network mediates. The actor model and CSP-style "
        "channels then take message passing from a mechanism into a design "
        "discipline — structuring a whole concurrent program so the "
        "question 'which lock protects this data' never needs to be asked, "
        "because no two threads ever touch the same mutable data at all."),
    "slides": [
        {
            "kind": "content",
            "title": "Choosing a mechanism is a coupling decision",
            "body": [
                heading("Shared memory: zero-copy, tightest coupling, DIY sync", color=C.ACCENT_BLUE),
                bullet("shared memory maps the same pages into two address spaces — no copy, but no delivery guarantee at all without a futex and seqlock"),
                bullet("message passing moves discrete messages through a kernel-mediated channel — at least one copy, but loose coupling and built-in back-pressure"),
                bullet("UNIX sockets add SO_PEERCRED (kernel-verified credentials) and SCM_RIGHTS (open file descriptor transfer) that no network socket has"),
                bullet("length-prefix framing is close to universal for binary protocols — the reader's job is mechanical: read the length, read exactly that many bytes"),
            ],
            "diagram": dg("22-communication-families"),
            "notes": (
                "Most real systems use both families, at different layers: shared memory "
                "for the tightest, same-host, latency-critical hand-off — the ring-buffer "
                "channel from the previous section is, in the single-process case, exactly "
                "this pattern applied between threads rather than processes — and message "
                "passing for anything that needs to cross a process or machine boundary, "
                "tolerate a restart on either side, or sit off the latency-critical path.\n\n"
                "In a container, UNIX sockets and shared memory both assume a shared "
                "filesystem namespace that containers don't automatically give: a socket "
                "bound inside one container's /tmp is absent from another's entirely without "
                "an explicit bind-mounted volume, and shm_open names land in a tmpfs private "
                "to each container's mount namespace by default. TCP and UDP need none of "
                "this ceremony, which is why they're the default choice crossing a container "
                "boundary."),
        },
        {
            "kind": "content",
            "title": "Confinement: stronger than a lock, enforced by the compiler",
            "body": [
                heading("An actor's state isn't locked — it's unreachable", color=C.ACCENT_GREEN),
                bullet("an actor owns private state nothing outside it can touch, communicating only through a mailbox it alone reads"),
                bullet("a CSP channel is anonymous — neither sender nor receiver needs to know who, or how many, is on the other end"),
                bullet("a bounded mailbox is the actor-model analog of the Disruptor's back-pressure: an unbounded one hides the exact failure mode bounding makes visible"),
                bullet("move-only message types enforce confinement at compile time — a moved unique_ptr's sender can't dereference it without a visible compiler error"),
            ],
            "diagram": dg("23-actors-vs-channels"),
            "notes": (
                "This is a strictly stronger guarantee than 'protected by a mutex' — a mutex "
                "protects data that is still, structurally, shared, and a bug is one missed "
                "lock acquisition away from a race. An actor's state isn't locked at all; "
                "there's nothing to synchronize against from outside because nothing outside "
                "can reach it.\n\n"
                "The practical test for confinement in C++ is ownership, and the language "
                "already has the tool for enforcing it at compile time: a std::unique_ptr "
                "passed by value into a queue leaves the sender's own pointer null, and the "
                "compiler won't let the sender dereference it without that being a visible "
                "bug at the call site, not a race discovered under load. An unbounded "
                "mailbox under a memory-limited container is a straightforward way to get "
                "OOM-killed — size every mailbox's capacity explicitly."),
        },
        {
            "kind": "content-code",
            "title": "No framework needed: jthread, mailbox, move semantics",
            "body": [
                heading("The queue is the only state shared across the boundary", color=C.ACCENT_PURPLE),
                bullet("every message is moved in and moved out exactly once; a move-only payload makes the type refuse to compile if copied"),
                bullet("the actor's own total is a plain local variable inside run() — the only way to read it is to send a message and wait on the reply"),
                bullet("jthread's destructor requests a stop and joins automatically — exception-safe, leak-free shutdown with no separate call site"),
            ],
            "code": (
                "template <typename Msg>\n"
                "class Mailbox {\n"
                "public:\n"
                "    explicit Mailbox(std::size_t cap) : cap_(cap) {}\n"
                "    void send(Msg msg) {\n"
                "        std::unique_lock lock(mu_);\n"
                "        not_full_.wait(lock, [&] { return q_.size() < cap_; });\n"
                "        q_.push(std::move(msg));\n"
                "        not_empty_.notify_one();\n"
                "    }\n"
                "    std::optional<Msg> receive(std::stop_token st) {\n"
                "        std::unique_lock lock(mu_);\n"
                "        not_empty_.wait(lock, st, [&] { return !q_.empty(); });\n"
                "        if (q_.empty()) return std::nullopt;  // stop requested\n"
                "        Msg msg = std::move(q_.front());\n"
                "        q_.pop();\n"
                "        not_full_.notify_one();\n"
                "        return msg;\n"
                "    }\n"
                "private:\n"
                "    std::size_t cap_;\n"
                "    std::mutex mu_;\n"
                "    std::condition_variable_any not_empty_, not_full_;\n"
                "    std::queue<Msg> q_;\n"
                "};"
            ),
            "notes": (
                "This pattern is worth reaching for when a component's correctness is "
                "easier to state as 'processes one event at a time, in order, against "
                "private state' than as 'some invariant holds across several fields "
                "multiple threads touch' — an order book, a per-connection session, a state "
                "machine driving a device.\n\n"
                "It is not a general replacement for shared-state concurrency: a workload "
                "that needs many threads touching the same data concurrently for "
                "throughput gains nothing from forcing everything through one actor's "
                "single-threaded mailbox loop. A pool of actors is also directly constrained "
                "by a container's CPU quota in a way hardware_concurrency() won't reveal — "
                "size the pool from the configured quota, not the core count, and watch "
                "throttled_usec, not just end-to-end mailbox latency, when load climbs."),
        },
    ],
},

# ============================================================================
# §8 — Concurrent REST and gRPC Services (ch24 + ch25)
# ============================================================================
{
    "num": 8,
    "label": "§8",
    "title": "Concurrent REST and gRPC services",
    "tagline": "A REST or gRPC endpoint under real load is a concurrency problem wearing a protocol costume.",
    "divider_notes": (
        "The protocol framing is incidental; what determines whether a "
        "service stays responsive at a thousand connections or falls over "
        "at a hundred is the same set of decisions covered throughout "
        "this deck — how many threads actually run application "
        "code, how work gets handed to them, and what happens when more "
        "requests arrive than the service can finish in time. Boost.Asio "
        "and Beast for REST, gRPC's completion-queue API underneath all "
        "three of its surfaces, same underlying questions both times."),
    "slides": [
        {
            "kind": "content",
            "title": "Thread-per-request ties cost to connections, not work",
            "body": [
                heading("The async model decouples waiting on I/O from holding a thread", color=C.ACCENT_BLUE),
                bullet("thread-per-request's cost scales with concurrent connections, not request rate — ten thousand idle keep-alives need ten thousand threads"),
                bullet("an async event loop polls readiness across every open socket at once and dispatches a handler only when data is ready"),
                bullet("the price: handler code as asynchronous initiations and callbacks, and a callback firing after its captured object died is the model's signature bug"),
                bullet("back-pressure should reject, not block, for a deadline-bound endpoint — blocking just defers the same latency problem"),
            ],
            "notes": (
                "A service whose handlers do real, sustained CPU work per request can win "
                "outright with thread-per-request's simplicity — a pool sized to the core "
                "count, no event-loop indirection to debug. A service whose bottleneck is "
                "connection count and I/O wait needs the async model's lower per-connection "
                "cost to reach the connection counts a modern REST tier is expected to "
                "sustain.\n\n"
                "Overload shedding has to be cheap: checking an atomic counter and "
                "writing a fixed, pre-serialized 503 response, with no database call, no "
                "logging call that itself blocks on I/O. A shedding path that does "
                "meaningful work defeats its own purpose — a service shedding load because "
                "it's out of handler capacity, using handler capacity to shed it, degrades "
                "exactly like the overload it was meant to prevent."),
        },
        {
            "kind": "content-code",
            "title": "A Beast session outlives every operation it has in flight",
            "body": [
                heading("shared_from_this() inside every completion handler", color=C.ACCENT_GREEN),
                bullet("the session's lifetime is the detail easiest to get wrong — it has to survive until Beast's own internally issued operations finish too"),
                bullet("stream_.expires_after() sets a rolling per-operation deadline directly on the stream"),
                bullet("where a request actually runs is decided by which worker thread's io_context::run() call happens to be free"),
            ],
            "code": (
                "void do_read() {\n"
                "    req_ = {};\n"
                "    stream_.expires_after(std::chrono::seconds(10));\n"
                "    boost::beast::http::async_read(\n"
                "        stream_, buffer_, req_,\n"
                "        [self = shared_from_this()]\n"
                "        (boost::beast::error_code ec, std::size_t) {\n"
                "            if (!ec) self->handle_request();\n"
                "        });\n"
                "}"
            ),
            "notes": (
                "Beast builds HTTP parsing on top of Asio's asynchronous sockets without "
                "imposing a framework — no routing layer, no middleware chain, just a "
                "parser, a serializer, and the same async_read/async_write primitives any "
                "other Asio I/O uses. That minimalism keeps the concurrency structure "
                "visible instead of hidden behind a framework's own thread pool.\n\n"
                "Graceful shutdown ties directly to deadline propagation: on SIGTERM, stop "
                "accepting new connections immediately, then give in-flight requests the "
                "remainder of their own deadlines to finish, not a fixed extra grace period "
                "layered on top. A server that drains blindly for a fixed thirty seconds "
                "either kills requests that needed thirty-one or holds the process open "
                "twenty-nine seconds after every in-flight request already finished or timed "
                "out on its own."),
        },
        {
            "kind": "content",
            "title": "Completion queues: the one model under all three gRPC APIs",
            "body": [
                heading("Tag-based dispatch — a void* out, the same tag back", color=C.ACCENT_ORANGE),
                bullet("sync spends a thread blocked per call so application code never sees the queue; callback hides it behind gRPC's own managed pool"),
                bullet("every asynchronous operation is tagged on initiation; cq->Next() returns the tag unchanged, purely opaque to the queue itself"),
                bullet("a bidirectional stream owns multiple live tags at once — read and write completions can interleave in either order"),
                bullet("RESOURCE_EXHAUSTED is gRPC's 503 — an explicit, cheap rejection once in-flight calls exceed a configured cap"),
            ],
            "diagram": dg("25-grpc-completion-queue"),
            "notes": (
                "Picking a surface is really picking how much of the concurrency machinery "
                "to own directly. The raw async API trades more code for the ability to "
                "tune completion-queue count and thread assignment directly, which matters "
                "once a service's RPC concurrency outgrows what gRPC's default pool sizing "
                "assumes.\n\n"
                "Completion-queue count and thread-pool count are two separate numbers, and "
                "conflating them is the most common sizing mistake in a hand-rolled async "
                "server — a single shared queue still serializes dequeue through its own "
                "internal locking regardless of how many threads call Next() on it. gRPC's "
                "own guidance, roughly one completion queue per thread intended to service "
                "it exclusively, sidesteps that contention the same way per-worker deques "
                "sidestep a single shared task queue's lock."),
        },
        {
            "kind": "content",
            "title": "cpu.max, not hardware_concurrency(), sizes the pool",
            "body": [
                heading("The same oversubscription trap, both protocols", color=C.ACCENT_RED),
                bullet("hardware_concurrency() reflects a cpuset restriction but is blind to a CFS cpu.max quota — a container capped to two cores can still report sixty-four"),
                bullet("a pool sized from the host's full core count inside a throttled container doesn't get more capacity — it gets more threads taking turns on the same budget"),
                bullet("a channel cache (one long-lived channel per downstream target) keeps file-descriptor and keepalive cost bounded by topology rather than by traffic"),
                bullet("a gRPC server's graceful shutdown drains every completion queue before exit, or outstanding tags are simply abandoned rather than completed"),
            ],
            "notes": (
                "This is the same cgroup trap the Thread Pools chapter and this deck's "
                "Containers section both cover, applied without modification to a Beast "
                "server's io_context workers and a gRPC server's completion-queue servicing "
                "threads alike. More threads calling cq->Next() or io_context::run() than "
                "the quota can run concurrently pays for context switches out of a budget "
                "already fully spoken for.\n\n"
                "The failure mode is harder to spot than a clean throughput ceiling because "
                "it shows up as request-handling or RPC tail latency spikes rather than a "
                "flat plateau a dashboard makes obvious. Flip the health-check service to "
                "NOT_SERVING before a gRPC server stops accepting calls, so a load balancer "
                "or mesh routes around it before the process itself stops listening."),
        },
    ],
},

# ============================================================================
# §9 — Error Handling vs Exception Handling (ch26)
# ============================================================================
{
    "num": 9,
    "label": "§9",
    "title": "Error handling vs exception handling",
    "tagline": "A thread has no caller to return to. A future's producer and consumer run on different stacks.",
    "divider_notes": (
        "Every mechanism covered in this deck — futures, coroutines, lock-"
        "free structures, thread pools — moves a unit of work off the "
        "calling thread, and none of it answers what happens when that "
        "unit of work fails. Error handling that works fine single-"
        "threaded routinely breaks across these boundaries, usually by "
        "going silent rather than crashing loudly, which is the worse "
        "failure mode of the two."),
    "slides": [
        {
            "kind": "content",
            "title": "Who pays, and when",
            "body": [
                heading("Error codes: fixed cost every call. Exceptions: zero until thrown.", color=C.ACCENT_BLUE),
                bullet("the Itanium ABI's table-based unwinding means a function that never throws pays nothing extra for the possibility"),
                bullet("a std::thread's entry function has no caller frame to unwind into — an uncaught exception there calls std::terminate, no exceptions"),
                bullet("a coroutine's default promise makes the identical decision for the identical reason: no destination exists on the stack to catch it"),
                bullet("std::future is the one boundary with built-in store-and-rethrow — get() rethrows the exact exception object on the consumer's own thread"),
            ],
            "notes": (
                "On a hot path where a failure is routine rather than exceptional — a lock-"
                "free queue reporting itself full, a retry loop's expected-to-sometimes-miss "
                "cache lookup — the exception cost model is backwards: the common case is "
                "the one that wants to be cheapest, and an exception makes it free only by "
                "making the differentiating case disproportionately expensive.\n\n"
                "A production Task-style coroutine type avoids the default terminate by "
                "storing the exception in unhandled_exception() and rethrowing it when "
                "something asks for the result — hand-rolled, because the standard library "
                "ships the coroutine machinery without this convenience type. The pattern "
                "across all three boundaries is consistent: a synchronous throw/catch pair "
                "only works within one stack, so every mechanism that moves work onto "
                "another stack needs its own explicit convention."),
        },
        {
            "kind": "content-code",
            "title": "std::expected chains fallible steps with no exception in flight",
            "body": [
                heading("A real payload optional<T> never carried", color=C.ACCENT_GREEN),
                bullet("and_then, transform, or_else, transform_error — a flat sequence of transformations, no nested if (!result) guards"),
                bullet("every step is a branch on a tag bit, not a stack walk — the hot-path cost model error codes already had"),
                bullet("the strong exception-safety guarantee under a lock prevents a mid-update throw from handing the next thread a half-updated object"),
            ],
            "code": (
                "std::expected<Connection, ConnectError>\n"
                "connect(const Endpoint& ep) {\n"
                "    return resolve_dns(ep)\n"
                "        .and_then([](const Address& a) {\n"
                "            return tcp_connect(a); })\n"
                "        .and_then([](RawSocket s) {\n"
                "            return tls_handshake(s); })\n"
                "        .transform([](TlsSession s) {\n"
                "            return Connection{std::move(s)}; });\n"
                "}"
            ),
            "notes": (
                "std::optional tells a caller something is missing but not why — a "
                "std::optional<Connection> from a failed connect says nothing about whether "
                "the peer refused, DNS failed, or the handshake timed out. std::expected's "
                "second type parameter is built to carry exactly that reason as a first-"
                "class value.\n\n"
                "noexcept destructors keep RAII locking safe during unwinding for a specific "
                "reason: std::mutex::unlock() is specified never to throw, so lock_guard's "
                "destructor can't become the second exception in a two-exception pileup that "
                "would otherwise call std::terminate. A custom RAII wrapper doing something "
                "non-trivial in its destructor has to preserve that guarantee deliberately — "
                "a destructor that can throw is a loaded clause nobody checks until a "
                "different exception is already unwinding through it."),
        },
    ],
},

# ============================================================================
# §10 — Debugging Races, Deadlocks, and Sanitizers (ch27 + ch28)
# ============================================================================
{
    "num": 10,
    "label": "§10",
    "title": "Debugging races, deadlocks, and sanitizers",
    "tagline": "A correct-looking result this run is evidence of nothing — races are scheduling-dependent by nature.",
    "divider_notes": (
        "A race explained in the abstract teaches nothing about what to do "
        "the next time one shows up in a real codebase. This section builds "
        "one minimal, deliberately broken program for each failure mode, "
        "forces the failure to reproduce on demand rather than "
        "occasionally, and reads what gdb and ThreadSanitizer actually say "
        "about them, line by line — then broadens into the continuously-"
        "running tools that catch a defect before anyone needs a debugger "
        "at all."),
    "slides": [
        {
            "kind": "content",
            "title": "Forcing a deadlock open rather than hoping for it",
            "body": [
                heading("A std::latch turns 'sometimes' into 'every run'", color=C.ACCENT_RED),
                bullet("the textbook AB/BA deadlock can appear to work nine times out of ten on an idle, fast machine"),
                bullet("a latch initialized to the thread count, counted down right after each thread's first lock, guarantees both threads reach their second acquisition together"),
                bullet("thread apply all bt catches the cycle directly — one thread blocked in pthread_mutex_lock on the mutex the other already holds"),
                bullet("printing a mutex's own __data.__owner field names the owning thread id directly — read off live state, not inferred from source"),
            ],
            "diagram": dg("27-gdb-lock-cycle-backtrace"),
            "notes": (
                "A plain, uninstrumented run of a racy program can print the "
                "correct sum on one invocation and a corrupted total on the next, purely as "
                "a function of how the scheduler happened to interleave two threads' load-"
                "add-store sequences that time. Treating a correct print as proof is exactly "
                "backwards — the absence of a symptom is not the absence of the defect.\n\n"
                "gdb's multithreaded vocabulary layers on top of everything it already does "
                "for a single-threaded crash: info threads is the first command against a "
                "hung process, since a deadlock's signature sits right there — every thread "
                "involved inside a locking primitive, not inside application logic. "
                "set scheduler-locking on lets a session single-step one thread without "
                "every other thread racing ahead and scrambling the picture."),
        },
        {
            "kind": "diagram",
            "title": "Reading a ThreadSanitizer report",
            "diagram": dg("27-tsan-report-anatomy"),
            "caption": "Five sections, each mapped to a fact TSan's per-thread vector clock actually observed on this one execution.",
            "notes": (
                "Each section of a TSan report maps onto a specific fact the instrumentation "
                "observed during the one execution it just ran: the two conflicting writes "
                "with full call stacks, the raced-on location, and each thread's parentage "
                "reconstructed back to a human-meaningful creation site rather than an "
                "anonymous pthread id.\n\n"
                "The report's deeper mechanism is a vector clock per thread, updated at "
                "every synchronization point, tracking precisely which other threads' prior "
                "writes a given access is guaranteed to have observed. That's also the "
                "report's most important limitation: TSan is dynamic analysis, so a clean "
                "run means no race was observed on this execution's schedule and inputs, not "
                "that none exists in the program — a race gated behind a rare interleaving, "
                "or code TSan's instrumentation never touched, can sit undetected through an "
                "arbitrarily long run of clean reports."),
        },
        {
            "kind": "content",
            "title": "Two detection strategies, one answer",
            "body": [
                heading("TSan's vector clocks vs Helgrind's lockset-and-happens-before hybrid", color=C.ACCENT_PURPLE),
                bullet("compile-time instrumentation (TSan, ASan, UBSan) rebuilds the binary — cheap enough for every CI run, at 2-15x overhead depending on tool"),
                bullet("binary instrumentation (Helgrind, DRD) needs no rebuild at all — an order of magnitude slower, the trade worth making only when recompiling isn't an option"),
                bullet("Helgrind can flag a lock-order risk that hasn't manifested in any single run yet — a different signal from TSan's stricter 'only report what happened'"),
                bullet("ASan and TSan usually can't link into the same binary — two separate instrumented builds, not one combined one"),
            ],
            "diagram": dg("28-tsan-vs-helgrind-mechanism"),
            "notes": (
                "The right CI default is two purpose-built jobs rather than one heavyweight "
                "one: ASan+UBSan at roughly 2x as a required, blocking gate on every pull "
                "request; TSan at 5-15x, still cheap enough for every PR for most suites, "
                "scoped down to concurrency-relevant targets first if wall-clock time becomes "
                "a bottleneck, rather than dropped to a nightly schedule — a race caught a "
                "day late already merged into every branch built against it in the "
                "meantime.\n\n"
                "Helgrind or DRD at 10-50x is the one tier where a nightly or weekly job is "
                "the right trade, specifically because Valgrind's value is catching "
                "something the cheaper tools structurally cannot — no sanitizer runtime for "
                "a target, or confirming the exact shipped binary. A __attribute__(("
                "no_sanitize(\"thread\"))) annotation is the escape hatch for a deliberately "
                "racy benchmark-only function TSan would otherwise, correctly, flag."),
        },
    ],
},

# ============================================================================
# §11 — Observing Concurrency (ch29)
# ============================================================================
{
    "num": 11,
    "label": "§11",
    "title": "Observing concurrency",
    "tagline": "The pool clogging under a burst happens once, on a host with no debugger attached, and is gone by the time it's reported.",
    "divider_notes": (
        "A concurrent service in production affords none of the stop-"
        "rerun-instrument luxury the previous section relied on. "
        "Observability fills that gap with signals a running service emits "
        "continuously, cheap enough to leave on, specific enough to say "
        "which pool, which lock, and which percentile actually misbehaved. "
        "This instruments a service with OpenTelemetry and ships the "
        "result to an LGTM stack so the numbers are something to query, "
        "not something the program merely asserts about itself."),
    "slides": [
        {
            "kind": "content",
            "title": "Context does not cross a thread boundary on its own",
            "body": [
                heading("Thread-safe to call concurrently is not the same as correctly nested", color=C.ACCENT_BLUE),
                bullet("a span created on a pool's worker thread doesn't know it belongs to the request that submitted the work — nothing tells it"),
                bullet("the fix: capture the parent Context at submission, install a Scope as the first thing the worker's handler does"),
                bullet("a coroutine's suspend/resume pair has the identical problem — the Scope lived on a stack that's gone the moment it unwinds past suspension"),
                bullet("the frame carries its own copy of the Context, stored in the promise type, reinstalled on resume before any user code runs"),
            ],
            "diagram": dg("29-context-propagation"),
            "notes": (
                "This is the real subject of the chapter, not a footnote: a pool's worker "
                "threads creating spans concurrently is fine on its own — nothing about the "
                "SDK knows that a span on worker thread seven belongs to the same logical "
                "request as one created a moment earlier on the submitting thread. Getting "
                "that relationship right is a propagation problem, not a thread-safety "
                "problem.\n\n"
                "The first visible sign of getting this wrong is a dashboard full of single-"
                "span traces where a deep request tree was expected — a child span started "
                "inside a pool task without a reinstalled Scope doesn't fail, it silently "
                "starts a brand-new trace root. Nothing crosses a thread boundary implicitly; "
                "it has to be handed off as an explicit, owned value, the same discipline the "
                "Disruptor's single-writer principle and actor confinement both rest on."),
        },
        {
            "kind": "content-code",
            "title": "Flush before shutdown is a property of the type",
            "body": [
                heading("jthread + stop_token guarantee the last batch actually leaves", color=C.ACCENT_GREEN),
                bullet("starting a span isn't free — allocates, reads a clock, copies attributes — so instrument at request or batch grain, not per sub-microsecond iteration"),
                bullet("four metrics cover most of concurrency health: queue depth, lock wait time, task latency percentiles, contention counters"),
                bullet("label by pool or stage name — a small, bounded set known at compile time, never by anything unbounded like a request id"),
            ],
            "code": (
                "class InstrumentedWorker {\n"
                "public:\n"
                "    explicit InstrumentedWorker(telemetry::Handle t)\n"
                "        : t_(std::move(t)),\n"
                "          thread_([this](std::stop_token st) { run(st); }) {}\n"
                "    // destructor is implicit: jthread stops + joins\n"
                "\n"
                "private:\n"
                "    void run(std::stop_token st) {\n"
                "        while (!st.stop_requested()) process_next();\n"
                "        t_.flush_and_shutdown(std::chrono::seconds(5));\n"
                "    }\n"
                "    telemetry::Handle t_;\n"
                "    void process_next();\n"
                "    std::jthread thread_;\n"
                "};"
            ),
            "notes": (
                "A climbing lock-wait-time histogram with a flat hold-time distribution "
                "means threads are queued behind a lock that's fine once acquired; a "
                "climbing hold time means the critical section itself got slower — two "
                "failure modes that look identical from outside and need separate "
                "histograms to tell apart.\n\n"
                "In a container, the instrumented process has to reach the collector by its "
                "compose service name, not localhost, because localhost inside a container "
                "refers to that container alone. Batching introduces real, bounded memory "
                "pressure worth sizing deliberately — a batch span processor's buffer needs "
                "headroom above steady per-request allocation, or the buffer itself triggers "
                "an OOM kill in exactly the traffic spike the telemetry exists to explain."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 29,
            "demo_name": "An instrumented pool, a burst, and a real LGTM stack",
            "demo_command": "cd examples/concurrency/29-observing-concurrency && ./demo.sh",
            "demo_description": (
                "A multi-container compose stack: the instrumented thread-pool service, the "
                "grafana/otel-lgtm backend, and a profile-gated verifier that queries Tempo "
                "and Mimir, from ingested telemetry rather than the service's own claims "
                "about itself."
            ),
            "demo_url": demo_url("29-observing-concurrency"),
            "notes": (
                "This is the one demo in the deck that proves observability rather than "
                "describing it: the verifier queries Tempo through the collector for correct "
                "parent/child span nesting (request to task) and queries Mimir for the "
                "queue-depth metric actually rising during the burst and returning to zero "
                "after drain.\n\n"
                "The distinction: saturation was both "
                "produced and observed, not merely logged by the service and taken on faith. "
                "Walk through the compose topology if time allows: the service, the "
                "collector, and the LGTM backend, with Grafana as the one pane every signal "
                "resolves through."),
        },
    ],
},

# ============================================================================
# §12 — Coding Practices and Design Patterns (ch30 + ch31)
# ============================================================================
{
    "num": 12,
    "label": "§12",
    "title": "Coding practices and design patterns",
    "tagline": "A race that passes code review is a naming problem as often as it's a logic problem.",
    "divider_notes": (
        "Per-type habits — immutability by default, RAII locking, "
        "confinement, naming that makes a threading contract legible "
        "without reading the implementation — scale up into the "
        "architectures that decide how whole systems of well-behaved "
        "pieces fit together: pipelines, sharding, half-sync/half-async. "
        "None of these patterns is new; what's worth building is the "
        "vocabulary to name which one a given design actually is before "
        "the wrong one gets load-tested into a rewrite."),
    "slides": [
        {
            "kind": "content-code",
            "title": "A lock the compiler enforces, not a comment",
            "body": [
                heading("Monitor<T>: there is no path to the data except through here", color=C.ACCENT_BLUE),
                bullet("a data member named data_ next to a comment reading 'protected by mutex_' is not enforced — the compiler cannot read the comment"),
                bullet("a const accessor hiding a mutable cache is not thread-safe just because its signature promises not to mutate observable state"),
                bullet("a type with no thread-safety annotation should default to confined, never to assumed-shared"),
            ],
            "code": (
                "template <typename T>\n"
                "class Monitor {\n"
                "public:\n"
                "    explicit Monitor(T value) : value_(std::move(value)) {}\n"
                "\n"
                "    // only path to value_: a lock-holding call\n"
                "    template <typename F>\n"
                "    auto with_lock(F&& f) {\n"
                "        std::lock_guard lk(mutex_);\n"
                "        return std::forward<F>(f)(value_);\n"
                "    }\n"
                "\n"
                "private:\n"
                "    std::mutex mutex_;\n"
                "    T value_;\n"
                "};"
            ),
            "notes": (
                "Immutability is the cheapest way to avoid synchronizing access at all: an "
                "immutable value shared across threads needs no lock for reads, because "
                "there's no write for a read to race with. The recurring structural pattern "
                "is a snapshot — construct a new immutable version, publish it by swapping a "
                "pointer, and readers holding the old one keep reading a consistent, if "
                "slightly stale, value.\n\n"
                "Clang's Thread Safety Analysis turns part of this naming discipline into a "
                "compile-time check: GUARDED_BY and REQUIRES annotations let -Wthread-safety "
                "reject any access to a guarded member that isn't provably protected, for "
                "code that can't be restructured into a Monitor. Pinning the exact Clang "
                "version the annotations were validated against matters, because the "
                "diagnostics have changed in both directions across releases."),
        },
        {
            "kind": "content",
            "title": "Pipelines isolate phases; sharding parallelizes data",
            "body": [
                heading("SEDA stages each get their own pool and bounded queue", color=C.ACCENT_ORANGE),
                bullet("a queue boundary decouples each stage's throughput from its neighbors' and gives each one an independent admission-control point"),
                bullet("fan-out/fan-in extends the pattern to parallel replicas of one stage, joined with a std::latch set to N"),
                bullet("sharding partitions state by key with exactly one writer per shard — the single-writer principle generalized to a whole system"),
                bullet("the hard case is any operation spanning more than one shard — coordinate it explicitly, or redesign the key space to avoid it"),
            ],
            "diagram": dg("31-seda-pipeline"),
            "notes": (
                "The cost of a pipeline is the hand-off itself: every stage boundary is a "
                "context switch and usually a cache-cold start for the next stage's thread. "
                "A pipeline earns that cost back when stages differ in blocking "
                "behavior or resource profile, and is a poor fit for a request whose entire "
                "path is a few microseconds of uniform CPU work.\n\n"
                "A reactor dispatches on readiness; a proactor dispatches on completion, and "
                "io_uring pulls Linux's traditional epoll-based reactor toward the proactor "
                "shape. Half-sync/half-async keeps application code as ordinary blocking "
                "logic on a synchronous layer while a reactor or proactor handles I/O "
                "without ever blocking its own thread — the queueing layer between them "
                "needs the same explicit context propagation as any other thread hand-off."),
        },
        {
            "kind": "content-code",
            "title": "A sharded router: no lock, because no other writer",
            "body": [
                heading("Reached only through its own shard's mailbox", color=C.ACCENT_PURPLE),
                bullet("a request for key K routes to the shard owning K — consistent hash or modulo, a mechanical lookup"),
                bullet("total write throughput scales with shard count rather than being capped by one shared structure's serialization point"),
                bullet("resharding needs a brief quiesce on the migrating range, or a short-lived coordinator — a cost paid occasionally, not on every request"),
            ],
            "code": (
                "template <typename Key, typename State>\n"
                "class ShardedStore {\n"
                "public:\n"
                "    explicit ShardedStore(std::size_t n) : shards_(n) {}\n"
                "\n"
                "    void dispatch(const Key& key,\n"
                "        std::move_only_function<void(State&)> op) {\n"
                "        auto& shard =\n"
                "            shards_[std::hash<Key>{}(key) % shards_.size()];\n"
                "        shard.mailbox.send(std::move(op));\n"
                "    }\n"
                "\n"
                "private:\n"
                "    struct Shard {\n"
                "        Mailbox<std::move_only_function<void(State&)>>\n"
                "            mailbox{64};\n"
                "        std::jthread worker{[](std::stop_token) {}};\n"
                "    };\n"
                "    std::vector<Shard> shards_;\n"
                "};"
            ),
            "notes": (
                "This is the architecture behind partitioning a market-data feed or an "
                "order book by instrument symbol: each symbol's book has exactly one "
                "writer, so two symbols' updates never contend for the same lock. A tighter "
                "latency budget favors fewer hand-offs on the critical path — sharded single "
                "writers, or a tight reactor loop with no queueing layer at all for the "
                "hottest requests.\n\n"
                "A throughput-oriented batch system can afford a deeper pipeline, because "
                "its latency budget is measured in milliseconds rather than microseconds and "
                "the isolation a pipeline buys is worth more than the hand-off cost it adds. "
                "Real systems compose these rather than picking exactly one — a SEDA stage "
                "is often internally sharded, and a half-sync/half-async boundary often "
                "feeds the first stage of a pipeline."),
        },
    ],
},

# ============================================================================
# §13 — Concurrency in Containers (ch32)
# ============================================================================
{
    "num": 13,
    "label": "§13",
    "title": "Concurrency in containers",
    "tagline": "The kernel interface a program queries for CPU count and the limit that actually throttles it are unrelated code paths.",
    "divider_notes": (
        "Every thread pool, every allocator arena count, every polling "
        "loop in this book assumed a thread could see the machine it was "
        "actually running on. Inside a container that assumption breaks in "
        "a specific, mechanical way: cpu.max and cpuset.cpus are two "
        "independent cgroup v2 controls, easy to confuse because they're "
        "configured from the same --cpus flag or the same Kubernetes "
        "resources block, but enforced by unrelated kernel code paths."),
    "slides": [
        {
            "kind": "content",
            "title": "Two knobs, two different failure modes",
            "body": [
                heading("A time budget vs a fixed set of visible cores", color=C.ACCENT_BLUE),
                bullet("cpu.max is a time budget — 200 ms allowed per 100 ms period — enforced across every visible core, with no regard for which ones"),
                bullet("cpuset.cpus is a fixed set of CPU IDs — no period, no time accounting, no throttling event, ever"),
                bullet("a container can carry both at once, unrelated to each other, and behave completely differently under load depending on which binds"),
                bullet("hardware_concurrency() reflects cpuset correctly on glibc 2.36+ — and never reflects cpu.max at all"),
            ],
            "diagram": dg("32-quota-vs-cpuset"),
            "notes": (
                "Eight threads each getting twenty-five milliseconds of wall time on eight "
                "different cores exhausts a two-hundred-millisecond quota exactly as fast as "
                "two threads running flat out on two cores for a hundred milliseconds — the "
                "quota taxes total CPU-seconds, not core count, which is the detail that "
                "trips up a naive mental model of '--cpus=2 means two cores.'\n\n"
                "A Guaranteed-QoS Kubernetes pod with the CPU Manager static policy enabled "
                "is removed from cpu.max accounting entirely and instead granted exclusive, "
                "pinned cores through cpuset.cpus. Two pods that both 'request two cores' "
                "can be running under mechanically different enforcement, and a program "
                "that only reads cpu.max sees nothing meaningful on the pinned one, because "
                "no quota file is populated once a cgroup is cpuset-exclusive."),
        },
        {
            "kind": "stat-row",
            "title": "Two knobs, two different failure modes",
            "stats": [
                ("200000/100000", "cpu.max: a time budget in microseconds per period", C.ACCENT_BLUE),
                ("cpuset.cpus", "a fixed core set, zero time accounting, never throttles", C.ACCENT_GREEN),
                ("16", "hardware_concurrency() on a host, even inside a 2-core quota", C.ACCENT_RED),
                ("throttled_usec", "cpu.stat's direct, unambiguous evidence of CFS throttling", C.ACCENT_ORANGE),
            ],
            "notes": (
                "These four facts are the chapter's entire argument compressed to a glance. "
                "A quota-limited container on a large host reports the host's full core "
                "count regardless of how little CPU time it has actually been granted, "
                "because hardware_concurrency() answers 'how many cores can a thread be "
                "scheduled on,' not 'how much CPU time has this container been given' — a "
                "different question entirely, faithfully answered.\n\n"
                "cpu.stat's throttled_usec field, not throttled_time, is the direct evidence "
                "worth watching continuously: a climbing value under a fixed pool size is "
                "the clearest available signal that the quota, not the algorithm, is adding "
                "latency. Every pool a service creates or inherits — the application's own, "
                "OpenMP, TBB, the allocator's per-CPU arenas — is a source of the identical "
                "oversubscription at its defaults."),
        },
        {
            "kind": "content-code",
            "title": "Derive the pool size from the real constraint",
            "body": [
                heading("The tighter of cpuset count and cgroup quota, never below 1", color=C.ACCENT_GREEN),
                bullet("an orchestrator-supplied CPU_LIMIT wins outright — it already knows allocations a generic cgroup reader has to work harder to characterize"),
                bullet("pinning under a pure quota stops migration but buys no additional CPU time — the quota is accounted across the whole cgroup regardless"),
                bullet("pinning under a cpuset composes cleanly and is what Kubernetes' CPU Manager static policy grants a Guaranteed-QoS pod"),
            ],
            "code": (
                "unsigned recommended_cpu_pool_size() {\n"
                "    if (const char* env = std::getenv(\"CPU_LIMIT\")) {\n"
                "        double v = std::atof(env);\n"
                "        if (v > 0.0)\n"
                "            return std::max(1u,\n"
                "                (unsigned)std::floor(v));\n"
                "    }\n"
                "    unsigned affinity = affinity_cpu_count();\n"
                "    if (auto quota = cgroup_cpu_quota()) {\n"
                "        return std::max(1u, (unsigned)std::floor(\n"
                "            std::min(*quota, (double)affinity)));\n"
                "    }\n"
                "    return std::max(1u, affinity);\n"
                "}"
            ),
            "notes": (
                "For a latency-sensitive container, the practical rule follows directly "
                "from the two mechanisms: request whole, integer cores under a QoS class "
                "and CPU Manager configuration that grants cpuset-exclusive pinning rather "
                "than a shared time budget, pin hot-path threads explicitly within that set "
                "once running, and size every pool from the pinned core count rather than a "
                "host-wide probe.\n\n"
                "Where exclusive pinning isn't available and a shared quota is the reality, "
                "keep thread count at or below the quota and monitor throttled_usec "
                "continuously — a sustained climb there means the fix is a smaller pool or "
                "a larger quota, not a faster algorithm. This applies per stage in a "
                "pipeline, not once for the whole thing: each stage's pool sized off "
                "hardware_concurrency() can oversubscribe the aggregate quota even when "
                "each one looks reasonable on its own."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 32,
            "demo_name": "cgroup-probe, run under a tightening sequence of limits",
            "demo_command": "cd examples/concurrency/32-concurrency-in-containers && ./demo.sh --cpus=2",
            "demo_description": (
                "Prints hardware_concurrency(), the sched_getaffinity-derived cpuset count, "
                "and the cgroup v2 cpu.max quota side by side. Progressively narrowing "
                "--cpuset-cpus and --cpus separately shows the two numbers moving for two "
                "different reasons — and, left unconstrained, the oversubscription gap."
            ),
            "demo_url": demo_url("32-concurrency-in-containers"),
            "notes": (
                "Run it in three steps if time allows: bare host (numbers agree, or the "
                "quota reports unlimited), then --cpus=4 --cpuset-cpus=0-7 on a host with "
                "more than eight cores (cpuset count drops to 8, quota drops to 4.00 — two "
                "different numbers for two different reasons), then --cpus=2 alone with no "
                "cpuset restriction at all.\n\n"
                "That last step is the oversubscription scenario from the chapter's opening, "
                "reproduced on demand: the cpuset count jumps back to the full host count "
                "while the quota stays at 2.00. Running the probe alongside cat /sys/fs/"
                "cgroup/cpu.stat before and after a deliberately oversized pool makes "
                "throttled_usec climb visibly — the most convincing evidence in the deck "
                "that sizing from hardware_concurrency() alone is a real cost, not a "
                "theoretical one."),
        },
    ],
},

# ============================================================================
# §14 — Full example: Ingest, Match, Publish (ch33)
# ============================================================================
{
    "num": 14,
    "label": "§14",
    "title": "Full example: ingest, match, publish",
    "tagline": "A real low-latency service is never one technique running alone — it's several wired into stages.",
    "divider_notes": (
        "Every earlier chapter picked one concurrency model, one "
        "synchronization primitive, one workload, and measured it in "
        "isolation, which was a deliberate simplification. This closing "
        "section builds the wiring once, as a single order-book pipeline — "
        "ingest, match, publish — run under one workload, so the earlier "
        "chapters' individually-true claims can be checked against how "
        "they behave stacked on top of each other."),
    "slides": [
        {
            "kind": "diagram",
            "title": "Three stages, three concurrency models",
            "diagram": dg("33-pipeline-architecture"),
            "caption": "Many ingest threads feed a pinned single-writer match thread over a lock-free ring, fanning out through a second ring to publish threads.",
            "notes": (
                "Ingest is a thread pool, because connection handling parallelizes "
                "trivially. Match is exactly one thread, pinned to one core, because an "
                "order book is fundamentally a serial data structure — a lock around a "
                "shared book would only reintroduce, as a bottleneck, the serialization a "
                "single dedicated thread already gives for free.\n\n"
                "Publish is a small pool again, because encoding and writing to N "
                "independent subscriber connections is embarrassingly parallel work. Both "
                "ring boundaries are bounded rather than growable, which is what makes "
                "back-pressure visible instead of silent: when match falls behind, the "
                "ingest ring's gating sequence refuses new claims, and ingest threads "
                "respond BUSY rather than let an unbounded queue absorb the backlog."),
        },
        {
            "kind": "content",
            "title": "Verify which thread ran it — don't assume the diagram",
            "body": [
                heading("A single OTel span per stage, carrying gettid() as an attribute", color=C.ACCENT_BLUE),
                bullet("every match span in every trace should carry the identical thread.id attribute — exactly one, not N"),
                bullet("a match stage reporting more than one distinct thread id has broken the design's central correctness guarantee"),
                bullet("the ring-occupancy attribute at each hand-off makes synchronization cost visible rather than inferred"),
                bullet("end-to-end latency gets the full Chapter 18 discipline: warmed, repeated, p50/p99/p99.9 — never a single std::chrono delta"),
            ],
            "notes": (
                "This is a book-keeping discrepancy that produces no compiler warning and "
                "no crash on its own — only a bug serious enough to invalidate every "
                "correctness assumption the single-writer design depends on, surfacing much "
                "later as a data race nobody can reproduce. Verifying it with a real span "
                "attribute, rather than trusting the architecture diagram, is the "
                "instrument this deck has argued for throughout.\n\n"
                "Two load shapes matter: a sustained moderate rate exercises the steady-"
                "state path and produces the number a capacity-planning conversation "
                "actually wants, while a deliberate overload burst tests the back-pressure "
                "path specifically — the ingest ring should fill, BUSY responses should "
                "appear, and admitted orders' tail latency should stay bounded by the "
                "ring's fixed capacity rather than growing open-ended."),
        },
        {
            "kind": "content-code",
            "title": "A bounded spin, then a cheap fallback — never forever",
            "body": [
                heading("Cheap in both the hot case and the idle one", color=C.ACCENT_GREEN),
                bullet("the match thread busy-polls the ingest ring briefly, matching The Low-Latency Fast Path's busy-poll-versus-block trade-off directly"),
                bullet("a bounded spin budget keeps common-case latency at the busy-poll floor without pinning a core at 100% indefinitely"),
                bullet("std::expected carries a per-order outcome across the ring boundary — no exception, no stack on the other side to catch it"),
            ],
            "code": (
                "std::uint64_t seen =\n"
                "    ingest_ring.published.load(std::memory_order_acquire);\n"
                "for (int spins = 0; spins < kSpinBudget; ++spins) {\n"
                "    if (seen != last_claimed) break;\n"
                "    seen = ingest_ring.published.load(\n"
                "        std::memory_order_acquire);\n"
                "}\n"
                "if (seen == last_claimed) {\n"
                "    ingest_ring.published.wait(last_claimed,\n"
                "                                std::memory_order_acquire);\n"
                "}"
            ),
            "notes": (
                "Nearly every earlier chapter in this deck shows up here as a specific, "
                "consequential design decision rather than a technique chosen for its own "
                "sake: the acquire/release pairing underneath both rings' claim-and-publish "
                "sequences, the cache-line discipline keeping hot sequence counters away "
                "from cold event payloads, the coding-practices review discipline that "
                "keeps the match thread's single-writer invariant from eroding the first "
                "time a feature seems like it only needs to 'peek' at the book.\n\n"
                "Each stage runs as its own container in the companion example, with the "
                "match container alone given a cpuset-exclusive core pin. Running it "
                "without that pin, a quick deliberate misconfiguration, is a useful "
                "exercise on its own — the same workload under a shared quota shows CFS "
                "throttling pauses landing directly on the match thread's latency "
                "distribution, visible in both the recorded p99.9 and throttled_usec "
                "climbing in lockstep."),
        },
        {
            "kind": "demo-cue",
            "demo_num": 33,
            "demo_name": "The full pipeline, under sustained load and a burst",
            "demo_command": "cd examples/concurrency/33-ingest-match-publish && ./demo.sh",
            "demo_description": (
                "Runs pipeline once and checks that no accepted order was lost or "
                "duplicated through either ring, that the order book's own conservation "
                "counters balance, that match really is single-threaded, that the overload "
                "burst engaged back-pressure, and that p50/p99/p99.9 figures are present."
            ),
            "demo_url": demo_url("33-ingest-match-publish"),
            "notes": (
                "This is the deck's closing argument made runnable: no latency number in "
                "the chapter is presented as the book's own measurement, because a matching "
                "engine's achievable p99 depends on core topology, kernel configuration, and "
                "the specific hardware under test closely enough that a quoted figure would "
                "mislead a reader about their own hardware more than it would inform "
                "them.\n\n"
                "Point the room at what the verifier actually checks rather than a number on "
                "a slide: order conservation across both rings, single-threaded match "
                "enforced and verified (not assumed), back-pressure engaging under burst "
                "rather than memory growing unbounded, and percentiles present in the "
                "output. This is the example to run on a reader's own hardware for the real "
                "figures."),
        },
    ],
},

]
