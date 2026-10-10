// concurrency/09-lock-free-data-structures — SPSC ring buffer, padded vs.
// unpadded cursors.
//
// One producer thread pushes values 0..N-1 into a bounded ring buffer; one
// consumer thread pops them, in order, on the other end. `tail` (items
// pushed) and `head` (items popped) are each written by exactly one thread
// and only ever read by the other -- the one-writer-per-counter property
// the chapter identifies as what makes SPSC safe without a lock or a CAS.
// Since the producer pushes value `i` at logical position `t == i`, a
// correct ring must have the consumer read back exactly `v == h` at every
// logical position `h` -- any loss, duplication, or reordering shows up
// immediately as a value/position mismatch, not just a wrong running sum.
//
// A `--pad on|off` flag controls whether `head` and `tail` share a cache
// line (the default, unpadded layout) or each get their own
// std::hardware_destructive_interference_size-aligned line -- the same
// false-sharing experiment Doc 20 runs on a pair of independent counters,
// here applied to the ring's own cursors, which is exactly the scenario
// this chapter's "Running in a container" section describes: the
// consumer's store to `head` invalidates the producer's cached copy of the
// whole line, `tail` included, even though the producer never touches
// `head`.
//
// A `--capacity` flag (default 1024, down to 1 for maximum contention)
// controls the backing buffer's size.
//
// Usage:
//   spsc_ring --pad on|off [--capacity N] [-n ITEMS]
//
// Prints one line in a key=value form a shell or a Lua harness can parse
// without any special grammar:
//
//   mode=padded capacity=1024 pinned=true cpus=0/1 n=5000000 consumed=5000000 \
//     mismatches=0 sum=12499997500000 expected_sum=12499997500000 \
//     elapsed_ms=210.773 ops_per_sec=23721987

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <sched.h>
#include <pthread.h>
#include <string>
#include <thread>
#include <vector>

#include <fmt/core.h>

namespace {

#if defined(__cpp_lib_hardware_interference_size)
constexpr std::size_t kLineSize = std::hardware_destructive_interference_size;
#else
constexpr std::size_t kLineSize = 64;
#endif

constexpr std::uint64_t kDefaultIterations = 5'000'000ULL;
constexpr std::uint64_t kDefaultCapacity = 1024;

// Unpadded: head and tail with no spacing hint -- on essentially every real
// compiler/ABI, two adjacent 8-byte atomics land in the same 64-byte cache
// line. That's the false-sharing case this example measures.
struct UnpaddedCursors {
    std::atomic<std::uint64_t> head{0};
    std::atomic<std::uint64_t> tail{0};
};

// Padded: each cursor forced onto its own cache line.
struct PaddedCursors {
    alignas(kLineSize) std::atomic<std::uint64_t> head{0};
    alignas(kLineSize) std::atomic<std::uint64_t> tail{0};
};

struct RunResult {
    std::uint64_t consumed = 0;
    std::uint64_t mismatches = 0;
    std::uint64_t sum = 0;
    double elapsed_ms = 0.0;
};

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

bool pin_to_cpu(std::thread& t, int cpu) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu, &cpuset);
    return pthread_setaffinity_np(t.native_handle(), sizeof(cpu_set_t), &cpuset) == 0;
}

// Shared by both the padded and unpadded layouts -- only the cursor
// struct's layout differs (see UnpaddedCursors / PaddedCursors above).
template <typename Cursors>
RunResult run_ring(std::uint64_t n, std::uint64_t capacity, bool pin, int cpu_a, int cpu_b) {
    Cursors cursors;
    std::vector<std::uint64_t> buf(capacity, 0);

    auto start = std::chrono::steady_clock::now();

    std::thread producer([&] {
        std::uint64_t t = 0;
        for (std::uint64_t i = 0; i < n; ++i) {
            while (t - cursors.head.load(std::memory_order_acquire) == capacity) {
                // spin: ring full
            }
            buf[t % capacity] = i;
            ++t;
            cursors.tail.store(t, std::memory_order_release);
        }
    });

    std::uint64_t consumed = 0;
    std::uint64_t mismatches = 0;
    std::uint64_t sum = 0;

    std::thread consumer([&] {
        std::uint64_t h = 0;
        for (std::uint64_t i = 0; i < n; ++i) {
            while (h == cursors.tail.load(std::memory_order_acquire)) {
                // spin: ring empty
            }
            std::uint64_t v = buf[h % capacity];
            // The producer pushed value `i` at logical position `t == i`,
            // so a correct FIFO ring must hand the consumer back exactly
            // `v == h` at logical position `h`. Any loss, duplication, or
            // reordering shows up here as a direct value mismatch.
            if (v != h) {
                ++mismatches;
            }
            sum += v;
            ++h;
            ++consumed;
            cursors.head.store(h, std::memory_order_release);
        }
    });

    if (pin) {
        pin_to_cpu(producer, cpu_a);
        pin_to_cpu(consumer, cpu_b);
    }

    producer.join();
    consumer.join();

    auto end = std::chrono::steady_clock::now();

    RunResult r;
    r.consumed = consumed;
    r.mismatches = mismatches;
    r.sum = sum;
    r.elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
    return r;
}

} // namespace

int main(int argc, char** argv) {
    std::string pad_arg = "off";
    std::uint64_t n = kDefaultIterations;
    std::uint64_t capacity = kDefaultCapacity;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--pad" && i + 1 < argc) {
            pad_arg = argv[++i];
        } else if (arg == "--capacity" && i + 1 < argc) {
            capacity = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-n" && i + 1 < argc) {
            n = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: spsc_ring --pad on|off [--capacity N] [-n ITEMS]\n");
            return 0;
        }
    }

    if (n == 0) {
        fmt::print(stderr, "error: -n must be >= 1\n");
        return 2;
    }
    if (capacity == 0) {
        fmt::print(stderr, "error: --capacity must be >= 1\n");
        return 2;
    }

    bool padded = (pad_arg == "on");

    auto cpus = available_cpus();
    bool pin = cpus.size() >= 2;
    int cpu_a = pin ? cpus[0] : 0;
    int cpu_b = pin ? cpus[1] : 0;

    RunResult r = padded
        ? run_ring<PaddedCursors>(n, capacity, pin, cpu_a, cpu_b)
        : run_ring<UnpaddedCursors>(n, capacity, pin, cpu_a, cpu_b);

    std::uint64_t expected_sum = n * (n - 1) / 2;
    double ops_per_sec = r.elapsed_ms > 0.0
        ? (static_cast<double>(r.consumed) / (r.elapsed_ms / 1000.0))
        : 0.0;

    fmt::print(
        "mode={} capacity={} pinned={} cpus={}/{} n={} consumed={} mismatches={} sum={} "
        "expected_sum={} elapsed_ms={:.3f} ops_per_sec={:.0f}\n",
        padded ? "padded" : "unpadded",
        capacity,
        pin ? "true" : "false",
        cpu_a, cpu_b,
        n, r.consumed, r.mismatches, r.sum, expected_sum, r.elapsed_ms, ops_per_sec);

    return 0;
}
