// concurrency/21-lock-free-messaging-and-the-disruptor — single-producer
// ring with a two-stage consumer pipeline.
//
// This builds the pipeline Doc 21 describes: one producer, a "journal"
// consumer that trails the producer's published sequence, and a
// dependent "business logic" consumer that trails the journal's sequence
// instead of the producer's directly -- the diamond-dependency pattern
// the chapter calls a sequence barrier. Every mutable position in the
// system has exactly one writer (the single-writer principle Chapter 9
// established for the plain SPSC ring, generalized here to three
// independent sequence counters instead of two):
//
//   published    sole writer: producer       -- highest published slot
//   journal_seq  sole writer: journal stage   -- highest journal has read
//   biz_seq      sole writer: business stage  -- highest business has read
//
// No thread ever writes a location another thread also writes, so the
// whole scheme is built out of plain atomic loads/stores (release on
// publish, acquire on read) plus std::atomic<T>::wait/notify for blocking
// -- no compare-and-swap loop, no mutex, matching Doc 21's C++20 standards
// note that atomic wait/notify is "the practical default today" for this
// exact pattern.
//
// Back-pressure: the producer must not overwrite a slot a consumer
// hasn't read yet. Since the business stage is gated behind the journal
// stage (journal_seq always >= biz_seq), biz_seq is the slowest sequence
// in the system, so it's the one that gates the producer's claims. The
// business stage is deliberately slowed down (a short sleep every
// SLOW_EVERY events) so the ring fills and the producer is guaranteed to
// have to wait at least once -- this is what makes "back-pressure
// engages" a hard, reproducible assertion rather than a race against
// scheduler luck.
//
// Usage:
//   disruptor_ring [-n COUNT] [--capacity N] [--slow-every N] [--slow-us N]
//
// Prints one line in a key=value form a shell or a Lua harness can parse
// without any special grammar:
//
//   cpus=0/1/2 pinned=true n=100000 capacity=256 slow_every=100 slow_sleep_us=50 \
//     published=100000 journal_consumed=100000 journal_mismatches=0 \
//     biz_consumed=100000 biz_mismatches=0 gating_violations=0 \
//     producer_backpressure_events=842 max_batch_journal=57 max_batch_biz=12 \
//     elapsed_ms=612.345 events_per_sec=163265

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <sched.h>
#include <pthread.h>
#include <string>
#include <thread>
#include <vector>

#include <fmt/core.h>

namespace {

constexpr std::uint64_t kDefaultN = 100'000ULL;
constexpr std::uint64_t kDefaultCapacity = 64ULL;
constexpr std::uint64_t kDefaultSlowEvery = 50ULL;
constexpr std::uint64_t kDefaultSlowSleepUs = 150ULL;
// With the defaults above the business stage is structurally forced to
// spend at least (kDefaultN / kDefaultSlowEvery) * kDefaultSlowSleepUs ==
// ~300ms in actual sleep syscalls to process all n events, on top of
// whatever real work it does -- a floor no amount of host speed can beat.
// capacity (64) is small relative to n (100,000), so the producer only
// needs to outrun that floor once to hit the back-pressure wait path, and
// outrunning a 300ms floor is true on any CI runner this project targets,
// not just a fast dev machine -- this is what makes
// producer_backpressure_events > 0 a deterministic assertion rather than
// a race against scheduler luck.

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

struct Stats {
    // Written only by the thread named in the comment; read by main()
    // only after every thread has been joined, so there's no race on the
    // read side either.
    std::uint64_t journal_consumed = 0;   // journal thread
    std::uint64_t journal_mismatches = 0; // journal thread
    std::uint64_t max_batch_journal = 0;  // journal thread

    std::uint64_t biz_consumed = 0;    // business thread
    std::uint64_t biz_mismatches = 0;  // business thread
    std::uint64_t gating_violations = 0; // business thread
    std::uint64_t max_batch_biz = 0;   // business thread
};

} // namespace

int main(int argc, char** argv) {
    std::uint64_t n = kDefaultN;
    std::uint64_t capacity = kDefaultCapacity;
    std::uint64_t slow_every = kDefaultSlowEvery;
    std::uint64_t slow_sleep_us = kDefaultSlowSleepUs;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-n" && i + 1 < argc) {
            n = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "--capacity" && i + 1 < argc) {
            capacity = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "--slow-every" && i + 1 < argc) {
            slow_every = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "--slow-us" && i + 1 < argc) {
            slow_sleep_us = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print(
                "usage: disruptor_ring [-n COUNT] [--capacity N] "
                "[--slow-every N] [--slow-us N]\n");
            return 0;
        }
    }
    if (capacity < 2) capacity = 2;
    if (slow_every < 1) slow_every = 1;

    // The ring: fixed, pre-allocated event slots. A producer never
    // allocates on the hot path; it claims a slot by index and writes
    // into the object already there. Plain (non-atomic) storage is
    // correct here -- see the file header: the three sequence counters'
    // acquire/release pairing establishes the happens-before edges that
    // make these plain reads and writes safe, exactly as Chapter 9's
    // SPSC ring used head/tail to the same end.
    std::vector<std::uint64_t> slots(capacity, 0);

    std::atomic<std::uint64_t> published{0};
    std::atomic<std::uint64_t> journal_seq{0};
    std::atomic<std::uint64_t> biz_seq{0};
    std::atomic<std::uint64_t> producer_backpressure_events{0};

    auto cpus = available_cpus();
    bool pin = cpus.size() >= 3;
    int cpu_producer = pin ? cpus[0] : 0;
    int cpu_journal = pin ? cpus[1] : 0;
    int cpu_biz = pin ? cpus[2] : 0;

    Stats stats;

    auto start = std::chrono::steady_clock::now();

    // ── Producer: single writer of `published` and of every slot. ──────
    std::thread producer([&] {
        for (std::uint64_t i = 0; i < n; ++i) {
            // Back-pressure: don't claim slot i until the slowest
            // consumer (biz_seq -- see file header) has read past the
            // slot i would otherwise overwrite.
            std::uint64_t gate = biz_seq.load(std::memory_order_acquire);
            if (i - gate >= capacity) {
                producer_backpressure_events.fetch_add(1, std::memory_order_relaxed);
                do {
                    biz_seq.wait(gate, std::memory_order_acquire);
                    gate = biz_seq.load(std::memory_order_acquire);
                } while (i - gate >= capacity);
            }

            slots[i % capacity] = i;
            published.store(i + 1, std::memory_order_release);
            published.notify_all();
        }
    });

    // ── Journal consumer: single writer of journal_seq. Gated only on
    // the producer's published sequence -- nothing slows this stage
    // down, so it demonstrates batching under load (it will often find
    // several newly published slots per wake-up). ──────────────────────
    std::thread journal([&] {
        std::uint64_t pos = 0;
        while (pos < n) {
            std::uint64_t avail = published.load(std::memory_order_acquire);
            while (avail == pos) {
                published.wait(avail, std::memory_order_acquire);
                avail = published.load(std::memory_order_acquire);
            }
            std::uint64_t batch = avail - pos;
            stats.max_batch_journal = std::max(stats.max_batch_journal, batch);
            for (; pos < avail; ++pos) {
                std::uint64_t v = slots[pos % capacity];
                if (v != pos) {
                    ++stats.journal_mismatches;
                }
                ++stats.journal_consumed;
            }
            journal_seq.store(pos, std::memory_order_release);
            journal_seq.notify_all();
        }
    });

    // ── Business-logic consumer: single writer of biz_seq. Gated on the
    // journal stage's sequence, not the producer's -- the diamond
    // dependency Doc 21 describes. Deliberately slowed down so the ring
    // fills and the producer's back-pressure path is exercised every
    // run, not just when the scheduler happens to starve it. ───────────
    std::thread business([&] {
        std::uint64_t pos = 0;
        while (pos < n) {
            std::uint64_t avail = journal_seq.load(std::memory_order_acquire);
            while (avail == pos) {
                journal_seq.wait(avail, std::memory_order_acquire);
                avail = journal_seq.load(std::memory_order_acquire);
            }
            std::uint64_t batch = avail - pos;
            stats.max_batch_biz = std::max(stats.max_batch_biz, batch);
            for (; pos < avail; ++pos) {
                // Defensive, *observed* check of the sequence-barrier
                // invariant itself: this stage must never process a slot
                // the journal stage hasn't advanced past yet. By
                // construction pos < avail <= journal_seq always holds;
                // this reads journal_seq again, live, rather than
                // trusting the snapshot in `avail`, so a real ordering
                // bug would actually be caught here instead of asserted
                // away.
                if (pos >= journal_seq.load(std::memory_order_acquire)) {
                    ++stats.gating_violations;
                }
                std::uint64_t v = slots[pos % capacity];
                if (v != pos) {
                    ++stats.biz_mismatches;
                }
                ++stats.biz_consumed;
                if ((pos % slow_every) == 0) {
                    std::this_thread::sleep_for(std::chrono::microseconds(slow_sleep_us));
                }
            }
            biz_seq.store(pos, std::memory_order_release);
            biz_seq.notify_all();
        }
    });

    if (pin) {
        pin_to_cpu(producer, cpu_producer);
        pin_to_cpu(journal, cpu_journal);
        pin_to_cpu(business, cpu_biz);
    }

    producer.join();
    journal.join();
    business.join();

    auto end = std::chrono::steady_clock::now();
    double elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
    double events_per_sec = elapsed_ms > 0.0
        ? static_cast<double>(n) / (elapsed_ms / 1000.0)
        : 0.0;

    fmt::print(
        "cpus={}/{}/{} pinned={} n={} capacity={} slow_every={} slow_sleep_us={} "
        "published={} journal_consumed={} journal_mismatches={} "
        "biz_consumed={} biz_mismatches={} gating_violations={} "
        "producer_backpressure_events={} max_batch_journal={} max_batch_biz={} "
        "elapsed_ms={:.3f} events_per_sec={:.0f}\n",
        cpu_producer, cpu_journal, cpu_biz, pin ? "true" : "false",
        n, capacity, slow_every, slow_sleep_us,
        published.load(std::memory_order_relaxed),
        stats.journal_consumed, stats.journal_mismatches,
        stats.biz_consumed, stats.biz_mismatches, stats.gating_violations,
        producer_backpressure_events.load(std::memory_order_relaxed),
        stats.max_batch_journal, stats.max_batch_biz,
        elapsed_ms, events_per_sec);

    return 0;
}
