// concurrency/28-sanitizers — the same racy counter chapter 27 builds,
// reused here so this example stays standalone (every demo in this
// project builds and verifies on its own -- see the repo-wide convention
// note in 20-mechanical-sympathy/README.md) while still letting TWO
// independent detection algorithms converge on the identical bug: compile-
// time ThreadSanitizer instrumentation versus Valgrind Helgrind's binary
// re-translation and lockset analysis.
//
// Two std::jthreads each run a tight loop calling increment() on a SHARED
// counter N times with no synchronization between them. In "racy" mode the
// counter is a plain `int&` and increment() does a bare `++counter` -- a
// non-atomic read-modify-write with no happens-before edge connecting the
// two threads' accesses, which the C++ object model defines as a data
// race (undefined behavior) independent of what any single run prints. In
// "fixed" mode the counter is a `std::atomic<int>&` and increment() does a
// `fetch_add` instead -- every access is synchronized, so there's no race
// for either tool to find.
//
// This source is compiled THREE ways by this demo's Containerfile: once
// plain (for the Helgrind leg -- Valgrind needs no rebuild/instrumentation
// at all, just debug symbols to name a source line), once with
// -fsanitize=thread (for the TSan leg), and the plain build is reused
// unmodified for Helgrind rather than built a third time.
//
// Usage:
//   racy_counter --mode racy|fixed [-n ITERATIONS]
//
// Prints one key=value line to stdout:
//   mode=racy n=20000 counter=14285 expected=40000

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <thread>

#include <fmt/core.h>

namespace {

constexpr int kDefaultIterations = 20'000;
constexpr int kThreads = 2;

// The racing line: a bare, non-atomic read-modify-write on a plain int
// shared by both threads with no lock, no atomic, and no other
// synchronization. noinline so this always shows up as its own frame --
// in a ThreadSanitizer report AND in a Helgrind report -- so "the same
// source line" is something both tools can actually be checked against.
__attribute__((noinline))
void increment(int& counter) {
    ++counter; // <-- the race: load, add, store, no happens-before edge
}

// The fix: the exact same call shape, but the counter carries its own
// synchronization. Both ThreadSanitizer (compile-time) and Helgrind
// (binary re-translation) model an atomic read-modify-write as properly
// synchronized, regardless of memory order -- this path is race-free
// under both detection algorithms.
__attribute__((noinline))
void increment(std::atomic<int>& counter) {
    counter.fetch_add(1, std::memory_order_relaxed);
}

void run_racy(int iterations) {
    int counter = 0;

    {
        std::jthread t1([&] {
            for (int i = 0; i < iterations; ++i) increment(counter);
        });
        std::jthread t2([&] {
            for (int i = 0; i < iterations; ++i) increment(counter);
        });
    }

    int expected = iterations * kThreads;
    fmt::print("mode=racy n={} counter={} expected={}\n", iterations, counter, expected);
}

void run_fixed(int iterations) {
    std::atomic<int> counter{0};

    {
        std::jthread t1([&] {
            for (int i = 0; i < iterations; ++i) increment(counter);
        });
        std::jthread t2([&] {
            for (int i = 0; i < iterations; ++i) increment(counter);
        });
    }

    int expected = iterations * kThreads;
    fmt::print("mode=fixed n={} counter={} expected={}\n", iterations, counter.load(), expected);
}

} // namespace

int main(int argc, char** argv) {
    std::string mode = "fixed";
    int iterations = kDefaultIterations;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--mode" && i + 1 < argc) {
            mode = argv[++i];
        } else if (arg == "-n" && i + 1 < argc) {
            iterations = std::atoi(argv[++i]);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: racy_counter --mode racy|fixed [-n ITERATIONS]\n");
            return 0;
        }
    }

    if (iterations < 1) iterations = 1;

    if (mode == "racy") {
        run_racy(iterations);
    } else {
        run_fixed(iterations);
    }

    return 0;
}
