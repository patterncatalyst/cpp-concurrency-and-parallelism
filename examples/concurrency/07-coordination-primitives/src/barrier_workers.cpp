// concurrency/07-coordination-primitives — a barrier-phased worker pool.
//
// A fixed pool of `workers` threads runs through `phases` rounds,
// synchronized by one std::barrier. In each phase, every worker writes a
// deterministic partial value into its own slot (no two workers ever touch
// the same slot, so there is no race on the write side), then calls
// arrive_and_wait(). Once every worker has arrived, std::barrier's
// completion function -- which the standard guarantees runs exactly once
// per phase, on exactly one of the arriving threads, after all have
// arrived and before any is released -- sums the slots into a running
// total and prints one line recording that phase's result, before the
// barrier resets its count and releases everyone into the next phase.
//
// Each worker's slot value is deterministic: worker `id`'s contribution in
// phase `p` (both zero-indexed) is `(p + 1) * (id + 1)`. That makes the
// expected final total a closed form:
//
//   sum over p in [0, phases)  of  (p+1)  *  sum over id in [0, workers) of (id+1)
//     = ( phases   * (phases   + 1) / 2 )
//     * ( workers  * (workers  + 1) / 2 )
//
// which is exactly what verify.lua recomputes and compares against this
// program's own reported final_total -- a check on the arithmetic, not a
// hard-coded magic number.
//
// Usage:
//   barrier_workers [-w WORKERS] [-p PHASES]
//
// Output: one line per phase as the completion function runs --
//   phase=0 completion merged_sum=10 running_total=10
// -- followed by a final summary line:
//   workers=4 phases=5 final_total=150

#include <barrier>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include <fmt/core.h>

namespace {

constexpr int kDefaultWorkers = 4;
constexpr int kDefaultPhases = 5;

} // namespace

int main(int argc, char** argv) {
    int num_workers = kDefaultWorkers;
    int num_phases = kDefaultPhases;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-w" && i + 1 < argc) {
            num_workers = std::atoi(argv[++i]);
        } else if (arg == "-p" && i + 1 < argc) {
            num_phases = std::atoi(argv[++i]);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: barrier_workers [-w WORKERS] [-p PHASES]\n");
            return 0;
        }
    }

    if (num_workers < 1) {
        num_workers = 1;
    }
    if (num_phases < 1) {
        num_phases = 1;
    }

    std::vector<std::uint64_t> slots(static_cast<std::size_t>(num_workers), 0);
    std::uint64_t running_total = 0;
    int phase_counter = 0;

    // Completion function: the standard guarantees this runs exactly once
    // per phase, on exactly one of the arriving threads, strictly after
    // every worker has called arrive_and_wait() for this phase and
    // strictly before any of them is released into the next one. That
    // ordering is what makes reading every slot here race-free without any
    // extra lock: the barrier itself is the synchronization.
    auto completion = [&] {
        std::uint64_t phase_sum = 0;
        for (auto value : slots) {
            phase_sum += value;
        }
        running_total += phase_sum;
        fmt::print("phase={} completion merged_sum={} running_total={}\n",
            phase_counter, phase_sum, running_total);
        ++phase_counter;
    };

    std::barrier sync_point(num_workers, completion);

    auto worker = [&](int id) {
        for (int phase = 0; phase < num_phases; ++phase) {
            // Each worker owns exactly one slot; no two workers ever write
            // the same index, so this assignment needs no synchronization
            // of its own -- the barrier below is what makes it visible to
            // the completion function.
            slots[static_cast<std::size_t>(id)] =
                static_cast<std::uint64_t>(phase + 1) * static_cast<std::uint64_t>(id + 1);
            sync_point.arrive_and_wait();
        }
    };

    std::vector<std::thread> threads;
    threads.reserve(static_cast<std::size_t>(num_workers));
    for (int id = 0; id < num_workers; ++id) {
        threads.emplace_back(worker, id);
    }
    for (auto& t : threads) {
        t.join();
    }

    fmt::print("workers={} phases={} final_total={}\n",
        num_workers, num_phases, running_total);

    return 0;
}
