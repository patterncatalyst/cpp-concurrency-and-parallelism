// concurrency/05-futex-cost — uncontended vs. contended mutex cost, and the
// futex syscall count behind both.
//
// Three modes, each doing the same fixed total of N increments:
//
//   baseline     one thread, a plain non-atomic counter, no mutex at all.
//                This is the "no lock" floor the other two modes are
//                compared against.
//   uncontended  one thread, the SAME loop, now wrapped in
//                std::lock_guard<std::mutex> every iteration -- never
//                contended, because nothing else is running concurrently.
//                Chapter 5's claim is that this costs one atomic
//                instruction per iteration and crosses into the kernel
//                (a futex(2) call) effectively never.
//   contended    the same N increments split evenly across T threads
//                sharing ONE mutex -- the case where the compare-and-swap
//                genuinely fails often enough to send threads into the
//                kernel to sleep and wake each other.
//
// Correctness (the final count) must equal N exactly in every mode --
// contention changes performance, never arithmetic, and that is the hard
// assertion verify.lua checks unconditionally. The syscall story is layered
// on top from OUTSIDE this binary: verify.lua runs each mode under
// `strace -f -e trace=futex` and counts "futex(" occurrences in the trace.
// That comparison is inherently scheduling- and environment-dependent (and
// strace itself may be unavailable or unable to attach under a locked-down
// container runtime), so it is treated as a soft, WARN-not-FAIL check --
// see verify.lua and the chapter text for why.
//
// Usage:
//   futex_cost --mode baseline|uncontended|contended [-n N] [-t THREADS]
//
// Prints one key=value line a shell or a Lua harness can parse without any
// special grammar:
//
//   mode=contended threads=8 n=200000 count=200000 elapsed_ms=12.345

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <fmt/core.h>

namespace {

constexpr std::uint64_t kDefaultN = 200'000ULL;
constexpr int kDefaultThreads = 8;

// baseline: no mutex, no other thread -- the floor every other mode is
// measured against.
double run_baseline(std::uint64_t n, std::uint64_t& out_count) {
    auto start = std::chrono::steady_clock::now();
    std::uint64_t counter = 0;
    for (std::uint64_t i = 0; i < n; ++i) {
        ++counter;
    }
    auto end = std::chrono::steady_clock::now();
    out_count = counter;
    return std::chrono::duration<double, std::milli>(end - start).count();
}

// uncontended: a real std::mutex, but only ever one thread touches it, so
// the compare-and-swap in lock()/unlock() never loses and the futex slow
// path (the actual syscall) is never reached.
double run_uncontended(std::uint64_t n, std::uint64_t& out_count) {
    auto start = std::chrono::steady_clock::now();
    std::mutex mu;
    std::uint64_t counter = 0;
    for (std::uint64_t i = 0; i < n; ++i) {
        std::lock_guard<std::mutex> lock(mu);
        ++counter;
    }
    auto end = std::chrono::steady_clock::now();
    out_count = counter;
    return std::chrono::duration<double, std::milli>(end - start).count();
}

// contended: the same N increments, split evenly (remainder absorbed by
// the first threads) across `threads` workers sharing one mutex, so the
// compare-and-swap genuinely fails often enough to park threads in the
// kernel.
double run_contended(std::uint64_t n, int threads, std::uint64_t& out_count) {
    auto start = std::chrono::steady_clock::now();
    std::mutex mu;
    std::uint64_t counter = 0;

    const auto thread_count = static_cast<std::uint64_t>(threads);
    const std::uint64_t base_share = n / thread_count;
    const std::uint64_t remainder = n % thread_count;

    std::vector<std::thread> workers;
    workers.reserve(static_cast<std::size_t>(threads));
    for (int t = 0; t < threads; ++t) {
        std::uint64_t share = base_share + (static_cast<std::uint64_t>(t) < remainder ? 1 : 0);
        workers.emplace_back([&mu, &counter, share] {
            for (std::uint64_t i = 0; i < share; ++i) {
                std::lock_guard<std::mutex> lock(mu);
                ++counter;
            }
        });
    }
    for (auto& w : workers) {
        w.join();
    }

    auto end = std::chrono::steady_clock::now();
    out_count = counter;
    return std::chrono::duration<double, std::milli>(end - start).count();
}

} // namespace

int main(int argc, char** argv) {
    std::string mode = "baseline";
    std::uint64_t n = kDefaultN;
    int threads = kDefaultThreads;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--mode" && i + 1 < argc) {
            mode = argv[++i];
        } else if (arg == "-n" && i + 1 < argc) {
            n = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-t" && i + 1 < argc) {
            threads = std::atoi(argv[++i]);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: futex_cost --mode baseline|uncontended|contended [-n N] [-t THREADS]\n");
            return 0;
        }
    }

    if (threads < 1) {
        threads = 1;
    }

    std::uint64_t count = 0;
    double elapsed_ms = 0.0;
    int reported_threads = 1;

    if (mode == "uncontended") {
        elapsed_ms = run_uncontended(n, count);
    } else if (mode == "contended") {
        elapsed_ms = run_contended(n, threads, count);
        reported_threads = threads;
    } else {
        mode = "baseline";
        elapsed_ms = run_baseline(n, count);
    }

    fmt::print(
        "mode={} threads={} n={} count={} elapsed_ms={:.3f}\n",
        mode, reported_threads, n, count, elapsed_ms);

    return 0;
}
