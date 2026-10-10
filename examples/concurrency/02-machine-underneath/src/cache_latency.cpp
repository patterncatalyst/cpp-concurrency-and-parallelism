// concurrency/02-machine-underneath — cache-hierarchy latency probe.
//
// Doc 02 claims a rough latency shape for the cache hierarchy (Figure
// 2.1): roughly 4 cycles for an L1 hit, roughly 12 for L2, roughly 40 for
// a shared L3, and 100-300 cycles once a miss falls all the way through to
// DRAM. This program measures that shape directly rather than citing it,
// using the standard pointer-chase technique: build a single-cycle random
// permutation over an array of cache-line-sized (64-byte) nodes, then time
// how long it takes, on average, to walk one link of that cycle, for a
// handful of working-set sizes chosen to step through L1, L2, L3, and past
// all of them into DRAM.
//
// The chase order is a random permutation, not a stride, which matters:
// a linear or strided walk is exactly what a hardware prefetcher is built
// to predict, and would measure prefetch-assisted bandwidth instead of
// real memory latency. A random single-cycle permutation makes every load
// address depend on the *value* of the previous load -- the next address
// genuinely cannot be known until the current one completes -- so the
// prefetcher has nothing to work with and the measured time reflects the
// latency this chapter is about.
//
// NUMA (local-node vs. remote-node access latency) is deliberately NOT
// covered here. Doc 02 introduces NUMA topology, but the worked comparison
// lives in Doc 16 and
// examples/concurrency/16-numa-affinity-and-data-locality/, which runs in
// the KVM lab (see the lgtm-systems-programming skill) because a real
// multi-node NUMA topology and exclusive core isolation aren't reliably
// available inside a container -- see this file's own README for why.
//
// Usage:
//   cache_latency [--trials N] [--accesses N]
//
// Prints one line per working-set size, in increasing size order, in a
// key=value form a shell or a Lua harness can parse without any special
// grammar:
//
//   step=1 label=L1 size_kib=8 nodes=128 trials=3 accesses=2000000 \
//     ns_per_access=1.823 chase_sink=1724
//
// `ns_per_access` is the minimum over `trials` independent timed runs
// (minimum, not mean, is the standard way to suppress scheduler-noise
// outliers in a microbenchmark like this one -- any individual run can be
// slowed down by a stray preemption, but nothing makes one run faster than
// the hardware actually allows). `chase_sink` is the final node index the
// chase landed on; it is printed, not discarded, purely so the compiler
// cannot prove the chase loop's result is unused and optimize the whole
// thing away.

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <new>
#include <numeric>
#include <random>
#include <sched.h>
#include <pthread.h>
#include <string>
#include <vector>

#include <fmt/core.h>

namespace {

#if defined(__cpp_lib_hardware_interference_size)
constexpr std::size_t kLineSize = std::hardware_destructive_interference_size;
#else
constexpr std::size_t kLineSize = 64;
#endif

// Every node is padded to exactly one cache line. Without this, several
// 8-byte "next" links would share a line and the chase would measure a
// mix of in-line and cross-line jumps instead of one line fetched per
// access -- the padding is what makes "size" in the step table below mean
// "bytes of cache footprint touched", not just "bytes of payload".
struct alignas(kLineSize) Node {
    std::uint64_t next;
    char pad[kLineSize - sizeof(std::uint64_t)];
};
static_assert(sizeof(Node) == kLineSize, "Node must be exactly one cache line");

// Default working-set sizes, each roughly 16x the last, chosen to land
// solidly inside L1, inside L2, at the L2/L3 boundary, inside a large L3,
// and (the last step) far enough past any realistic L3 to guarantee most
// accesses miss all the way to DRAM. The 16x gaps are deliberate: real
// cache sizes vary across machines, but the gaps are wide enough that the
// *ordering* of average latency across these five steps should hold
// regardless of exactly where a given CPU's L1/L2/L3 boundaries fall --
// the hard claim this example makes is about that ordering, not about
// matching any specific cycle count.
struct SizeStep {
    const char* label;
    std::uint64_t bytes;
};

const std::vector<SizeStep> kSteps = {
    {"L1",    8ULL * 1024},
    {"L2",    128ULL * 1024},
    {"L2/L3", 2ULL * 1024 * 1024},
    {"L3",    32ULL * 1024 * 1024},
    {"DRAM",  256ULL * 1024 * 1024},
};

// A timed chase needs enough total accesses that the elapsed time clears
// the OS timer's practical resolution (a handful of milliseconds, not
// microseconds) even for the fastest, smallest working set -- otherwise
// scheduling jitter dominates the measurement. For working sets bigger
// than this floor, use at least one full lap of the cycle so every node
// gets touched during the timed window, not just during warm-up.
constexpr std::uint64_t kDefaultAccessesFloor = 2'000'000ULL;
constexpr int kDefaultTrials = 3;

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

// Pin the current (main) thread to one CPU, best-effort. This is a
// single-threaded benchmark -- the point of pinning here isn't to avoid
// false sharing between threads (there's only one), it's to stop the
// scheduler from migrating the chase mid-run onto a core with a cold
// cache of its own, which would show up as bogus latency noise unrelated
// to the working-set size being measured.
bool pin_self_to_cpu(int cpu) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu, &cpuset);
    return pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset) == 0;
}

// Build a single Hamiltonian cycle over n nodes: a uniformly shuffled
// permutation, linked node-to-next-in-permutation-order, wrapping back to
// the start. Every node is visited exactly once per lap, in an order with
// no exploitable stride, and the whole array is reachable from node 0.
std::vector<Node> build_chase(std::uint64_t n, std::mt19937_64& rng) {
    std::vector<std::uint64_t> order(n);
    std::iota(order.begin(), order.end(), 0ULL);
    std::shuffle(order.begin(), order.end(), rng);

    std::vector<Node> nodes(n);
    for (std::uint64_t i = 0; i < n; ++i) {
        nodes[order[i]].next = order[(i + 1) % n];
    }
    return nodes;
}

struct ChaseResult {
    double ns_per_access;
    std::uint64_t sink;
};

// Walk `accesses` links of the cycle starting from `start`, timing the
// whole walk. The loop body's only side effect visible outside the loop
// is `idx` itself (returned as `sink`), and each load's address depends
// on the previous load's value -- together, that's what stops a compiler
// from either hoisting the chase or deleting it as dead code.
ChaseResult chase(const std::vector<Node>& nodes, std::uint64_t accesses, std::uint64_t start) {
    std::uint64_t idx = start;
    auto t0 = std::chrono::steady_clock::now();
    for (std::uint64_t i = 0; i < accesses; ++i) {
        idx = nodes[idx].next;
    }
    auto t1 = std::chrono::steady_clock::now();
    double ns = std::chrono::duration<double, std::nano>(t1 - t0).count();
    return {ns / static_cast<double>(accesses), idx};
}

} // namespace

int main(int argc, char** argv) {
    int trials = kDefaultTrials;
    std::uint64_t accesses_floor = kDefaultAccessesFloor;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--trials" && i + 1 < argc) {
            trials = std::atoi(argv[++i]);
        } else if (arg == "--accesses" && i + 1 < argc) {
            accesses_floor = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: cache_latency [--trials N] [--accesses N]\n");
            return 0;
        }
    }
    if (trials < 1) trials = 1;

    auto cpus = available_cpus();
    if (!cpus.empty()) {
        pin_self_to_cpu(cpus.front());
    }

    std::mt19937_64 rng(0xC0FFEEULL); // fixed seed: reproducible chase order

    std::uint64_t carry = 0; // continue the chase across steps/trials
    int step_num = 0;

    for (const auto& step : kSteps) {
        ++step_num;
        std::uint64_t n = step.bytes / sizeof(Node);
        if (n < 2) n = 2;

        std::vector<Node> nodes = build_chase(n, rng);

        std::uint64_t accesses = std::max(accesses_floor, n);

        // Warm-up lap (untimed): touch every node once so the timed runs
        // below all start from the same "recently touched" state. Without
        // this, the first timed run would also be paying first-touch page
        // faults, which would unfairly penalize whichever step happens to
        // run first rather than reflecting that step's cache behavior.
        ChaseResult warm = chase(nodes, n, carry);
        carry = warm.sink;

        double best_ns_per_access = -1.0;
        std::uint64_t last_sink = carry;
        for (int t = 0; t < trials; ++t) {
            ChaseResult r = chase(nodes, accesses, carry);
            carry = r.sink;
            last_sink = r.sink;
            if (best_ns_per_access < 0.0 || r.ns_per_access < best_ns_per_access) {
                best_ns_per_access = r.ns_per_access;
            }
        }

        fmt::print(
            "step={} label={} size_kib={} nodes={} trials={} accesses={} "
            "ns_per_access={:.3f} chase_sink={}\n",
            step_num, step.label, step.bytes / 1024, n, trials, accesses,
            best_ns_per_access, last_sink);
    }

    return 0;
}
