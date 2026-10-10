// concurrency/27-debugging-races-deadlocks — a real, reproducible data
// race, plus its atomic fix.
//
// Two std::jthreads each run a tight loop calling increment() on a SHARED
// counter N times with no synchronization between them. In "racy" mode the
// counter is a plain `int&` and increment() does a bare `++counter` -- a
// non-atomic read-modify-write with no happens-before edge connecting the
// two threads' accesses to it, which the C++ object model defines as a
// data race (undefined behavior) regardless of whether a given run happens
// to print the mathematically correct total. In "fixed" mode the counter
// is a `std::atomic<int>&` and increment() does a `fetch_add` instead --
// now every access is a synchronized atomic operation, so there is no race
// to find, in this build or under ThreadSanitizer.
//
// This single source is compiled TWICE by this demo's Containerfile: once
// plain, once with -fsanitize=thread. The binary itself doesn't know or
// care which; the harness decides what to assert against each build.
//
// Usage:
//   racy_counter --mode racy|fixed [-n ITERATIONS]
//
// Prints one key=value line to stdout:
//   mode=racy n=100000 counter=142857 expected=200000
//
// (For --mode racy, `counter` is frequently LESS than `expected` -- lost
// updates from the unsynchronized read-modify-write -- but the point of
// this example is not the wrong number; a run that happens to print the
// right number anyway is still built on undefined behavior. ThreadSanitizer
// is what actually proves the defect, independent of the printed count.)

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <thread>

#include <fmt/core.h>

namespace {

constexpr int kDefaultIterations = 100'000;
constexpr int kThreads = 2;

// The racing line: a bare, non-atomic read-modify-write on a plain int
// shared by both threads with no lock, no atomic, and no other
// synchronization. noinline so this always shows up as its own frame --
// in a ThreadSanitizer report, in a Helgrind report, and under gdb -- so
// "name the source line" always resolves to THIS function's body, never
// an inlined fragment of main() or worker().
__attribute__((noinline))
void increment(int& counter) {
    ++counter; // <-- the race: load, add, store, no happens-before edge
}

// The fix: the exact same call shape, but the counter itself carries its
// own synchronization. memory_order_relaxed is enough here -- the only
// property this program needs is that concurrent fetch_adds don't lose
// updates, not any particular ordering relative to other memory, and
// ThreadSanitizer models every atomic operation (regardless of memory
// order) as properly synchronized for race-detection purposes.
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
        // jthreads join automatically when they go out of scope.
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
