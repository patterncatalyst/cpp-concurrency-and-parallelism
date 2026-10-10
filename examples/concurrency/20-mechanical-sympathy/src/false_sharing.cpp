// concurrency/20-mechanical-sympathy — false sharing vs. cache-line padding.
//
// Two threads each fetch_add their own std::atomic<uint64_t> counter N
// times, pinned to separate CPUs. In "unpadded" mode the two counters sit
// on the struct's default layout -- adjacent, almost certainly sharing one
// 64-byte cache line -- so every increment on one core invalidates the
// other core's cached copy of that line even though the two threads touch
// completely disjoint bytes. In "padded" mode each counter gets its own
// std::hardware_destructive_interference_size-aligned line, so the two
// cores stop fighting over cache-coherence traffic for data they never
// actually share.
//
// Correctness (the final counts) must be identical either way -- padding
// changes performance, not the arithmetic. Usage:
//
//   false_sharing --pad on|off [-n ITER_COUNT]
//
// Prints one line in a key=value form a shell or a Lua harness can parse
// without any special grammar:
//
//   mode=padded pinned=true n=20000000 count_a=20000000 count_b=20000000 elapsed_ms=123.456

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <new>
#include <sched.h>
#include <pthread.h>
#include <string>
#include <thread>
#include <vector>

#include <fmt/core.h>

namespace {

// std::hardware_destructive_interference_size lives behind a feature-test
// macro because some toolchains (notably libstdc++ on GCC) gate it behind
// a diagnostic due to its ABI sensitivity across separately-compiled units
// -- see the chapter's discussion of why. This example is a single
// translation unit built and run together, so the ABI caveat doesn't
// apply; fall back to the near-universal 64-byte line size if the standard
// library doesn't expose the constant.
#if defined(__cpp_lib_hardware_interference_size)
constexpr std::size_t kLineSize = std::hardware_destructive_interference_size;
#else
constexpr std::size_t kLineSize = 64;
#endif

constexpr std::uint64_t kDefaultIterations = 20'000'000ULL;

// Unpadded: two atomics with no spacing hint. On essentially every real
// compiler/ABI, a pair of adjacent 8-byte atomics lands in the same
// 64-byte cache line -- that's the bug this example demonstrates.
struct UnpaddedCounters {
    std::atomic<std::uint64_t> a{0};
    std::atomic<std::uint64_t> b{0};
};

// Padded: each counter forced onto its own cache line via alignas, per
// the chapter's central technique.
struct PaddedCounters {
    alignas(kLineSize) std::atomic<std::uint64_t> a{0};
    alignas(kLineSize) std::atomic<std::uint64_t> b{0};
};

// Returns the list of CPU ids this process is currently allowed to run on
// (its cpuset -- which may be narrower than the host's full core count
// under a container CPU limit).
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

// Best-effort: pin a running thread to one CPU id. Returns false (and
// changes nothing observable besides the pinning itself) if the kernel
// refuses -- a cpuset that excludes the requested id, for example.
bool pin_to_cpu(std::thread& t, int cpu) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu, &cpuset);
    return pthread_setaffinity_np(t.native_handle(), sizeof(cpu_set_t), &cpuset) == 0;
}

template <typename Counters>
double run_once(Counters& counters, std::uint64_t n, bool pin, int cpu_a, int cpu_b) {
    auto start = std::chrono::steady_clock::now();

    std::thread ta([&] {
        for (std::uint64_t i = 0; i < n; ++i) {
            counters.a.fetch_add(1, std::memory_order_relaxed);
        }
    });
    std::thread tb([&] {
        for (std::uint64_t i = 0; i < n; ++i) {
            counters.b.fetch_add(1, std::memory_order_relaxed);
        }
    });

    if (pin) {
        pin_to_cpu(ta, cpu_a);
        pin_to_cpu(tb, cpu_b);
    }

    ta.join();
    tb.join();

    auto end = std::chrono::steady_clock::now();
    return std::chrono::duration<double, std::milli>(end - start).count();
}

} // namespace

int main(int argc, char** argv) {
    std::string pad_arg = "off";
    std::uint64_t n = kDefaultIterations;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--pad" && i + 1 < argc) {
            pad_arg = argv[++i];
        } else if (arg == "-n" && i + 1 < argc) {
            n = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: false_sharing --pad on|off [-n ITERATIONS]\n");
            return 0;
        }
    }

    bool padded = (pad_arg == "on");

    // Pin the two hot threads to two SEPARATE physical/logical CPUs within
    // this process's cpuset, so the comparison isolates cache-line
    // placement from scheduler noise (two threads the scheduler happens to
    // bounce onto the same core would mask the effect either way).
    auto cpus = available_cpus();
    bool pin = cpus.size() >= 2;
    int cpu_a = pin ? cpus[0] : 0;
    int cpu_b = pin ? cpus[1] : 0;

    std::uint64_t count_a = 0;
    std::uint64_t count_b = 0;
    double elapsed_ms = 0.0;

    if (padded) {
        PaddedCounters counters;
        elapsed_ms = run_once(counters, n, pin, cpu_a, cpu_b);
        count_a = counters.a.load(std::memory_order_relaxed);
        count_b = counters.b.load(std::memory_order_relaxed);
    } else {
        UnpaddedCounters counters;
        elapsed_ms = run_once(counters, n, pin, cpu_a, cpu_b);
        count_a = counters.a.load(std::memory_order_relaxed);
        count_b = counters.b.load(std::memory_order_relaxed);
    }

    fmt::print(
        "mode={} pinned={} cpus={}/{} n={} count_a={} count_b={} elapsed_ms={:.3f}\n",
        padded ? "padded" : "unpadded",
        pin ? "true" : "false",
        cpu_a, cpu_b,
        n, count_a, count_b, elapsed_ms);

    return 0;
}
