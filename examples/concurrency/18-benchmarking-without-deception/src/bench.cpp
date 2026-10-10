// concurrency/18-benchmarking-without-deception — the chapter's own harness,
// applied to a deliberately trivial, fixed workload: one atomic fetch_add
// per iteration.
//
// Default (harness) mode:
//   1. Run --warmup throwaway iterations, untimed, discarded.
//   2. Time --iters remaining iterations individually, between two
//      steady_clock reads each, folding every iteration's fetch_add
//      return value into a checksum the program reads at the end (so the
//      optimizer can't treat any iteration as dead code).
//   3. Sort the raw samples; report min/median/p99/max.
//   4. Apply the coordinated-omission backfill over the SAME raw samples,
//      using the run's own median as the expected per-operation interval
//      E: for every sample v > E, synthesize v-E, v-2E, ... down to E,
//      standing in for the requests that would have queued behind a stall
//      of that length. Report co_p99/co_n alongside the raw figures.
//
// --naive mode skips warmup entirely and times the whole --iters loop as
// ONE wall-clock sample -- no per-iteration samples exist, so no
// percentile of any kind is computed or printed. This makes the
// methodology gap the rest of the chapter argues against visible in the
// program's own output, not only in prose.
//
// Usage:
//   bench [--iters N] [--warmup W]
//   bench --naive [--iters N]
//
// Prints one line:
//   mode=harness n=50000 warmup=5000 min_ns=21 median_ns=34 p99_ns=118 max_ns=40221 co_p99_ns=142 co_n=50644 checksum=1276287500 expected_checksum=1276287500 checksum_ok=true
//   mode=naive n=50000 elapsed_ns=1842933 checksum=1249975000 expected_checksum=1249975000 checksum_ok=true

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

#include <fmt/core.h>

namespace {

using Clock = std::chrono::steady_clock;

// The fixed workload every iteration performs. fetch_add's own
// pre-increment return value is folded into the caller's checksum
// accumulator, which the program prints at the end -- an observably used
// result the optimizer cannot prove is dead, and a free correctness check:
// a fixed, known iteration count must always produce the identical,
// closed-form checksum.
std::uint64_t one_unit_of_work(std::atomic<std::uint64_t>& counter) {
    return counter.fetch_add(1, std::memory_order_relaxed);
}

struct Stats {
    std::int64_t min_ns = 0;
    std::int64_t median_ns = 0;
    std::int64_t p99_ns = 0;
    std::int64_t max_ns = 0;
    std::int64_t co_p99_ns = 0;
    std::uint64_t co_n = 0;
};

std::int64_t percentile_ns(const std::vector<std::int64_t>& sorted, double p) {
    if (sorted.empty()) {
        return 0;
    }
    std::size_t idx = static_cast<std::size_t>(p * static_cast<double>(sorted.size() - 1));
    return sorted[idx];
}

// Coordinated-omission backfill: for every raw sample v exceeding the
// expected interval e_ns, synthesize v-e_ns, v-2*e_ns, ... down to e_ns,
// standing in for the requests a fixed-rate caller would have had queued
// behind a stall of that length. Capped per-sample so one pathological
// stall can't grow the array without bound.
std::vector<std::int64_t> co_correct(const std::vector<std::int64_t>& raw, std::int64_t e_ns,
                                      std::uint64_t cap_per_sample) {
    std::vector<std::int64_t> out;
    out.reserve(raw.size());
    for (auto v : raw) {
        out.push_back(v);
        if (e_ns <= 0) {
            continue;
        }
        std::uint64_t backfilled = 0;
        std::int64_t remaining = v - e_ns;
        while (remaining >= e_ns && backfilled < cap_per_sample) {
            out.push_back(remaining);
            remaining -= e_ns;
            ++backfilled;
        }
    }
    return out;
}

Stats analyze(const std::vector<std::int64_t>& raw) {
    Stats s;
    std::vector<std::int64_t> sorted = raw;
    std::sort(sorted.begin(), sorted.end());
    s.min_ns = sorted.front();
    s.median_ns = percentile_ns(sorted, 0.50);
    s.p99_ns = percentile_ns(sorted, 0.99);
    s.max_ns = sorted.back();

    auto corrected = co_correct(raw, s.median_ns, /*cap_per_sample=*/100000);
    std::sort(corrected.begin(), corrected.end());
    s.co_p99_ns = percentile_ns(corrected, 0.99);
    s.co_n = corrected.size();
    return s;
}

} // namespace

int main(int argc, char** argv) {
    std::uint64_t iters = 50000;
    std::uint64_t warmup = 5000;
    bool naive = false;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--iters" && i + 1 < argc) {
            iters = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "--warmup" && i + 1 < argc) {
            warmup = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "--naive") {
            naive = true;
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: bench [--iters N] [--warmup W] | bench --naive [--iters N]\n");
            return 0;
        }
    }

    std::atomic<std::uint64_t> counter{0};

    if (naive) {
        // No warmup, one single unwarmed wall-clock sample over the whole
        // loop -- the methodology this chapter argues against, made
        // observable: no percentile field of any kind appears below.
        std::uint64_t checksum = 0;
        auto start = Clock::now();
        for (std::uint64_t i = 0; i < iters; ++i) {
            checksum += one_unit_of_work(counter);
        }
        auto end = Clock::now();
        auto elapsed_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count();
        std::uint64_t expected = iters > 0 ? iters * (iters - 1) / 2 : 0;
        fmt::print(
            "mode=naive n={} elapsed_ns={} checksum={} expected_checksum={} checksum_ok={}\n",
            iters, elapsed_ns, checksum, expected, checksum == expected ? "true" : "false");
        return 0;
    }

    if (iters == 0) {
        fmt::print("mode=harness n=0 warmup={} error=iters_must_be_positive\n", warmup);
        return 1;
    }

    // Warmup: discarded, untimed. Its own contribution to the counter is
    // left in place -- the timed loop below starts from wherever the
    // counter stands after warmup, and the expected checksum accounts for
    // that base exactly, rather than resetting the counter (which would
    // let a warmup bug silently vanish from the correctness check).
    for (std::uint64_t i = 0; i < warmup; ++i) {
        one_unit_of_work(counter);
    }
    std::uint64_t base = counter.load(std::memory_order_relaxed);

    std::uint64_t checksum = 0;
    std::vector<std::int64_t> samples;
    samples.reserve(iters);
    for (std::uint64_t i = 0; i < iters; ++i) {
        auto start = Clock::now();
        checksum += one_unit_of_work(counter);
        auto end = Clock::now();
        samples.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(end - start).count());
    }

    Stats s = analyze(samples);
    // fetch_add's pre-increment returns are base, base+1, ..., base+iters-1
    // in a single-threaded run: sum = iters*base + iters*(iters-1)/2.
    std::uint64_t expected = iters > 0 ? (iters * base + iters * (iters - 1) / 2) : 0;

    fmt::print(
        "mode=harness n={} warmup={} min_ns={} median_ns={} p99_ns={} max_ns={} "
        "co_p99_ns={} co_n={} checksum={} expected_checksum={} checksum_ok={}\n",
        iters, warmup, s.min_ns, s.median_ns, s.p99_ns, s.max_ns, s.co_p99_ns, s.co_n,
        checksum, expected, checksum == expected ? "true" : "false");

    return 0;
}
