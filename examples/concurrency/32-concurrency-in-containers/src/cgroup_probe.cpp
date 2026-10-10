// concurrency/32-concurrency-in-containers — cgroup-probe + pool-bench.
//
// A container's cgroup v2 "cpu.max" file is a TIME BUDGET (quota
// microseconds / period microseconds, or the literal string "max" for
// unlimited). std::thread::hardware_concurrency() answers a completely
// different question -- "how many cores could a thread here be scheduled
// on" -- which tracks a cpuset restriction but NOT a quota. A container
// given `--cpus=2` with no cpuset restriction on a 16-core host still
// reports hardware_concurrency() == 16: nothing narrowed what the thread
// can see, only how much aggregate CPU time it may spend.
//
// This program:
//   1. Reads /sys/fs/cgroup/cpu.max, guarding every failure mode (file
//      missing entirely -- cgroup v1 or no cgroups at all; unreadable;
//      malformed; or the literal "max") by folding all of them into the
//      same "no quota" state, exactly as the chapter's std::optional-based
//      cgroup_cpu_quota() does.
//   2. Reads hardware_concurrency() and, separately, the sched_getaffinity
//      cpuset-visible core count.
//   3. Derives a pool size: the tighter of the quota and the affinity
//      count when a quota exists, else the affinity count (or
//      hardware_concurrency() if even sched_getaffinity fails) -- an
//      orchestrator-supplied CPU_LIMIT env var wins outright, mirroring
//      the chapter's recommended_cpu_pool_size().
//   4. Runs a small, fixed, CPU-bound "pool-bench" workload at that pool
//      size so the program demonstrates sizing a pool to the quota, not
//      merely printing numbers.
//
// Prints one line in a key=value form a shell or Lua harness can parse
// without any special grammar:
//
//   hardware_concurrency=16 affinity_count=16 quota=unlimited pool_size=16 bench_iters=2000000 pool_bench_ms=41.117
//
// Usage: cgroup_probe [--bench-iters N]
//
// Under a plain `docker run` (no --cpus/--cpuset-cpus), cpu.max reads
// "max" -- the fallback/unlimited path this example's verify.lua asserts
// as a hard requirement. Run the image with `--cpus=N` (see README) to
// put a real quota in the cgroup and watch `quota=` become a finite
// number smaller than hardware_concurrency() on a multi-core host -- the
// gap this chapter is about.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <sched.h>
#include <string>
#include <thread>
#include <vector>

#include <fmt/core.h>
#include <fmt/format.h> // fmt::format (used for the quota field) lives here, not core.h

namespace {

constexpr std::uint64_t kDefaultBenchIters = 2'000'000ULL;

// Folds every "no usable quota" case (file missing -- e.g. cgroup v1 or a
// host with no cgroups at all; unreadable; malformed; or the literal
// "max") into the same empty state, exactly as the chapter's
// std::optional<double>-returning cgroup_cpu_quota() does. Never throws,
// never crashes on a missing or unexpected /sys layout.
struct CgroupQuota {
    bool available = false;
    double quota_cores = 0.0;
};

CgroupQuota read_cgroup_cpu_quota() {
    CgroupQuota result;

    std::ifstream f("/sys/fs/cgroup/cpu.max");
    if (!f.is_open()) {
        return result; // cgroup v1, no cgroups, or the path isn't mounted
    }

    std::string quota_str;
    long period = 0;
    if (!(f >> quota_str >> period)) {
        return result; // malformed/short read -- guard, don't crash
    }
    if (quota_str == "max" || period <= 0) {
        return result; // unlimited
    }

    char* end = nullptr;
    const double quota_us = std::strtod(quota_str.c_str(), &end);
    if (end == quota_str.c_str()) {
        return result; // first field wasn't numeric -- guard, don't crash
    }

    result.available = true;
    result.quota_cores = quota_us / static_cast<double>(period);
    return result;
}

// The sched_getaffinity-derived cpuset-visible core count. Falls back to
// hardware_concurrency() if the syscall itself fails (never observed in
// practice, but guarded per the chapter's own affinity_cpu_count()).
unsigned affinity_cpu_count(unsigned fallback) {
    cpu_set_t set;
    CPU_ZERO(&set);
    if (::sched_getaffinity(0, sizeof(set), &set) != 0) {
        return fallback;
    }
    const int n = CPU_COUNT(&set);
    return n > 0 ? static_cast<unsigned>(n) : fallback;
}

// The pool size a CPU-bound stage should actually use: an orchestrator-
// supplied CPU_LIMIT wins outright; otherwise the tighter of the cgroup
// quota and the cpuset-visible core count; falling back to the affinity
// count (or hardware_concurrency() as a last resort) when no quota is
// set. Mirrors the chapter's recommended_cpu_pool_size().
unsigned recommended_pool_size(unsigned hw, unsigned affinity, const CgroupQuota& quota) {
    if (const char* env = std::getenv("CPU_LIMIT")) {
        const double v = std::strtod(env, nullptr);
        if (v > 0.0) {
            return std::max(1u, static_cast<unsigned>(v));
        }
    }

    const unsigned ceiling = affinity > 0 ? affinity : std::max(1u, hw);

    if (quota.available) {
        const double tighter = std::min(quota.quota_cores, static_cast<double>(ceiling));
        return std::max(1u, static_cast<unsigned>(tighter)); // floor
    }
    return ceiling;
}

// A small, fixed, CPU-bound workload: each worker does the same bounded
// amount of arithmetic, so the only thing that varies between runs is how
// many workers are allowed to run concurrently. Not a benchmark in its
// own right -- the point is demonstrating "a pool sized to the quota
// runs a fixed workload" rather than measuring anything precise.
double pool_bench(unsigned pool_size, std::uint64_t iters_per_thread) {
    std::atomic<std::uint64_t> sink{0};
    const auto start = std::chrono::steady_clock::now();

    std::vector<std::thread> workers;
    workers.reserve(pool_size);
    for (unsigned i = 0; i < pool_size; ++i) {
        workers.emplace_back([&sink, iters_per_thread] {
            std::uint64_t local = 0;
            for (std::uint64_t j = 0; j < iters_per_thread; ++j) {
                local += j * 2654435761ULL; // bounded, non-optimizable-away busywork
            }
            sink.fetch_add(local, std::memory_order_relaxed);
        });
    }
    for (auto& t : workers) {
        t.join();
    }

    const auto end = std::chrono::steady_clock::now();
    // Touch the sink so the compiler can't prove the loops are dead code.
    if (sink.load(std::memory_order_relaxed) == 0xFFFFFFFFFFFFFFFFULL) {
        std::fprintf(stderr, "unreachable\n");
    }
    return std::chrono::duration<double, std::milli>(end - start).count();
}

} // namespace

int main(int argc, char** argv) {
    std::uint64_t bench_iters = kDefaultBenchIters;

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--bench-iters" && i + 1 < argc) {
            bench_iters = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: cgroup_probe [--bench-iters N]\n");
            return 0;
        }
    }

    const unsigned hw = std::thread::hardware_concurrency();
    const unsigned affinity = affinity_cpu_count(hw);
    const CgroupQuota quota = read_cgroup_cpu_quota();
    const unsigned pool_size = recommended_pool_size(hw, affinity, quota);

    const double bench_ms = pool_bench(pool_size, bench_iters);

    const std::string quota_field =
        quota.available ? fmt::format("{:.2f}", quota.quota_cores) : std::string("unlimited");

    fmt::print(
        "hardware_concurrency={} affinity_count={} quota={} pool_size={} "
        "bench_iters={} pool_bench_ms={:.3f}\n",
        hw, affinity, quota_field, pool_size, bench_iters, bench_ms);

    return 0;
}
