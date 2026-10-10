// concurrency/27-debugging-races-deadlocks — a real, deterministic AB/BA
// deadlock, plus its std::scoped_lock fix.
//
// Two Account objects, each with its own std::mutex. run_transfer(from, to)
// locks `from.mutex` first, then `to.mutex`, exactly modeling a transfer
// debiting one account and crediting another. Two threads call it with the
// two accounts in OPPOSITE order -- one does run_transfer(a, b), the other
// run_transfer(b, a) -- the textbook AB/BA shape.
//
// Left to scheduling luck, that shape deadlocks only sometimes: both
// threads have to reach their SECOND lock() call while the other already
// holds its first, a timing window that can be narrow enough to miss most
// runs on an idle machine. A std::latch(2) forces the window open on
// purpose: both threads count down immediately after acquiring their first
// lock and wait on the latch before attempting their second, so neither
// can reach its second acquisition until BOTH already hold their first.
// That turns "sometimes deadlocks" into "deadlocks on every single run" --
// the only version of this bug worth handing to gdb or a CI gate.
//
// Usage:
//   ab_ba_deadlock --mode deadlock   forces the AB/BA deadlock; prints its
//                                    own pid, then hangs forever by design.
//                                    The caller is expected to run this
//                                    under an external `timeout` and/or
//                                    attach gdb to the printed pid.
//   ab_ba_deadlock --mode fixed [-n ITERATIONS]
//                                    the identical opposing acquisition
//                                    order, but via std::scoped_lock, which
//                                    doesn't care what order its own
//                                    arguments were given -- it always
//                                    completes.

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <latch>
#include <mutex>
#include <string>
#include <thread>

#if defined(__unix__) || defined(__APPLE__)
#include <unistd.h>
#endif

#include <fmt/core.h>

namespace {

constexpr int kDefaultIterations = 20'000;
constexpr long kTransferAmount = 1;

struct Account {
    std::mutex mutex;
    const char* name;
    long balance;
};

// The Account-level acquisition function both deadlock-mode threads call,
// with `from`/`to` swapped between them. noinline so it always shows up by
// its own name in a gdb backtrace -- "two Account-level acquisition
// functions" means this frame, present (and blocked) in BOTH threads.
__attribute__((noinline))
void run_transfer(Account& from, Account& to, std::latch& both_holding_first_lock, long amount) {
    std::lock_guard<std::mutex> lock_from(from.mutex);
    // Neither thread proceeds to its second lock() until BOTH threads
    // already hold their first -- the forcing function that turns
    // scheduling luck into a guaranteed circular wait.
    both_holding_first_lock.arrive_and_wait();
    std::lock_guard<std::mutex> lock_to(to.mutex); // blocks forever under --mode deadlock
    from.balance -= amount;
    to.balance += amount;
}

[[noreturn]] void run_deadlock() {
    Account account_a{{}, "A", 1'000};
    Account account_b{{}, "B", 1'000};
    std::latch both_holding_first_lock(2);

#if defined(__unix__) || defined(__APPLE__)
    long pid = static_cast<long>(getpid());
#else
    long pid = -1;
#endif
    fmt::print("mode=deadlock pid={} starting (expected to hang -- attach gdb or run under timeout)\n", pid);
    std::fflush(stdout);

    // Thread "2": account_b -> account_a (locks b then a).
    std::thread t2([&] {
        run_transfer(account_b, account_a, both_holding_first_lock, kTransferAmount);
    });
    // Thread "3": account_a -> account_b (locks a then b).
    std::thread t3([&] {
        run_transfer(account_a, account_b, both_holding_first_lock, kTransferAmount);
    });

    t2.join();
    t3.join();

    // Unreachable under a genuine AB/BA deadlock -- printed only if this
    // binary is ever rebuilt without the bug, so a future fix doesn't
    // masquerade as a silent hang instead of a visible success line.
    fmt::print("mode=deadlock result=completed-unexpectedly\n");
    std::exit(0);
}

// Same opposing acquisition order (account_a->account_b on one thread,
// account_b->account_a on the other), fixed via std::scoped_lock, which
// tries all of its arguments, backs off on failure, and retries -- it does
// not care which order the two threads named them in, so this can never
// deadlock no matter how many iterations run.
void run_fixed(int iterations) {
    Account account_a{{}, "A", 1'000};
    Account account_b{{}, "B", 1'000};
    std::atomic<std::int64_t> ops{0};

    auto worker = [&](Account& from, Account& to) {
        for (int i = 0; i < iterations; ++i) {
            std::scoped_lock lock(from.mutex, to.mutex);
            from.balance -= kTransferAmount;
            to.balance += kTransferAmount;
            ops.fetch_add(1, std::memory_order_relaxed);
        }
    };

    std::thread t1([&] { worker(account_a, account_b); });
    std::thread t2([&] { worker(account_b, account_a); });
    t1.join();
    t2.join();

    fmt::print("mode=fixed iterations={} total_ops={} result=ok\n", iterations, ops.load());
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
            fmt::print("usage: ab_ba_deadlock --mode deadlock|fixed [-n ITERATIONS]\n");
            return 0;
        }
    }

    if (iterations < 1) iterations = 1;

    if (mode == "deadlock") {
        run_deadlock();
    } else {
        run_fixed(iterations);
    }

    return 0;
}
