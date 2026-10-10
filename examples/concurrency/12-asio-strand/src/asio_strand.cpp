// concurrency/12-asio-strand — strand-vs-mutex: serialization without a lock.
//
// The chapter's central claim: posting the SAME unsynchronized-counter
// handler two different ways through Boost.Asio changes correctness, and
// posting an equivalent handler guarded by a strand versus a std::mutex
// changes how often the kernel gets involved, without changing the
// arithmetic either way. This program runs four experiments, selected by
// --mode, all in-process (no sockets, no TCP port):
//
//   --mode strand        N handlers posted through a single shared strand,
//                         drained by a multithreaded io_context. Asio's own
//                         guarantee is that handlers posted to the same
//                         strand never run concurrently with each other, no
//                         matter how many threads call run() -- so the
//                         unsynchronized counter must come back exactly N,
//                         and no handler should ever observe another one
//                         already "inside" the critical section.
//   --mode nostrand       The identical handler body, posted straight to
//                         the io_context instead of through a strand.
//                         Nothing else changes. With no serialization
//                         guarantee, two handlers CAN run concurrently on
//                         two different worker threads, and the counter's
//                         read-modify-write (unsynchronized by design) can
//                         lose updates.
//   --mode strand-cost    An equivalent-work pair (plain ++counter, none of
//   --mode mutex-cost     the race-demo's instrumentation) comparing a
//                         strand's and a std::mutex's cost for the same
//                         correct-either-way result: how often a worker
//                         thread had to go through the kernel to get there.
//
// Why a race needs forcing, not just hoping: a bare `++counter` on a
// handful of threads can race in principle but, in practice, often
// executes too fast for two handlers to ever truly overlap on a given
// host/scheduler, especially on constrained CI hardware. The race-demo
// handler (race_handler_body below) widens the window deliberately: it
// reads the counter, calls std::this_thread::yield() -- an explicit
// scheduling point -- then spins a little longer before writing back.
// Through a strand this is still always safe: Asio's serialization
// guarantee holds regardless of how long a handler occupies its thread, or
// whether it yields mid-handler, because another thread calling run()
// simply will not dequeue a second handler from the SAME strand while one
// is already running -- it looks for other ready work (or, with none
// available, becomes idle) instead. Posted with no strand at all, the same
// yield() is instead the thing that lets another already-dequeued handler
// on another worker thread interleave for certain, rather than merely by
// chance -- which is what makes the "no-strand" case's overlap count a
// deterministic, CI-reliable signal instead of a coin flip.
//
// The kernel-cost comparison intentionally drops that widening: it isn't
// measuring whether a race can be forced, only how expensive going through
// the kernel is for equivalent, correct, contended work. Counting actual
// futex(2) calls needs strace -f -c -e trace=futex, which needs a ptrace
// capability this project's demo.sh does not grant the container (a plain
// `docker run --rm`, per the base convention). getrusage(RUSAGE_THREAD)'s
// ru_nvcsw -- voluntary context switches -- is the portable proxy used
// instead: a thread that blocks on a contended std::mutex's futex(FUTEX_WAIT)
// and is later woken records a voluntary context switch; a strand, per the
// chapter, "never puts a thread to sleep at all" for the handler it's
// running, so it should need measurably fewer of them for the same work.
// This comparison is SOFT and informational only (see verify.lua) --
// reported, never asserted to a fixed ratio.
//
// Output is one line in a key=value form a shell or Lua harness can parse
// without any special grammar, e.g.:
//
//   mode=strand threads=6 n=4000 counter=4000 expected=4000 overlaps=0 active_max=1 distinct_tids=6 elapsed_ms=8.112
//   mode=nostrand threads=6 n=4000 counter=3958 expected=4000 overlaps=112 active_max=3 distinct_tids=6 elapsed_ms=6.004
//   mode=strand-cost threads=6 n=4000 counter=4000 voluntary_ctxt_switches=14 elapsed_ms=5.201
//   mode=mutex-cost threads=6 n=4000 counter=4000 voluntary_ctxt_switches=389 elapsed_ms=7.845

// gettid() and RUSAGE_THREAD are Linux/glibc extensions gated behind
// _GNU_SOURCE. g++ defines this for C++ translation units by default, but
// that behavior isn't a cross-compiler guarantee this project wants to
// lean on (the project also targets clang) -- define it explicitly instead
// of relying on a driver default.
#define _GNU_SOURCE 1

#include <boost/asio/io_context.hpp>
#include <boost/asio/post.hpp>
#include <boost/asio/strand.hpp>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <sys/resource.h>
#include <unistd.h>

#include <fmt/core.h>

namespace asio = boost::asio;

namespace {

constexpr std::uint64_t kDefaultN = 4000;
constexpr unsigned kMinThreads = 4;
constexpr unsigned kMaxThreads = 8;
constexpr int kDefaultSpin = 300;

// Clamp the worker-pool size to a range wide enough to make the no-strand
// case's overlap virtually certain (several threads really do call run()
// concurrently) without spawning more OS threads than a modest container
// CPU quota can usefully schedule.
unsigned pick_thread_count() {
    unsigned hc = std::thread::hardware_concurrency();
    if (hc < kMinThreads) hc = kMinThreads;
    if (hc > kMaxThreads) hc = kMaxThreads;
    return hc;
}

void bump_max(std::atomic<long>& running_max, long candidate) {
    long prev = running_max.load(std::memory_order_relaxed);
    while (candidate > prev &&
           !running_max.compare_exchange_weak(prev, candidate, std::memory_order_relaxed)) {
        // retry with the updated prev
    }
}

// ── Race demo: strand vs. no strand ─────────────────────────────────────

struct RaceStats {
    long counter = 0;                // deliberately unsynchronized
    std::atomic<int> active{0};      // handlers currently inside the section below
    std::atomic<long> active_max{0};
    std::atomic<long> overlaps{0};   // entries that found >=1 other handler already in
};

struct RaceResult {
    long counter = 0;
    long overlaps = 0;
    long active_max = 0;
    std::size_t distinct_tids = 0;
    double elapsed_ms = 0.0;
};

// The handler body itself. See the file header for why the yield() and the
// spin loop are both there: they widen the window just enough that, when
// nothing serializes these handlers, two of them really do overlap --
// deterministically, not by luck of the scheduler.
void race_handler_body(RaceStats& stats, int spin) {
    int now = stats.active.fetch_add(1, std::memory_order_acq_rel) + 1;
    bump_max(stats.active_max, now);
    if (now > 1) {
        stats.overlaps.fetch_add(1, std::memory_order_relaxed);
    }

    long tmp = stats.counter;    // unsynchronized read
    std::this_thread::yield();   // explicit scheduling point, mid-"critical section"
    for (volatile int i = 0; i < spin; ++i) {
        // widen the window a little further than yield() alone guarantees
    }
    stats.counter = tmp + 1;     // unsynchronized write -- lost updates possible here

    stats.active.fetch_sub(1, std::memory_order_acq_rel);
}

RaceResult run_race(bool use_strand, std::uint64_t n, unsigned threads, int spin) {
    asio::io_context ioc;
    asio::strand<asio::io_context::executor_type> strand(ioc.get_executor());

    RaceStats stats;
    std::mutex tid_mtx;
    std::set<pid_t> tids; // tiny topology probe: which OS threads ran a handler

    auto handler = [&] {
        {
            std::lock_guard<std::mutex> lk(tid_mtx);
            tids.insert(::gettid());
        }
        race_handler_body(stats, spin);
    };

    for (std::uint64_t i = 0; i < n; ++i) {
        if (use_strand) {
            asio::post(strand, handler);
        } else {
            asio::post(ioc, handler);
        }
    }

    auto start = std::chrono::steady_clock::now();
    std::vector<std::thread> pool;
    pool.reserve(threads);
    for (unsigned t = 0; t < threads; ++t) {
        pool.emplace_back([&] { ioc.run(); });
    }
    for (auto& t : pool) t.join();
    auto end = std::chrono::steady_clock::now();

    RaceResult r;
    r.counter = stats.counter;
    r.overlaps = stats.overlaps.load(std::memory_order_relaxed);
    r.active_max = stats.active_max.load(std::memory_order_relaxed);
    r.distinct_tids = tids.size();
    r.elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
    return r;
}

// ── Kernel-cost comparison: strand vs. mutex, equivalent work ───────────

struct CostStats {
    long counter = 0;
    std::mutex mtx; // only locked by the mutex-cost variant
    std::atomic<long> voluntary_ctxt_switches{0};
};

struct CostResult {
    long counter = 0;
    long voluntary_ctxt_switches = 0;
    double elapsed_ms = 0.0;
};

CostResult run_cost(bool use_mutex, std::uint64_t n, unsigned threads) {
    asio::io_context ioc;
    asio::strand<asio::io_context::executor_type> strand(ioc.get_executor());

    CostStats stats;

    auto handler = [&] {
        if (use_mutex) {
            std::lock_guard<std::mutex> lock(stats.mtx);
            ++stats.counter;
        } else {
            ++stats.counter; // strand already serializes -- no lock needed
        }
    };

    for (std::uint64_t i = 0; i < n; ++i) {
        if (use_mutex) {
            asio::post(ioc, handler);
        } else {
            asio::post(strand, handler);
        }
    }

    auto start = std::chrono::steady_clock::now();
    std::vector<std::thread> pool;
    pool.reserve(threads);
    for (unsigned t = 0; t < threads; ++t) {
        pool.emplace_back([&] {
            ioc.run();
            // Snapshot this worker thread's own lifetime rusage right as it
            // finishes -- RUSAGE_THREAD reports the calling thread only, so
            // this must run on the thread it describes, before it exits.
            rusage ru{};
            ::getrusage(RUSAGE_THREAD, &ru);
            stats.voluntary_ctxt_switches.fetch_add(
                static_cast<long>(ru.ru_nvcsw), std::memory_order_relaxed);
        });
    }
    for (auto& t : pool) t.join();
    auto end = std::chrono::steady_clock::now();

    CostResult r;
    r.counter = stats.counter;
    r.voluntary_ctxt_switches = stats.voluntary_ctxt_switches.load(std::memory_order_relaxed);
    r.elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
    return r;
}

} // namespace

int main(int argc, char** argv) {
    std::string mode = "strand";
    std::uint64_t n = kDefaultN;
    unsigned threads = pick_thread_count();
    int spin = kDefaultSpin;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--mode" && i + 1 < argc) {
            mode = argv[++i];
        } else if (arg == "-n" && i + 1 < argc) {
            n = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-t" && i + 1 < argc) {
            threads = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
        } else if (arg == "--spin" && i + 1 < argc) {
            spin = std::atoi(argv[++i]);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print(
                "usage: asio_strand --mode strand|nostrand|strand-cost|mutex-cost "
                "[-n POSTS] [-t THREADS] [--spin ITER]\n");
            return 0;
        }
    }

    if (threads < 1) threads = 1;

    if (mode == "strand" || mode == "nostrand") {
        bool use_strand = (mode == "strand");
        RaceResult r = run_race(use_strand, n, threads, spin);
        fmt::print(
            "mode={} threads={} n={} counter={} expected={} overlaps={} "
            "active_max={} distinct_tids={} elapsed_ms={:.3f}\n",
            mode, threads, n, r.counter, n, r.overlaps, r.active_max,
            r.distinct_tids, r.elapsed_ms);
    } else if (mode == "strand-cost" || mode == "mutex-cost") {
        bool use_mutex = (mode == "mutex-cost");
        CostResult r = run_cost(use_mutex, n, threads);
        fmt::print(
            "mode={} threads={} n={} counter={} voluntary_ctxt_switches={} "
            "elapsed_ms={:.3f}\n",
            mode, threads, n, r.counter, r.voluntary_ctxt_switches, r.elapsed_ms);
    } else {
        fmt::print(stderr, "unknown --mode '{}' (want strand|nostrand|strand-cost|mutex-cost)\n",
                   mode);
        return 1;
    }

    return 0;
}
