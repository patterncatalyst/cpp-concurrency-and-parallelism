// concurrency/01-execution-models — the four execution models, instrumented
// with COUNTED observables instead of wall-clock duration.
//
// Doc 1 draws two independent axes -- concurrency (structure: how many
// tasks are outstanding) and parallelism (execution: how many CPUs are
// occupied at once) -- and names the four cells that result from crossing
// them. This program runs the same instrumented `process()` workload under
// all four and prints, per model, three counts that are reproducible in
// *sign* even when they are not reproducible in magnitude:
//
//   distinct_cpus  -- popcount of the union of every sched_getcpu() reading
//                     taken during the run (a vDSO read, Chapter 3).
//   max_inflight   -- high-water mark of a start/finish counter, recorded
//                     with the chapter's compare-exchange loop so the
//                     observation itself never serializes the tasks it's
//                     watching.
//   interleaves    -- count of tasks whose own two ticket draws (from one
//                     shared atomic counter, around a work window) were NOT
//                     consecutive -- proof some other task's sample point
//                     landed between them.
//
// The four models:
//   sequential          -- one for loop, no threads, pinned to one CPU so a
//                           lightly loaded host can't manufacture a false
//                           "it touched two CPUs" reading for a model that
//                           has no threads to legitimately do so.
//   concurrent_pinned    -- many jthreads, each self-pinned to the SAME cpu
//                           id: the structure is real, the parallelism is
//                           deliberately withheld.
//   parallel             -- std::for_each(std::execution::par, ...): one
//                           logical call, parallelism supplied entirely by
//                           the standard library's execution policy.
//   both (oversubscribed)-- more unpinned jthreads than cores.
//
// Usage: execution_models (no arguments). Prints one key=value summary line
// per model plus a leading num_available_cpus= line, all trivial to parse:
//
//   num_available_cpus=8
//   model=sequential distinct_cpus=1 max_inflight=1 interleaves=0
//   model=concurrent_pinned distinct_cpus=1 max_inflight=37 interleaves=241
//   model=parallel distinct_cpus=6 max_inflight=6 interleaves=199
//   model=both distinct_cpus=7 max_inflight=15 interleaves=203

#include <algorithm>
#include <atomic>
#include <bit>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <execution>
#include <pthread.h>
#include <sched.h>
#include <thread>
#include <vector>

namespace {

// How many tasks each of the single-core-structured models (sequential,
// concurrent_pinned, parallel) runs. Large enough to give std::execution::par
// and the OS scheduler real surface to spread work across cores or
// interleave tasks; small enough that even the fully-serialized sequential
// model finishes in well under a second.
constexpr int kTasks = 256;

// Three observables, all lock-free: a CPU-occupancy bitmap, an in-flight
// high-water mark, and a ticket-gap interleave counter. Deliberately NOT
// movable/copyable (it's all atomics) -- callers pass one in by reference
// per model run rather than returning it by value.
struct Observables {
    // Assumes CPU ids stay below 64, true for any host or container this
    // demo targets; a machine with 64+ logical CPUs would saturate this
    // bitmap's low 64 of them, which only means distinct_cpus could under-
    // count on hardware far larger than anything this demo needs.
    std::atomic<std::uint64_t> cpu_mask{0};
    std::atomic<int> inflight{0};
    std::atomic<int> max_inflight{0};
    std::atomic<std::uint64_t> ticket{0};
    std::atomic<std::uint64_t> interleaves{0};

    void record_cpu() {
        int cpu = sched_getcpu();
        if (cpu < 0 || cpu >= 64) return;
        cpu_mask.fetch_or(std::uint64_t{1} << cpu, std::memory_order_relaxed);
    }

    // Verbatim technique from the chapter: a compare-exchange loop records a
    // high-water mark without a lock around the counter, which would itself
    // serialize the very tasks the counter is trying to observe overlapping.
    void bump_max_inflight(int now) {
        int seen = max_inflight.load(std::memory_order_relaxed);
        while (now > seen &&
               !max_inflight.compare_exchange_weak(seen, now, std::memory_order_relaxed)) {
            // compare_exchange_weak refreshes `seen` on failure; retry until
            // this task wins the race or another task already recorded a
            // larger mark.
        }
    }

    int distinct_cpus() const {
        return std::popcount(cpu_mask.load(std::memory_order_relaxed));
    }
};

// Deterministic, timestamp-free "work": enough iterations to give the
// scheduler a real window in which to run something else, without depending
// on wall-clock sleep. The periodic yield() offers the scheduler a
// cooperative point to switch to another ready task -- on a single pinned
// CPU that's the only way two logically-concurrent tasks ever actually
// overlap in time, since nothing here blocks or sleeps. `volatile sink`
// keeps the optimizer from deleting the loop entirely.
volatile std::uint64_t sink = 0;

void busy_work() {
    std::uint64_t acc = 0;
    for (int chunk = 0; chunk < 4; ++chunk) {
        for (int i = 0; i < 50'000; ++i) {
            acc += static_cast<std::uint64_t>(i) * 2654435761u;
        }
        std::this_thread::yield();
    }
    sink = acc;
}

// The instrumented stand-in for the chapter's process(i): records CPU
// occupancy before and after the work window, tracks the in-flight
// high-water mark, and draws two tickets from a shared monotonic counter
// around that window. A gap between this task's own two tickets means some
// other task drew a ticket in between -- i.e. the scheduler interleaved
// another task's sample point with this one. No timestamps, no sleeps, no
// assumption about the scheduler's quantum.
void process(Observables& obs) {
    obs.record_cpu();

    int now = obs.inflight.fetch_add(1, std::memory_order_relaxed) + 1;
    obs.bump_max_inflight(now);

    std::uint64_t t1 = obs.ticket.fetch_add(1, std::memory_order_relaxed);
    busy_work();
    std::uint64_t t2 = obs.ticket.fetch_add(1, std::memory_order_relaxed);
    if (t2 != t1 + 1) {
        obs.interleaves.fetch_add(1, std::memory_order_relaxed);
    }

    obs.inflight.fetch_sub(1, std::memory_order_relaxed);
    obs.record_cpu();
}

// The CPU ids this process is currently allowed to run on -- its cpuset,
// which may be narrower than the host's full core count under a container
// CPU limit (Chapter 1's "permission vs outcome" distinction).
std::vector<int> available_cpus() {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    std::vector<int> cpus;
    if (sched_getaffinity(0, sizeof(cpu_set_t), &cpuset) != 0) {
        return cpus;
    }
    for (int i = 0; i < CPU_SETSIZE; ++i) {
        if (CPU_ISSET(i, &cpuset)) {
            cpus.push_back(i);
        }
    }
    return cpus;
}

// Pin the CALLING thread to one CPU id. Used both by the sequential model
// (pin main itself) and, self-applied, by each concurrent_pinned worker --
// self-pinning avoids the race a parent thread pinning a just-started child
// from outside would have against that child's first few instructions.
bool pin_this_thread(int cpu) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu, &cpuset);
    return sched_setaffinity(0, sizeof(cpu_set_t), &cpuset) == 0;
}

void print_result(const char* model, const Observables& obs) {
    std::printf("model=%s distinct_cpus=%d max_inflight=%d interleaves=%" PRIu64 "\n",
                model, obs.distinct_cpus(), obs.max_inflight.load(std::memory_order_relaxed),
                obs.interleaves.load(std::memory_order_relaxed));
}

// Model 1: sequential. One task runs to completion before the next begins;
// no threads exist at all. Pin the one and only thread in the process to a
// single CPU for the duration of this model so a lightly-loaded host's
// scheduler can't migrate it mid-run and manufacture a false "touched two
// CPUs" reading -- the model has no threads, so nothing else could
// legitimately touch a second one.
void run_sequential(Observables& obs, const std::vector<int>& cpus) {
    if (!cpus.empty()) {
        pin_this_thread(cpus[0]);
    }
    for (int i = 0; i < kTasks; ++i) {
        process(obs);
    }
}

// Model 2: concurrent, not parallel. kTasks jthreads, every one pinned to
// the SAME cpu id. The structure (many outstanding tasks) is real; the
// parallelism is withheld on purpose. jthread's destructor joins
// automatically as `workers` goes out of scope at the end of this function.
void run_concurrent_pinned(Observables& obs, const std::vector<int>& cpus) {
    int cpu0 = cpus.empty() ? 0 : cpus[0];
    std::vector<std::jthread> workers;
    workers.reserve(kTasks);
    for (int i = 0; i < kTasks; ++i) {
        (void)i;
        workers.emplace_back([cpu0, &obs] {
            pin_this_thread(cpu0);
            process(obs);
        });
    }
}

// Model 3: parallel, not concurrent. A single logical operation, fanned
// across cores by the standard library's execution policy, with no visible
// task structure in the source.
void run_parallel(Observables& obs) {
    std::vector<int> data(kTasks);
    for (int i = 0; i < kTasks; ++i) {
        data[i] = i;
    }
    std::for_each(std::execution::par, data.begin(), data.end(),
                  [&obs](int) { process(obs); });
}

// Model 4: concurrent and parallel. More runnable tasks than cores,
// unpinned -- the ordinary shape of an oversubscribed thread pool.
void run_oversubscribed(Observables& obs) {
    unsigned hc = std::thread::hardware_concurrency();
    if (hc == 0) {
        hc = 2;
    }
    const unsigned n_workers = 2 * hc;
    std::vector<std::jthread> workers;
    workers.reserve(n_workers);
    for (unsigned i = 0; i < n_workers; ++i) {
        workers.emplace_back([&obs] { process(obs); });
    }
}

} // namespace

int main() {
    // Snapshot the process's starting affinity so it can be restored after
    // the sequential model pins the main thread down to one CPU -- a new
    // thread inherits the affinity mask of the thread that creates it, and
    // std::execution::par's thread pool is typically created lazily on its
    // first use. Leaving the main thread pinned to a single CPU past
    // run_sequential() would risk confining that pool (and any later
    // unpinned jthreads) to the same one CPU, making "parallel" and "both"
    // unable to touch more than one CPU through no fault of their own code.
    cpu_set_t original;
    CPU_ZERO(&original);
    bool have_original = (sched_getaffinity(0, sizeof(original), &original) == 0);

    auto cpus = available_cpus();
    std::printf("num_available_cpus=%zu\n", cpus.size());

    {
        Observables obs;
        run_sequential(obs, cpus);
        print_result("sequential", obs);
    }

    if (have_original) {
        sched_setaffinity(0, sizeof(original), &original);
    }

    {
        Observables obs;
        run_concurrent_pinned(obs, cpus);
        print_result("concurrent_pinned", obs);
    }
    {
        Observables obs;
        run_parallel(obs);
        print_result("parallel", obs);
    }
    {
        Observables obs;
        run_oversubscribed(obs);
        print_result("both", obs);
    }

    return 0;
}
