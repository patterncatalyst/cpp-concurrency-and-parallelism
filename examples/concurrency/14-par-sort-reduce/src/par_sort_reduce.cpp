// concurrency/14-par-sort-reduce — seq vs par vs par_unseq, same sort + reduce.
//
// Doc 14 covers the C++17 execution policies (seq/par/par_unseq) and the
// policy-parameterized parallel STL built on them. This example runs the
// SAME sort and the SAME reduction over the SAME input, once per policy, and
// prints what each run actually did:
//
//   sort_hash       -- an order-sensitive FNV-1a hash of the sorted output.
//                      Sorting is a correctness operation, not a performance
//                      choice -- every policy must sort the identical input
//                      into the identical output, so this hash must match
//                      across seq/par/par_unseq.
//   reduce_sum      -- the result of transform_reduce: map each element
//                      through a deterministic mixing function, then sum
//                      with std::plus<std::uint64_t>. Unsigned integer
//                      addition is exactly associative AND commutative under
//                      well-defined modular (wraparound) arithmetic, so the
//                      sum is bit-identical regardless of what order the
//                      partial sums from different threads combine in --
//                      unlike floating-point addition, which the chapter
//                      flags as NOT safe to assume reproducible across
//                      evaluation orders. Using an exact integer sum here is
//                      deliberate: it lets this harness assert correctness
//                      with a plain equality check instead of a tolerance.
//   distinct_cpus   -- popcount of the union of every sched_getcpu() reading
//                      taken inside transform_reduce's callable (ch01's
//                      "distinct_cpus" technique). Reported, not required,
//                      for seq (the library runs it on the calling thread by
//                      construction); checked as a soft signal for par: the
//                      library is PERMITTED to run the callable from more
//                      than one thread, but isn't required to split any
//                      specific workload across more than one -- see
//                      verify.lua.
//
// This is the project's second example to depend on oneTBB (after
// 01-execution-models): GCC's libstdc++ implements std::execution::par on
// top of a PSTL-over-TBB backend, so std::sort(std::execution::par, ...)
// and std::transform_reduce(std::execution::par, ...) fail to LINK without
// it, independent of whether the policy is honored at runtime.
//
// Usage: par_sort_reduce [-n ELEMENT_COUNT] [-w PER_ELEMENT_WORK]
//
// Prints one num_available_cpus= header line, then one policy= line per
// execution policy, all trivial to parse:
//
//   num_available_cpus=4 n=2000000 w=30
//   policy=seq       sort_ms=123.456 sort_hash=89abcdef01234567 reduce_ms=45.678 reduce_sum=18446744071562067968 distinct_cpus=1
//   policy=par       sort_ms=45.678  sort_hash=89abcdef01234567 reduce_ms=12.345 reduce_sum=18446744071562067968 distinct_cpus=4
//   policy=par_unseq sort_ms=44.123  sort_hash=89abcdef01234567 reduce_ms=12.001 reduce_sum=18446744071562067968 distinct_cpus=3

#include <algorithm>
#include <atomic>
#include <bit>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <execution>
#include <numeric>
#include <random>
#include <sched.h>
#include <string>
#include <vector>

#include <fmt/core.h>

namespace {

constexpr std::size_t kDefaultN = 2'000'000;
constexpr int kDefaultW = 30;
constexpr std::uint64_t kSeed = 42;

// FNV-1a over the sorted sequence, order-sensitive: any difference in the
// final element order or values between two policies' sorted output changes
// this hash. Stand-in for diffing the whole (multi-million-element) array.
std::uint64_t hash_sorted(const std::vector<std::uint64_t>& v) {
    std::uint64_t h = 1469598103934665603ULL; // FNV-1a 64-bit offset basis
    for (std::uint64_t x : v) {
        for (int b = 0; b < 8; ++b) {
            auto byte = static_cast<std::uint8_t>(x >> (b * 8));
            h ^= byte;
            h *= 1099511628211ULL; // FNV-1a 64-bit prime
        }
    }
    return h;
}

// Deterministic, pure per-element "work": w rounds of splitmix64-style
// mixing. A pure function of (x, w) only -- identical regardless of which
// thread runs it or in what order -- so transform_reduce's result cannot
// depend on the execution policy used to compute it, only the arithmetic
// (and the fixed seed/n/w) does. This is also the synthetic cost that gives
// par/par_unseq genuine per-element compute to amortize their dispatch
// overhead against, per the chapter's N*w-vs-c crossover discussion.
std::uint64_t mix(std::uint64_t x, int w) {
    for (int i = 0; i < w; ++i) {
        x += 0x9e3779b97f4a7c15ULL;
        x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
        x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
        x ^= (x >> 31);
    }
    return x;
}

// The CPU ids this process is currently allowed to run on -- its cpuset,
// which may be narrower than the host's full core count under a container
// CPU limit (`docker run --cpus`).
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

std::vector<std::uint64_t> make_data(std::size_t n, std::uint64_t seed) {
    std::vector<std::uint64_t> data(n);
    std::mt19937_64 rng(seed);
    std::uniform_int_distribution<std::uint64_t> dist;
    for (auto& x : data) {
        x = dist(rng);
    }
    return data;
}

struct Trial {
    const char* policy = "";
    double sort_ms = 0.0;
    std::uint64_t sort_hash = 0;
    double reduce_ms = 0.0;
    std::uint64_t reduce_sum = 0;
    int distinct_cpus = 0;
};

// Runs the sort phase and the transform_reduce phase under one execution
// policy, against a fresh copy of `original` for the sort (sort is
// in-place) and against `original` itself (read-only) for the reduce.
template <typename Policy>
Trial run_trial(const char* name, Policy policy,
                 const std::vector<std::uint64_t>& original, int w) {
    Trial t;
    t.policy = name;

    std::vector<std::uint64_t> sorted_copy = original;
    auto t0 = std::chrono::steady_clock::now();
    std::sort(policy, sorted_copy.begin(), sorted_copy.end());
    auto t1 = std::chrono::steady_clock::now();
    t.sort_ms = std::chrono::duration<double, std::milli>(t1 - t0).count();
    t.sort_hash = hash_sorted(sorted_copy);

    std::atomic<std::uint64_t> cpu_mask{0};
    auto t2 = std::chrono::steady_clock::now();
    t.reduce_sum = std::transform_reduce(
        policy, original.begin(), original.end(), std::uint64_t{0}, std::plus<>(),
        [&cpu_mask, w](std::uint64_t x) {
            int cpu = sched_getcpu();
            if (cpu >= 0 && cpu < 64) {
                cpu_mask.fetch_or(std::uint64_t{1} << cpu, std::memory_order_relaxed);
            }
            return mix(x, w);
        });
    auto t3 = std::chrono::steady_clock::now();
    t.reduce_ms = std::chrono::duration<double, std::milli>(t3 - t2).count();
    t.distinct_cpus = std::popcount(cpu_mask.load(std::memory_order_relaxed));

    return t;
}

void print_trial(const Trial& t) {
    fmt::print(
        "policy={:<9} sort_ms={:.3f} sort_hash={:016x} reduce_ms={:.3f} "
        "reduce_sum={} distinct_cpus={}\n",
        t.policy, t.sort_ms, t.sort_hash, t.reduce_ms, t.reduce_sum, t.distinct_cpus);
}

} // namespace

int main(int argc, char** argv) {
    std::size_t n = kDefaultN;
    int w = kDefaultW;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-n" && i + 1 < argc) {
            n = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-w" && i + 1 < argc) {
            w = std::atoi(argv[++i]);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: par_sort_reduce [-n ELEMENT_COUNT] [-w PER_ELEMENT_WORK]\n");
            return 0;
        }
    }

    auto cpus = available_cpus();
    fmt::print("num_available_cpus={} n={} w={}\n", cpus.size(), n, w);

    auto data = make_data(n, kSeed);

    print_trial(run_trial("seq", std::execution::seq, data, w));
    print_trial(run_trial("par", std::execution::par, data, w));
    print_trial(run_trial("par_unseq", std::execution::par_unseq, data, w));

    return 0;
}
