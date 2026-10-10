// concurrency/08-atomics-and-the-memory-model — one-slot hand-off under
// three orderings.
//
// One producer thread and one consumer thread move values 0..N-1 through a
// single-slot "ring" (capacity 1 -- the tightest possible contention, every
// push waiting on the previous pop and vice versa), the same lockstep
// hand-off the chapter derives: the producer writes the slot, then
// publishes it by advancing `tail`; the consumer waits for `tail` to
// advance, reads the slot, then advances `head` to free it for the next
// push. Run three ways:
//
//   --mode seqcst   tail/head are std::atomic<uint64_t>; every operation
//                   uses the type's default ordering (sequential
//                   consistency) -- the strongest, safest default.
//   --mode acqrel   tail/head are std::atomic<uint64_t>; the producer's
//                   `tail.store` is release and the consumer's `tail.load`
//                   is acquire (publishing/observing the slot write), and
//                   symmetrically the consumer's `head.store` is release
//                   and the producer's `head.load` is acquire (publishing/
//                   observing that the slot is free again). This is the
//                   chapter's minimal happens-before pairing, with nothing
//                   stronger than the hand-off actually needs.
//   --mode broken   tail/head are PLAIN uint64_t -- no std::atomic, no
//                   volatile, no ordering of any kind. This is the
//                   deliberately-broken negative case: a busy-wait loop
//                   reading an ordinary shared variable gives the compiler
//                   no reason to believe the variable can change inside the
//                   loop (nothing in the loop's visible code writes it), so
//                   -O2's loop-invariant code motion is free to load it
//                   once, cache it in a register, and spin on that cached
//                   copy forever -- even while the other thread keeps
//                   writing the real memory location. This is exactly the
//                   "needs volatile or atomic" bug every systems-programming
//                   text warns about, and it is deterministic per compiled
//                   binary (a code-generation decision, not a scheduler
//                   roll of the dice), so it reproduces identically on every
//                   run of the same build. Each spin wait is bounded by
//                   kMaxSpins so a stalled hand-off reports itself via
//                   `stalled=true` instead of hanging the process -- the
//                   goal is to observe the divergence safely, never to
//                   actually wedge a CI runner.
//
// Usage:
//   ring_handoff --mode seqcst|acqrel|broken [-n ITERATIONS]
//
// Prints one line in a key=value form a shell or a Lua harness can parse
// without any special grammar:
//
//   mode=seqcst n=2000000 completed=true consumed=2000000 sum=1999999000000 \
//     expected_sum=1999999000000 stalled=false elapsed_ms=312.4 ops_per_sec=6402048

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <sched.h>
#include <pthread.h>
#include <string>
#include <thread>
#include <vector>

#include <fmt/core.h>

namespace {

constexpr std::uint64_t kCapacity = 1;         // one-slot hand-off
constexpr std::uint64_t kMaxSpins = 20'000'000ULL; // bounded spin: never hang
constexpr std::uint64_t kDefaultIterations = 2'000'000ULL;

struct RunResult {
    bool completed = false;
    bool stalled = false;
    std::uint64_t consumed = 0;
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

// The two correct variants share this body, parameterized only by which
// memory_order each of the four operations uses. seq_cst passes the same
// order to all four; acq_rel passes release on the publishing stores and
// acquire on the observing loads (see the file header).
RunResult run_with_atomics(std::uint64_t n, bool pin, int cpu_a, int cpu_b,
                            std::memory_order tail_store_order,
                            std::memory_order tail_load_order,
                            std::memory_order head_store_order,
                            std::memory_order head_load_order) {
    std::atomic<std::uint64_t> head{0};
    std::atomic<std::uint64_t> tail{0};
    std::array<std::uint64_t, kCapacity> buf{};
    std::atomic<bool> stalled{false};

    auto start = std::chrono::steady_clock::now();

    std::thread producer([&] {
        std::uint64_t t = 0;
        for (std::uint64_t i = 0; i < n; ++i) {
            std::uint64_t spins = 0;
            while (t - head.load(head_load_order) == kCapacity) {
                // spin: slot still occupied, consumer hasn't freed it yet
                if (++spins > kMaxSpins) {
                    stalled.store(true, std::memory_order_relaxed);
                    return;
                }
            }
            buf[t % kCapacity] = i;
            ++t;
            tail.store(t, tail_store_order);
        }
    });

    std::uint64_t consumed = 0;
    std::uint64_t sum = 0;

    std::thread consumer([&] {
        std::uint64_t h = 0;
        for (std::uint64_t i = 0; i < n; ++i) {
            std::uint64_t spins = 0;
            while (h == tail.load(tail_load_order)) {
                // spin: slot still empty, producer hasn't published it yet
                if (++spins > kMaxSpins) {
                    stalled.store(true, std::memory_order_relaxed);
                    return;
                }
            }
            sum += buf[h % kCapacity];
            ++h;
            ++consumed;
            head.store(h, head_store_order);
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
    r.stalled = stalled.load(std::memory_order_relaxed);
    r.consumed = consumed;
    r.sum = sum;
    r.completed = !r.stalled && consumed == n;
    r.elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
    return r;
}

// The deliberately-broken negative case: plain, non-atomic, non-volatile
// `head`/`tail`. See the file header for why -O2 reliably turns the
// consumer's (and potentially the producer's) spin loop into a busy-wait on
// a register-cached, stale value rather than a true memory read every pass.
RunResult run_broken(std::uint64_t n, bool pin, int cpu_a, int cpu_b) {
    std::uint64_t head = 0;  // NOT atomic, NOT volatile -- the point of this case
    std::uint64_t tail = 0;  // NOT atomic, NOT volatile -- the point of this case
    std::array<std::uint64_t, kCapacity> buf{};
    bool producer_stalled = false;
    bool consumer_stalled = false;

    auto start = std::chrono::steady_clock::now();

    std::thread producer([&] {
        std::uint64_t t = 0;
        for (std::uint64_t i = 0; i < n; ++i) {
            std::uint64_t spins = 0;
            while (t - head == kCapacity) {
                if (++spins > kMaxSpins) {
                    producer_stalled = true;
                    return;
                }
            }
            buf[t % kCapacity] = i;
            ++t;
            tail = t; // plain store: no happens-before edge to the consumer at all
        }
    });

    std::uint64_t consumed = 0;
    std::uint64_t sum = 0;

    std::thread consumer([&] {
        std::uint64_t h = 0;
        for (std::uint64_t i = 0; i < n; ++i) {
            std::uint64_t spins = 0;
            while (h == tail) {
                // THE BUG: a plain read of a shared variable in a busy-wait
                // loop. Nothing inside this loop's visible code writes
                // `tail`, so the optimizer is free to treat it as
                // loop-invariant and cache it in a register for the life of
                // the loop -- even though another thread is concurrently
                // writing the real memory location.
                if (++spins > kMaxSpins) {
                    consumer_stalled = true;
                    return;
                }
            }
            sum += buf[h % kCapacity];
            ++h;
            ++consumed;
            head = h; // plain store: no happens-before edge to the producer either
        }
    });

    if (pin) {
        pin_to_cpu(producer, cpu_a);
        pin_to_cpu(consumer, cpu_b);
    }

    // thread::join() is itself a synchronization point (the joined thread's
    // completion happens-before join() returns), so reading the plain
    // locals below from main afterward is well-defined -- the race this
    // example demonstrates is strictly the producer/consumer loops' shared
    // reads/writes of `head`/`tail` while both threads are running
    // concurrently, not these final reads.
    producer.join();
    consumer.join();

    auto end = std::chrono::steady_clock::now();

    RunResult r;
    r.stalled = producer_stalled || consumer_stalled;
    r.consumed = consumed;
    r.sum = sum;
    r.completed = !r.stalled && consumed == n;
    r.elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
    return r;
}

} // namespace

int main(int argc, char** argv) {
    std::string mode = "seqcst";
    std::uint64_t n = kDefaultIterations;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--mode" && i + 1 < argc) {
            mode = argv[++i];
        } else if (arg == "-n" && i + 1 < argc) {
            n = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: ring_handoff --mode seqcst|acqrel|broken [-n ITERATIONS]\n");
            return 0;
        }
    }

    if (n == 0) {
        fmt::print(stderr, "error: -n must be >= 1\n");
        return 2;
    }

    auto cpus = available_cpus();
    bool pin = cpus.size() >= 2;
    int cpu_a = pin ? cpus[0] : 0;
    int cpu_b = pin ? cpus[1] : 0;

    RunResult r;
    if (mode == "seqcst") {
        r = run_with_atomics(n, pin, cpu_a, cpu_b,
                              std::memory_order_seq_cst, std::memory_order_seq_cst,
                              std::memory_order_seq_cst, std::memory_order_seq_cst);
    } else if (mode == "acqrel") {
        r = run_with_atomics(n, pin, cpu_a, cpu_b,
                              /*tail_store*/ std::memory_order_release,
                              /*tail_load*/  std::memory_order_acquire,
                              /*head_store*/ std::memory_order_release,
                              /*head_load*/  std::memory_order_acquire);
    } else if (mode == "broken") {
        r = run_broken(n, pin, cpu_a, cpu_b);
    } else {
        fmt::print(stderr, "error: unknown --mode '{}' (want seqcst|acqrel|broken)\n", mode);
        return 2;
    }

    std::uint64_t expected_sum = n * (n - 1) / 2;
    double ops_per_sec = r.elapsed_ms > 0.0
        ? (static_cast<double>(r.consumed) / (r.elapsed_ms / 1000.0))
        : 0.0;

    fmt::print(
        "mode={} n={} completed={} consumed={} sum={} expected_sum={} stalled={} "
        "elapsed_ms={:.3f} ops_per_sec={:.0f}\n",
        mode, n, r.completed, r.consumed, r.sum, expected_sum, r.stalled,
        r.elapsed_ms, ops_per_sec);

    return 0;
}
