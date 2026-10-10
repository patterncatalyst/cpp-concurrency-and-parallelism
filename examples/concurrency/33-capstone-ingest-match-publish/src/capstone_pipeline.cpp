// concurrency/33-capstone-ingest-match-publish — the book's capstone:
// ingest -> match -> publish, in one process.
//
// This is not a new idea; it is the rest of the book wired together the
// way Doc 33 describes. Every piece below is a direct, smaller application
// of an earlier chapter's technique rather than something invented fresh
// for this file:
//
//   INGEST   several producer threads (ch15's thread-pool shape, standing
//            in for ch24/25's connection handlers) decode NEW/CANCEL
//            order messages, stamp an arrival timestamp, and reject
//            anything whose deadline (ch3) has already passed before it
//            is allowed to cost the match stage a single cycle.
//
//   RING     a bounded, lock-free hand-off built on the single-writer
//            sequence discipline ch9's SPSC ring and ch21's disruptor
//            ring both establish -- generalized here to a per-slot
//            sequence number (Dmitry Vyukov's bounded MPMC queue) so the
//            SAME ring type safely supports many producers on the ingest
//            side and many consumers on the publish side, while keeping
//            each slot's hand-off a single-writer-then-single-reader
//            operation exactly like the simpler two-counter rings. A ring
//            is bounded, never grown: a full ring makes back-pressure a
//            visible, immediate signal (BUSY) instead of an unbounded
//            queue's invisible memory liability.
//
//   MATCH    exactly one thread, pinned to one core, is the sole writer
//            of the order book -- ch31's single-writer pattern and ch19's
//            fast-path playbook (pinned core, busy-poll read, zero
//            per-order heap allocation: the book's pool and price levels
//            are pre-sized once at startup, never resized on the hot
//            path). Price-time priority is a real, working limit order
//            book: intrusive doubly-linked FIFOs per price level, O(1)
//            insert/remove, cached best-bid/best-ask pointers.
//
//   PUBLISH  a small pool of threads drains the match stage's output ring
//            and "writes" each outcome out (to an in-memory buffer stood
//            in for a subscriber socket, per ch9's multi-consumer
//            technique) -- the one stage that genuinely parallelizes,
//            unlike match.
//
// What every example in this project prints is a reporting contract, not
// a judgment: this binary always exits 0 and only prints facts (one
// key=value EVENT line per accepted order, one SUMMARY line of counters
// and latency percentiles). verify.lua is where the hard/soft assertions
// tied to those facts live -- this mirrors every sibling example's
// "binary reports, Lua judges" convention.
//
// Usage:
//   capstone_pipeline [--sustained N] [--burst N] [--ingest-threads N]
//                      [--publish-threads N] [--ingest-capacity N]
//                      [--publish-capacity N]
//
// Output: one "EVENT ..." line per accepted order (in arbitrary print
// order -- match_seq is the field that carries the real ordering) and a
// single final "SUMMARY ..." line.

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <sched.h>
#include <pthread.h>
#include <string>
#include <thread>
#include <unistd.h>
#include <sys/syscall.h>
#include <vector>

// fmt/format.h (not just fmt/core.h, which the rest of this book's
// examples use for fmt::print alone) -- this example also builds each
// EVENT line into a std::string with fmt::format before deferring the
// actual print to after every thread has joined (see publish_worker).
#include <fmt/format.h>

namespace {

// ════════════════════════════════════════════════════════════════════════
// Small helpers shared with the rest of this book's examples.
// ════════════════════════════════════════════════════════════════════════

#if defined(__cpp_lib_hardware_interference_size)
constexpr std::size_t kLineSize = std::hardware_destructive_interference_size;
#else
constexpr std::size_t kLineSize = 64;
#endif

std::uint32_t tid() {
    return static_cast<std::uint32_t>(::syscall(SYS_gettid));
}

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

bool is_pow2(std::uint64_t v) { return v >= 2 && (v & (v - 1)) == 0; }

// ════════════════════════════════════════════════════════════════════════
// BoundedRing<T> — a bounded, lock-free MPMC ring (Dmitry Vyukov's bounded
// queue algorithm). Doc 9 and Doc 21's rings get single-writer safety from
// one atomic counter each writer alone advances; this ring generalizes
// that to a PER-SLOT sequence number so several producers (ingest) or
// several consumers (publish) can each win one slot via a single CAS,
// while every slot's own hand-off between the thread that claims it and
// the thread that completes it is still, underneath, a single-writer
// relationship -- the same mechanical-sympathy principle ch9/ch21 teach,
// applied at the granularity of one cell instead of the whole ring.
//
// `enqueue_pos_` and `dequeue_pos_` are each alignas(kLineSize) for the
// same reason ch20 pads the mechanical-sympathy counters: a producer's
// CAS on enqueue_pos_ and a consumer's CAS on dequeue_pos_ touch disjoint
// data but would otherwise share a cache line and serialize on every
// hand-off regardless of how many producers/consumers there are.
// ════════════════════════════════════════════════════════════════════════
template <typename T>
class BoundedRing {
public:
    explicit BoundedRing(std::uint64_t capacity)
        : mask_(capacity - 1), buffer_(capacity) {
        for (std::uint64_t i = 0; i < capacity; ++i) {
            buffer_[i].seq.store(i, std::memory_order_relaxed);
        }
    }

    bool try_push(T&& item) {
        Cell* cell;
        std::uint64_t pos = enqueue_pos_.load(std::memory_order_relaxed);
        for (;;) {
            cell = &buffer_[pos & mask_];
            std::uint64_t seq = cell->seq.load(std::memory_order_acquire);
            std::int64_t diff = static_cast<std::int64_t>(seq) - static_cast<std::int64_t>(pos);
            if (diff == 0) {
                if (enqueue_pos_.compare_exchange_weak(pos, pos + 1, std::memory_order_relaxed)) {
                    break;
                }
            } else if (diff < 0) {
                return false; // full: the slot this claim would need hasn't been freed yet
            } else {
                pos = enqueue_pos_.load(std::memory_order_relaxed);
            }
        }
        cell->data = std::move(item);
        cell->seq.store(pos + 1, std::memory_order_release);
        return true;
    }

    bool try_pop(T& item) {
        Cell* cell;
        std::uint64_t pos = dequeue_pos_.load(std::memory_order_relaxed);
        for (;;) {
            cell = &buffer_[pos & mask_];
            std::uint64_t seq = cell->seq.load(std::memory_order_acquire);
            std::int64_t diff = static_cast<std::int64_t>(seq) - static_cast<std::int64_t>(pos + 1);
            if (diff == 0) {
                if (dequeue_pos_.compare_exchange_weak(pos, pos + 1, std::memory_order_relaxed)) {
                    break;
                }
            } else if (diff < 0) {
                return false; // empty: nothing published up to this slot yet
            } else {
                pos = dequeue_pos_.load(std::memory_order_relaxed);
            }
        }
        item = std::move(cell->data);
        cell->seq.store(pos + mask_ + 1, std::memory_order_release);
        return true;
    }

    // Approximate occupancy: a point-in-time snapshot taken from two
    // independently-advancing atomics under concurrent producers and
    // consumers. Good enough for the observability use this example puts
    // it to (a reported ring-occupancy attribute, a peak-occupancy
    // high-water mark) -- never used for a correctness decision, only
    // for what gets printed.
    std::uint64_t occupancy() const {
        std::uint64_t e = enqueue_pos_.load(std::memory_order_acquire);
        std::uint64_t d = dequeue_pos_.load(std::memory_order_acquire);
        std::uint64_t occ = e >= d ? e - d : 0;
        std::uint64_t cap = mask_ + 1;
        // Two separate relaxed/acquire loads are a snapshot, not a transaction:
        // a producer's enqueue can be observed before the matching consumer's
        // dequeue, transiently reading one past capacity. The ring is truly
        // bounded (a push is rejected when full), so clamp the reported value.
        return occ < cap ? occ : cap;
    }

    bool empty() const { return occupancy() == 0; }
    std::uint64_t capacity() const { return mask_ + 1; }

private:
    struct Cell {
        std::atomic<std::uint64_t> seq{0};
        T data{};
    };

    std::uint64_t mask_;
    alignas(kLineSize) std::atomic<std::uint64_t> enqueue_pos_{0};
    alignas(kLineSize) std::atomic<std::uint64_t> dequeue_pos_{0};
    std::vector<Cell> buffer_;
};

// ════════════════════════════════════════════════════════════════════════
// Messages and events.
// ════════════════════════════════════════════════════════════════════════

enum class MsgKind : std::uint8_t { New, Cancel };
enum class Outcome : std::uint8_t { Rested, Filled, CancelOk, CancelMiss };

const char* kind_str(MsgKind k) { return k == MsgKind::New ? "NEW" : "CANCEL"; }
const char* outcome_str(Outcome o) {
    switch (o) {
        case Outcome::Rested:     return "RESTED";
        case Outcome::Filled:     return "FILLED";
        case Outcome::CancelOk:   return "CANCEL_OK";
        case Outcome::CancelMiss: return "CANCEL_MISS";
    }
    return "?";
}

// What an ingest thread hands to the match thread over the ingest ring.
// Every field a CANCEL message doesn't use is simply left at its default.
struct OrderMsg {
    MsgKind kind = MsgKind::New;
    std::uint64_t order_id = 0;     // NEW: this order's own id
    std::uint64_t target_id = 0;    // CANCEL: the id to cancel
    std::uint32_t price = 0;        // NEW only
    bool side_buy = false;          // NEW only
    std::uint64_t ingest_ts_ns = 0;
    std::uint32_t producer_tid = 0;
    std::uint32_t ring_occ_at_claim = 0;
};

// What the match thread hands to the publish pool over the publish ring.
struct PublishEvent {
    std::uint64_t match_seq = 0;    // assigned in match-processing order -- the
                                     // field that carries "the correct matching
                                     // order" once events land at publish.
    MsgKind kind = MsgKind::New;
    Outcome outcome = Outcome::Rested;
    std::uint64_t order_id = 0;     // NEW's own id, or CANCEL's target id
    std::uint32_t price = 0;
    bool side_buy = false;
    std::uint64_t ingest_ts_ns = 0;
    std::uint32_t producer_tid = 0;
    std::uint32_t match_tid = 0;
    std::uint32_t ring_occ_at_claim = 0;
};

// ════════════════════════════════════════════════════════════════════════
// MatchEngine — the order book. Ch19's fast-path playbook applied to a
// real (if simplified-to-unit-quantity) price-time-priority limit order
// book: every order occupies one pre-allocated pool slot for its entire
// life, price levels are intrusive doubly-linked FIFOs over pool indices
// (no node ever allocated or freed), and best-bid/best-ask are cached
// pointers updated incrementally rather than rescanned from scratch.
//
// This class has exactly one caller: the match thread. That is the whole
// of its thread-safety story (ch31's single-writer pattern) -- nothing in
// here is atomic, locked, or otherwise synchronized, because nothing
// needs to be.
// ════════════════════════════════════════════════════════════════════════
class MatchEngine {
public:
    MatchEngine(std::uint64_t max_orders, std::uint32_t price_levels)
        : price_levels_(price_levels),
          pool_(max_orders),
          bid_head_(price_levels, -1), bid_tail_(price_levels, -1),
          ask_head_(price_levels, -1), ask_tail_(price_levels, -1) {}

    Outcome process_new(std::uint64_t order_id, std::uint32_t price, bool side_buy) {
        std::uint32_t level = price - 1;
        if (side_buy) {
            if (best_ask_ != -1 && static_cast<std::uint32_t>(best_ask_) + 1 <= price) {
                std::int32_t victim = ask_head_[static_cast<std::size_t>(best_ask_)];
                unlink(victim, static_cast<std::uint32_t>(best_ask_), /*buy=*/false);
                ++filled_later_;
                ++filled_as_aggressor_;
                return Outcome::Filled;
            }
        } else {
            if (best_bid_ != -1 && static_cast<std::uint32_t>(best_bid_) + 1 >= price) {
                std::int32_t victim = bid_head_[static_cast<std::size_t>(best_bid_)];
                unlink(victim, static_cast<std::uint32_t>(best_bid_), /*buy=*/true);
                ++filled_later_;
                ++filled_as_aggressor_;
                return Outcome::Filled;
            }
        }

        // No crossing price available: rest the order (price-time
        // priority means it joins the back of this level's FIFO).
        PoolOrder& o = pool_[order_id];
        o.active = true;
        o.side_buy = side_buy;
        o.price = price;
        insert_level(static_cast<std::int32_t>(order_id), level, side_buy);
        ++rested_;
        return Outcome::Rested;
    }

    Outcome process_cancel(std::uint64_t target_id) {
        if (target_id >= pool_.size() || !pool_[target_id].active) {
            ++cancel_miss_;
            return Outcome::CancelMiss;
        }
        bool buy = pool_[target_id].side_buy;
        std::uint32_t level = pool_[target_id].price - 1;
        unlink(static_cast<std::int32_t>(target_id), level, buy);
        ++cancel_ok_;
        return Outcome::CancelOk;
    }

    // Independent cross-check: scan the pool itself (rather than trust
    // any running counter) and count orders still resting at the end of
    // the run.
    std::uint64_t scan_final_resting() const {
        std::uint64_t n = 0;
        for (const auto& o : pool_) {
            if (o.active) ++n;
        }
        return n;
    }

    std::uint64_t filled_as_aggressor() const { return filled_as_aggressor_; }
    std::uint64_t rested() const { return rested_; }
    std::uint64_t filled_later() const { return filled_later_; }
    std::uint64_t cancel_ok() const { return cancel_ok_; }
    std::uint64_t cancel_miss() const { return cancel_miss_; }

private:
    struct PoolOrder {
        bool active = false;
        bool side_buy = false;
        std::uint32_t price = 0;
        std::int32_t prev = -1;
        std::int32_t next = -1;
    };

    void insert_level(std::int32_t slot, std::uint32_t level, bool buy) {
        auto& head = buy ? bid_head_ : ask_head_;
        auto& tail = buy ? bid_tail_ : ask_tail_;
        pool_[static_cast<std::size_t>(slot)].prev = tail[level];
        pool_[static_cast<std::size_t>(slot)].next = -1;
        if (tail[level] != -1) {
            pool_[static_cast<std::size_t>(tail[level])].next = slot;
        } else {
            head[level] = slot;
        }
        tail[level] = slot;

        if (buy) {
            if (best_bid_ == -1 || static_cast<std::int32_t>(level) > best_bid_) {
                best_bid_ = static_cast<std::int32_t>(level);
            }
        } else {
            if (best_ask_ == -1 || static_cast<std::int32_t>(level) < best_ask_) {
                best_ask_ = static_cast<std::int32_t>(level);
            }
        }
    }

    // Unlinks `slot` from wherever it sits in its price level's doubly
    // linked FIFO -- the head (the common case: a fill always consumes
    // the FIFO head, which is exactly price-time priority) or anywhere
    // else in the middle (a cancel can target any still-resting order).
    void unlink(std::int32_t slot, std::uint32_t level, bool buy) {
        auto& head = buy ? bid_head_ : ask_head_;
        auto& tail = buy ? bid_tail_ : ask_tail_;
        PoolOrder& s = pool_[static_cast<std::size_t>(slot)];
        std::int32_t p = s.prev, n = s.next;
        if (p != -1) pool_[static_cast<std::size_t>(p)].next = n; else head[level] = n;
        if (n != -1) pool_[static_cast<std::size_t>(n)].prev = p; else tail[level] = p;
        s.active = false;
        s.prev = s.next = -1;

        if (head[level] == -1) {
            if (buy && best_bid_ == static_cast<std::int32_t>(level)) {
                std::int32_t l = best_bid_ - 1;
                while (l >= 0 && bid_head_[static_cast<std::size_t>(l)] == -1) --l;
                best_bid_ = l;
            } else if (!buy && best_ask_ == static_cast<std::int32_t>(level)) {
                std::int32_t l = best_ask_ + 1;
                while (l < static_cast<std::int32_t>(price_levels_) &&
                       ask_head_[static_cast<std::size_t>(l)] == -1) {
                    ++l;
                }
                best_ask_ = (l < static_cast<std::int32_t>(price_levels_)) ? l : -1;
            }
        }
    }

    std::uint32_t price_levels_;
    std::vector<PoolOrder> pool_;          // pre-sized once; zero per-order heap use after this
    std::vector<std::int32_t> bid_head_, bid_tail_;
    std::vector<std::int32_t> ask_head_, ask_tail_;
    std::int32_t best_bid_ = -1;
    std::int32_t best_ask_ = -1;

    std::uint64_t filled_as_aggressor_ = 0;
    std::uint64_t rested_ = 0;
    std::uint64_t filled_later_ = 0;
    std::uint64_t cancel_ok_ = 0;
    std::uint64_t cancel_miss_ = 0;
};

// ════════════════════════════════════════════════════════════════════════
// Config / constants.
// ════════════════════════════════════════════════════════════════════════

struct Config {
    std::uint64_t ingest_threads = 4;
    std::uint64_t publish_threads = 3;
    std::uint64_t sustained_per_thread = 1200;
    std::uint64_t burst_per_thread = 2500;
    std::uint64_t ingest_capacity = 64;
    std::uint64_t publish_capacity = 512;
};

constexpr std::uint32_t kPriceLevels = 64;
constexpr std::uint64_t kDeadlineExpireEvery = 97; // ~1% of generated messages arrive pre-expired
constexpr std::uint64_t kSustainedInterSubmitSleepUs = 20;

// The match thread's deliberate, fixed throughput ceiling -- the same
// technique ch21's disruptor_ring uses on its business-logic stage: a
// short sleep every kMatchSlowEveryN processed messages creates a floor
// no amount of host speed can beat (~kMatchSlowEveryN messages per
// kMatchSlowSleepUs microseconds). During the sustained phase, four
// producer threads each pacing themselves at kSustainedInterSubmitSleepUs
// stay comfortably under that floor, so the ingest ring should stay
// mostly empty. During the overload burst, producers submit with no
// pacing at all -- a rate no floor this conservative can keep up with --
// which is what makes the ingest ring filling, and BUSY responses
// following, a deterministic outcome of this run rather than a race
// against scheduler luck on whatever host happens to run it.
constexpr std::uint64_t kMatchSlowEveryN = 30;
constexpr std::uint64_t kMatchSlowSleepUs = 80;

std::uint64_t now_ns() {
    return static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count());
}

void update_peak(std::atomic<std::uint64_t>& peak, std::uint64_t observed) {
    std::uint64_t prev = peak.load(std::memory_order_relaxed);
    while (observed > prev &&
           !peak.compare_exchange_weak(prev, observed, std::memory_order_relaxed)) {
    }
}

// ════════════════════════════════════════════════════════════════════════
// Ingest: several producer threads, each generating its own NEW/CANCEL
// stream (ch24/25 stand-in: a real deployment decodes these from wire
// frames instead of generating them, but everything downstream of "a
// decoded OrderMsg with an ingest timestamp" is identical either way).
// ════════════════════════════════════════════════════════════════════════
void ingest_worker(
    int idx, const Config& cfg,
    BoundedRing<OrderMsg>& ring,
    std::atomic<std::uint64_t>& next_new_id,
    std::atomic<std::uint64_t>& busy_count,
    std::atomic<std::uint64_t>& deadline_expired_count,
    std::atomic<std::uint64_t>& ingest_peak_occupancy,
    std::atomic<std::uint64_t>& total_submitted) {
    std::mt19937 rng(1000u + static_cast<unsigned>(idx) * 7919u);
    std::uniform_int_distribution<std::uint32_t> price_dist(1, kPriceLevels);
    std::bernoulli_distribution side_dist(0.5);
    std::bernoulli_distribution cancel_dist(0.25);

    std::uint32_t my_tid = tid();
    std::uint64_t local_seq = 0;

    auto submit_phase = [&](std::uint64_t count, bool paced) {
        for (std::uint64_t i = 0; i < count; ++i, ++local_seq) {
            total_submitted.fetch_add(1, std::memory_order_relaxed);

            std::uint64_t ts = now_ns();
            bool pre_expired = (local_seq % kDeadlineExpireEvery) == 0;
            std::uint64_t deadline_ns = pre_expired ? ts - 1'000'000ULL : ts + 50'000'000ULL;
            if (ts > deadline_ns) {
                // The deadline (ch3) has already passed: reject before
                // this order ever costs the match stage a cycle.
                deadline_expired_count.fetch_add(1, std::memory_order_relaxed);
                continue;
            }

            OrderMsg msg;
            msg.ingest_ts_ns = ts;
            msg.producer_tid = my_tid;

            std::uint64_t known_ids = next_new_id.load(std::memory_order_acquire);
            if (known_ids > 0 && cancel_dist(rng)) {
                msg.kind = MsgKind::Cancel;
                std::uniform_int_distribution<std::uint64_t> id_dist(0, known_ids - 1);
                msg.target_id = id_dist(rng);
            } else {
                msg.kind = MsgKind::New;
                msg.order_id = next_new_id.fetch_add(1, std::memory_order_relaxed);
                msg.price = price_dist(rng);
                msg.side_buy = side_dist(rng);
            }

            std::uint64_t occ_before = ring.occupancy();
            msg.ring_occ_at_claim = static_cast<std::uint32_t>(occ_before);

            if (!ring.try_push(std::move(msg))) {
                // Ring full: shed load, don't retry and don't grow
                // anything -- exactly the back-pressure path Doc 21/33
                // describe.
                busy_count.fetch_add(1, std::memory_order_relaxed);
                continue;
            }
            update_peak(ingest_peak_occupancy, occ_before + 1);

            if (paced) {
                std::this_thread::sleep_for(std::chrono::microseconds(kSustainedInterSubmitSleepUs));
            }
        }
    };

    submit_phase(cfg.sustained_per_thread, /*paced=*/true);   // sustained, steady-state load
    submit_phase(cfg.burst_per_thread, /*paced=*/false);      // overload burst, no pacing
}

// ════════════════════════════════════════════════════════════════════════
// Match: exactly one thread, pinned, busy-polling the ingest ring.
// ════════════════════════════════════════════════════════════════════════
void match_worker(
    MatchEngine& engine,
    BoundedRing<OrderMsg>& ingest_ring,
    BoundedRing<PublishEvent>& publish_ring,
    std::atomic<bool>& producers_done,
    std::atomic<std::uint64_t>& events_produced,
    std::atomic<std::uint32_t>& match_tid_out) {
    std::uint32_t my_tid = tid();
    match_tid_out.store(my_tid, std::memory_order_relaxed);
    std::uint64_t seq_counter = 0;
    std::uint64_t since_sleep = 0;

    for (;;) {
        OrderMsg msg;
        if (!ingest_ring.try_pop(msg)) {
            if (producers_done.load(std::memory_order_acquire) && ingest_ring.empty()) {
                break;
            }
            continue; // busy-poll: this stage's latency budget can't absorb a futex round-trip
        }

        PublishEvent ev;
        ev.match_seq = seq_counter++;
        ev.kind = msg.kind;
        ev.ingest_ts_ns = msg.ingest_ts_ns;
        ev.producer_tid = msg.producer_tid;
        ev.match_tid = my_tid;
        ev.ring_occ_at_claim = msg.ring_occ_at_claim;

        if (msg.kind == MsgKind::New) {
            ev.order_id = msg.order_id;
            ev.price = msg.price;
            ev.side_buy = msg.side_buy;
            ev.outcome = engine.process_new(msg.order_id, msg.price, msg.side_buy);
        } else {
            ev.order_id = msg.target_id;
            ev.outcome = engine.process_cancel(msg.target_id);
        }

        // The publish ring is sized generously relative to the publish
        // pool's drain rate; a full publish ring here would be a sizing
        // bug, not a load-shedding opportunity (back-pressure is the
        // ingest ring's job per Doc 33), so the match thread retries
        // rather than drop an already-accepted order's outcome.
        while (!publish_ring.try_push(std::move(ev))) {
            std::this_thread::yield();
        }
        events_produced.fetch_add(1, std::memory_order_relaxed);

        if (++since_sleep >= kMatchSlowEveryN) {
            since_sleep = 0;
            std::this_thread::sleep_for(std::chrono::microseconds(kMatchSlowSleepUs));
        }
    }
}

// ════════════════════════════════════════════════════════════════════════
// Publish: a small pool draining the output ring (ch9's multi-consumer
// technique). Latency is captured here, at pop time, before any string
// formatting or I/O -- formatting/printing happens only after every
// thread has joined, so the measured path never includes this example's
// own stdout cost.
// ════════════════════════════════════════════════════════════════════════
struct PublishedLine {
    std::uint64_t match_seq;
    std::uint64_t latency_ns;
    std::string text;
};

void publish_worker(
    BoundedRing<PublishEvent>& ring,
    std::atomic<bool>& match_done,
    std::vector<PublishedLine>& out) {
    std::uint32_t my_tid = tid();
    for (;;) {
        PublishEvent ev;
        if (!ring.try_pop(ev)) {
            if (match_done.load(std::memory_order_acquire) && ring.empty()) {
                break;
            }
            std::this_thread::yield();
            continue;
        }
        std::uint64_t publish_ts = now_ns();
        std::uint64_t latency_ns = publish_ts >= ev.ingest_ts_ns ? publish_ts - ev.ingest_ts_ns : 0;

        std::string line = fmt::format(
            "EVENT match_seq={} kind={} outcome={} order_id={} price={} side={} "
            "producer_tid={} match_tid={} publish_tid={} ring_occ_at_claim={} "
            "ingest_ts_ns={} publish_ts_ns={} latency_ns={}",
            ev.match_seq, kind_str(ev.kind), outcome_str(ev.outcome), ev.order_id, ev.price,
            ev.side_buy ? "BUY" : "SELL", ev.producer_tid, ev.match_tid, my_tid,
            ev.ring_occ_at_claim, ev.ingest_ts_ns, publish_ts, latency_ns);

        out.push_back(PublishedLine{ev.match_seq, latency_ns, std::move(line)});
    }
}

} // namespace

int main(int argc, char** argv) {
    Config cfg;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto next_u64 = [&](std::uint64_t& dst) {
            if (i + 1 < argc) dst = std::strtoull(argv[++i], nullptr, 10);
        };
        if (arg == "--sustained") next_u64(cfg.sustained_per_thread);
        else if (arg == "--burst") next_u64(cfg.burst_per_thread);
        else if (arg == "--ingest-threads") next_u64(cfg.ingest_threads);
        else if (arg == "--publish-threads") next_u64(cfg.publish_threads);
        else if (arg == "--ingest-capacity") next_u64(cfg.ingest_capacity);
        else if (arg == "--publish-capacity") next_u64(cfg.publish_capacity);
        else if (arg == "-h" || arg == "--help") {
            fmt::print(
                "usage: capstone_pipeline [--sustained N] [--burst N] "
                "[--ingest-threads N] [--publish-threads N] "
                "[--ingest-capacity N] [--publish-capacity N]\n");
            return 0;
        }
    }

    if (cfg.ingest_threads < 1 || cfg.publish_threads < 1) {
        fmt::print(stderr, "error: --ingest-threads and --publish-threads must be >= 1\n");
        return 2;
    }
    if (!is_pow2(cfg.ingest_capacity) || !is_pow2(cfg.publish_capacity)) {
        fmt::print(stderr, "error: --ingest-capacity and --publish-capacity must be powers of two (>=2)\n");
        return 2;
    }

    // Upper bound on how many NEW orders this run could possibly generate
    // (every message could, in the worst case, roll NEW) -- sized once,
    // here, before any thread starts. This is the only heap allocation in
    // this program that touches order-sized memory; nothing on the match
    // thread's hot path allocates after this point.
    std::uint64_t max_orders = cfg.ingest_threads * (cfg.sustained_per_thread + cfg.burst_per_thread);
    MatchEngine engine(max_orders, kPriceLevels);

    BoundedRing<OrderMsg> ingest_ring(cfg.ingest_capacity);
    BoundedRing<PublishEvent> publish_ring(cfg.publish_capacity);

    std::atomic<std::uint64_t> next_new_id{0};
    std::atomic<std::uint64_t> busy_count{0};
    std::atomic<std::uint64_t> deadline_expired_count{0};
    std::atomic<std::uint64_t> ingest_peak_occupancy{0};
    std::atomic<std::uint64_t> total_submitted{0};
    std::atomic<std::uint64_t> events_produced{0};
    std::atomic<std::uint32_t> match_tid_out{0};
    std::atomic<bool> producers_done{false};
    std::atomic<bool> match_done{false};

    auto cpus = available_cpus();
    bool pin = cpus.size() >= 2;
    int match_cpu = pin ? cpus[0] : 0;

    auto start = std::chrono::steady_clock::now();

    // Start the publish consumers FIRST so the publish ring is always being
    // drained while the match stage pushes into it. The match stage does a
    // BLOCKING push (it must never drop an already-accepted order's outcome),
    // so with no consumer running yet it would spin forever on a full publish
    // ring while main blocked on match_thread.join() — a deadlock. The
    // consumers busy-poll an empty ring until match_done, so starting them
    // early is safe.
    std::vector<std::vector<PublishedLine>> publish_buffers(cfg.publish_threads);
    std::vector<std::thread> publish_threads;
    publish_threads.reserve(cfg.publish_threads);
    for (std::uint64_t t = 0; t < cfg.publish_threads; ++t) {
        publish_threads.emplace_back(publish_worker, std::ref(publish_ring),
                                      std::ref(match_done), std::ref(publish_buffers[t]));
        if (pin && cpus.size() > 1) {
            pin_to_cpu(publish_threads.back(), cpus[(t % (cpus.size() - 1)) + 1]);
        }
    }

    // Start match (drains the ingest ring, pushes outcomes to the publish ring).
    std::thread match_thread(match_worker, std::ref(engine), std::ref(ingest_ring),
                              std::ref(publish_ring), std::ref(producers_done),
                              std::ref(events_produced), std::ref(match_tid_out));
    if (pin) pin_to_cpu(match_thread, match_cpu);

    std::vector<std::thread> ingest_threads;
    ingest_threads.reserve(cfg.ingest_threads);
    for (std::uint64_t t = 0; t < cfg.ingest_threads; ++t) {
        ingest_threads.emplace_back(
            ingest_worker, static_cast<int>(t), std::cref(cfg), std::ref(ingest_ring),
            std::ref(next_new_id), std::ref(busy_count), std::ref(deadline_expired_count),
            std::ref(ingest_peak_occupancy), std::ref(total_submitted));
        if (pin && cpus.size() > 1) {
            pin_to_cpu(ingest_threads.back(), cpus[(t % (cpus.size() - 1)) + 1]);
        }
    }
    for (auto& t : ingest_threads) t.join();
    producers_done.store(true, std::memory_order_release);

    match_thread.join();
    match_done.store(true, std::memory_order_release);
    for (auto& t : publish_threads) t.join();

    auto end = std::chrono::steady_clock::now();
    double elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();

    // Merge, sort by match_seq (the field that carries real matching
    // order), then print -- all after every worker thread has joined, so
    // none of this I/O cost pollutes the latency figures below.
    std::vector<PublishedLine> all;
    all.reserve(events_produced.load());
    for (auto& buf : publish_buffers) {
        for (auto& line : buf) all.push_back(std::move(line));
    }
    std::sort(all.begin(), all.end(),
              [](const PublishedLine& a, const PublishedLine& b) { return a.match_seq < b.match_seq; });

    for (auto& line : all) {
        fmt::print("{}\n", line.text);
    }

    std::vector<std::uint64_t> latencies;
    latencies.reserve(all.size());
    for (auto& line : all) latencies.push_back(line.latency_ns);
    std::sort(latencies.begin(), latencies.end());

    auto percentile = [&](double p) -> std::uint64_t {
        if (latencies.empty()) return 0;
        std::size_t idx = static_cast<std::size_t>(p * static_cast<double>(latencies.size() - 1));
        return latencies[idx];
    };
    std::uint64_t p50 = percentile(0.50);
    std::uint64_t p99 = percentile(0.99);
    std::uint64_t p999 = percentile(0.999);

    std::uint64_t accepted_new = engine.filled_as_aggressor() + engine.rested();
    std::uint64_t accepted_cancel = engine.cancel_ok() + engine.cancel_miss();

    fmt::print(
        "SUMMARY pinned={} match_tid={} elapsed_ms={:.3f} "
        "ingest_threads={} publish_threads={} ingest_capacity={} publish_capacity={} "
        "total_submitted={} busy={} deadline_expired={} accepted={} "
        "accepted_new={} accepted_cancel={} "
        "filled_as_aggressor={} rested={} filled_later={} cancel_ok={} cancel_miss={} "
        "final_resting_scanned={} ingest_peak_occupancy={} events={} "
        "p50_latency_ns={} p99_latency_ns={} p999_latency_ns={}\n",
        pin ? "true" : "false", match_tid_out.load(std::memory_order_relaxed),
        elapsed_ms, cfg.ingest_threads, cfg.publish_threads, cfg.ingest_capacity, cfg.publish_capacity,
        total_submitted.load(), busy_count.load(), deadline_expired_count.load(),
        total_submitted.load() - busy_count.load() - deadline_expired_count.load(),
        accepted_new, accepted_cancel,
        engine.filled_as_aggressor(), engine.rested(), engine.filled_later(),
        engine.cancel_ok(), engine.cancel_miss(),
        engine.scan_final_resting(), ingest_peak_occupancy.load(), events_produced.load(),
        p50, p99, p999);

    return 0;
}
