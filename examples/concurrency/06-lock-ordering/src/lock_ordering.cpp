// concurrency/06-lock-ordering — AB/BA deadlock with std::lock_guard,
// fixed with std::scoped_lock.
//
// Two mutexes, `a` and `b`, and two threads that acquire them in opposing
// order:
//
//   --mode deadlock   Thread 1 takes `a` then `b`; thread 2 takes `b` then
//                      `a`, each using std::lock_guard. A std::latch(2)
//                      forces the race deterministically: each thread
//                      arrives at the latch only after it holds its FIRST
//                      lock, and the latch does not release either thread
//                      until BOTH have arrived -- so by the time either
//                      thread reaches for its second lock, the other
//                      thread is guaranteed to already be holding it. This
//                      is the textbook circular wait, made to happen every
//                      single run instead of only occasionally under raw
//                      scheduling luck. The process never terminates on
//                      its own in this mode -- by design, that IS the
//                      demonstration. The caller (verify.lua, via `demo.sh`
//                      and the CI wrapper) is expected to run this mode
//                      under an external `timeout`.
//   --mode fixed       The same opposing acquisition order, repeated for a
//                      fixed number of iterations, but using
//                      std::scoped_lock(a, b) / std::scoped_lock(b, a).
//                      scoped_lock's deadlock-avoidance algorithm does not
//                      care what order its arguments name; it tries,
//                      backs off, and retries until it holds everything it
//                      asked for. This mode always completes and exits 0.
//
// Usage:
//   lock_ordering --mode deadlock
//   lock_ordering --mode fixed [-n ITERATIONS]
//
// Output (fixed mode only -- deadlock mode prints a startup line and then,
// correctly, nothing further):
//   mode=fixed iterations=20000 total_ops=40000 result=ok

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <latch>
#include <mutex>
#include <string>
#include <thread>

#include <fmt/core.h>

#if defined(__unix__) || defined(__APPLE__)
#include <unistd.h>
#endif

namespace {

constexpr int kDefaultIterations = 20'000;

// Deterministically reproduces the AB/BA deadlock: a std::latch(2) ensures
// neither thread reaches for its second lock until BOTH threads already
// hold their first one, guaranteeing the circular wait instead of leaving
// it to scheduling luck.
void run_deadlock() {
    std::mutex a;
    std::mutex b;
    std::latch both_holding_first_lock(2);

#if defined(__unix__) || defined(__APPLE__)
    long pid = static_cast<long>(getpid());
#else
    long pid = -1;
#endif
    fmt::print("mode=deadlock pid={} starting (expected to hang -- run under timeout)\n", pid);
    std::fflush(stdout);

    std::thread t1([&] {
        std::lock_guard<std::mutex> lock_a(a);
        both_holding_first_lock.arrive_and_wait();
        std::lock_guard<std::mutex> lock_b(b); // blocks forever: t2 holds b
        (void)lock_b;
    });
    std::thread t2([&] {
        std::lock_guard<std::mutex> lock_b(b);
        both_holding_first_lock.arrive_and_wait();
        std::lock_guard<std::mutex> lock_a(a); // blocks forever: t1 holds a
        (void)lock_a;
    });

    t1.join();
    t2.join();

    // Unreachable under a genuine deadlock. Printed only if this binary is
    // ever rebuilt without the bug, so a future fix doesn't masquerade as
    // a silent hang instead of a visible (if surprising) success line.
    fmt::print("mode=deadlock result=completed-unexpectedly\n");
}

// Same opposing acquisition order, fixed via std::scoped_lock, which does
// not care which order its own arguments were given -- it tries all of
// them, backs off on failure, and retries, so two threads naming the same
// two mutexes in opposite argument order cannot deadlock each other.
void run_fixed(int iterations) {
    std::mutex a;
    std::mutex b;
    std::atomic<std::int64_t> ops{0};

    auto worker = [&](bool reversed) {
        for (int i = 0; i < iterations; ++i) {
            if (reversed) {
                std::scoped_lock lock(b, a);
                ops.fetch_add(1, std::memory_order_relaxed);
            } else {
                std::scoped_lock lock(a, b);
                ops.fetch_add(1, std::memory_order_relaxed);
            }
        }
    };

    std::thread t1([&] { worker(false); });
    std::thread t2([&] { worker(true); });
    t1.join();
    t2.join();

    fmt::print("mode=fixed iterations={} total_ops={} result=ok\n",
        iterations, ops.load());
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
            fmt::print("usage: lock_ordering --mode deadlock|fixed [-n ITERATIONS]\n");
            return 0;
        }
    }

    if (iterations < 1) {
        iterations = 1;
    }

    if (mode == "deadlock") {
        run_deadlock();
    } else {
        run_fixed(iterations);
    }

    return 0;
}
