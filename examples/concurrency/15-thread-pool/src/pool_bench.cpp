// concurrency/15-thread-pool — single shared queue vs. work-stealing deques.
//
// Two pool designs, same CPU-bound task mix, same correctness contract
// (every submitted task runs exactly once):
//
//   SingleQueuePool    one mutex+condition_variable-guarded deque every
//                      worker pops from. Simple, and the queue's single
//                      lock becomes a serialization point as worker count
//                      grows -- the chapter's central throughput claim.
//   WorkStealingPool   each worker owns a mutex-guarded deque of its own.
//                      The owner pushes/pops its own queue's bottom (LIFO:
//                      the most recently pushed task is the most cache-hot
//                      one); an idle worker steals from a busy neighbor's
//                      top (FIFO: the oldest queued task), so owner and
//                      thief only ever contend when a deque holds exactly
//                      one item. This is a teaching-grade mutex-per-deque
//                      implementation, not the lock-free Chase-Lev deque
//                      production work-stealing pools use -- the chapter
//                      is explicit that even a naive version keeps
//                      contention rare, because steals happen only when a
//                      worker is starved, not on every dispatch.
//
// Usage:
//   pool_bench --kind single|stealing [--workers W] [--tasks N] [--work-iters I]
//
// Submits N copies of the same fixed CPU-bound task (a tight sum-of-squares
// loop of I iterations) and reports aggregate throughput plus the average
// time a task spent queued before a worker picked it up:
//
//   kind=single workers=8 tasks=6000 work_iters=4000 completed=6000 elapsed_ms=142.318 throughput_tasks_per_sec=42167.9 avg_queue_wait_us=18.432

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <fmt/core.h>

namespace {

using Clock = std::chrono::steady_clock;

// The fixed CPU-bound task mix every pool kind runs identically, so any
// throughput difference between the two pool designs comes from the queue,
// not from the work itself.
std::uint64_t cpu_work(std::uint64_t iters) {
    std::uint64_t acc = 0;
    for (std::uint64_t i = 0; i < iters; ++i) {
        acc += i * i;
    }
    return acc;
}

struct Task {
    Clock::time_point enqueued_at;
    std::function<void()> fn;
};

// ───────────────────────────── single shared queue ─────────────────────

class SingleQueuePool {
public:
    explicit SingleQueuePool(unsigned n) {
        workers_.reserve(n);
        for (unsigned i = 0; i < n; ++i) {
            workers_.emplace_back([this] { run(); });
        }
    }

    SingleQueuePool(const SingleQueuePool&) = delete;
    SingleQueuePool& operator=(const SingleQueuePool&) = delete;

    ~SingleQueuePool() {
        {
            std::lock_guard<std::mutex> lk(mtx_);
            stop_ = true;
        }
        cv_.notify_all();
        for (auto& t : workers_) {
            t.join();
        }
    }

    void submit(std::function<void()> fn) {
        {
            std::lock_guard<std::mutex> lk(mtx_);
            queue_.push_back(Task{Clock::now(), std::move(fn)});
        }
        cv_.notify_one();
    }

    std::uint64_t completed() const {
        return tasks_completed_.load(std::memory_order_relaxed);
    }

    double avg_wait_ns() const {
        auto count = wait_ns_count_.load(std::memory_order_relaxed);
        if (count == 0) {
            return 0.0;
        }
        return static_cast<double>(wait_ns_sum_.load(std::memory_order_relaxed)) /
               static_cast<double>(count);
    }

private:
    void run() {
        while (true) {
            Task task;
            {
                std::unique_lock<std::mutex> lk(mtx_);
                cv_.wait(lk, [this] { return stop_ || !queue_.empty(); });
                if (stop_ && queue_.empty()) {
                    return;
                }
                task = std::move(queue_.front());
                queue_.pop_front();
            }
            record_wait(task.enqueued_at);
            task.fn();
            tasks_completed_.fetch_add(1, std::memory_order_relaxed);
        }
    }

    void record_wait(Clock::time_point enqueued_at) {
        auto wait_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
            Clock::now() - enqueued_at).count();
        wait_ns_sum_.fetch_add(static_cast<std::uint64_t>(wait_ns), std::memory_order_relaxed);
        wait_ns_count_.fetch_add(1, std::memory_order_relaxed);
    }

    std::mutex mtx_;
    std::condition_variable cv_;
    std::deque<Task> queue_;
    bool stop_ = false;
    std::vector<std::thread> workers_;
    std::atomic<std::uint64_t> tasks_completed_{0};
    std::atomic<std::uint64_t> wait_ns_sum_{0};
    std::atomic<std::uint64_t> wait_ns_count_{0};
};

// ───────────────────────────── work-stealing deques ─────────────────────

class WorkStealingPool {
public:
    explicit WorkStealingPool(unsigned n) : n_(n), deques_(n) {
        workers_.reserve(n);
        for (unsigned i = 0; i < n; ++i) {
            workers_.emplace_back([this, i] { run(i); });
        }
    }

    WorkStealingPool(const WorkStealingPool&) = delete;
    WorkStealingPool& operator=(const WorkStealingPool&) = delete;

    ~WorkStealingPool() {
        stop_.store(true, std::memory_order_release);
        for (auto& t : workers_) {
            t.join();
        }
    }

    // Round-robins new work across every worker's own deque (pushed onto
    // the "bottom", the owner's push/pop end). Callable from any thread.
    void submit(std::function<void()> fn) {
        unsigned idx = next_.fetch_add(1, std::memory_order_relaxed) % n_;
        auto& d = deques_[idx];
        std::lock_guard<std::mutex> lk(d.mtx);
        d.items.push_front(Task{Clock::now(), std::move(fn)});
    }

    std::uint64_t completed() const {
        return tasks_completed_.load(std::memory_order_relaxed);
    }

    double avg_wait_ns() const {
        auto count = wait_ns_count_.load(std::memory_order_relaxed);
        if (count == 0) {
            return 0.0;
        }
        return static_cast<double>(wait_ns_sum_.load(std::memory_order_relaxed)) /
               static_cast<double>(count);
    }

private:
    struct Deque {
        std::mutex mtx;
        std::deque<Task> items; // front = bottom (owner LIFO), back = top (thief FIFO)
    };

    void run(unsigned id) {
        while (true) {
            Task task;
            bool got = try_pop_own(id, task);
            if (!got) {
                got = try_steal(id, task);
            }
            if (!got) {
                if (stop_.load(std::memory_order_acquire) && all_empty()) {
                    return;
                }
                std::this_thread::yield();
                continue;
            }
            record_wait(task.enqueued_at);
            task.fn();
            tasks_completed_.fetch_add(1, std::memory_order_relaxed);
        }
    }

    bool try_pop_own(unsigned id, Task& out) {
        auto& d = deques_[id];
        std::lock_guard<std::mutex> lk(d.mtx);
        if (d.items.empty()) {
            return false;
        }
        out = std::move(d.items.front()); // bottom: most recently pushed
        d.items.pop_front();
        return true;
    }

    bool try_steal(unsigned id, Task& out) {
        for (unsigned offset = 1; offset < n_; ++offset) {
            unsigned victim = (id + offset) % n_;
            auto& d = deques_[victim];
            std::lock_guard<std::mutex> lk(d.mtx);
            if (!d.items.empty()) {
                out = std::move(d.items.back()); // top: oldest queued
                d.items.pop_back();
                return true;
            }
        }
        return false;
    }

    bool all_empty() {
        for (auto& d : deques_) {
            std::lock_guard<std::mutex> lk(d.mtx);
            if (!d.items.empty()) {
                return false;
            }
        }
        return true;
    }

    void record_wait(Clock::time_point enqueued_at) {
        auto wait_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
            Clock::now() - enqueued_at).count();
        wait_ns_sum_.fetch_add(static_cast<std::uint64_t>(wait_ns), std::memory_order_relaxed);
        wait_ns_count_.fetch_add(1, std::memory_order_relaxed);
    }

    unsigned n_;
    std::vector<Deque> deques_;
    std::atomic<unsigned> next_{0};
    std::atomic<bool> stop_{false};
    std::vector<std::thread> workers_;
    std::atomic<std::uint64_t> tasks_completed_{0};
    std::atomic<std::uint64_t> wait_ns_sum_{0};
    std::atomic<std::uint64_t> wait_ns_count_{0};
};

template <typename Pool>
void run_bench(const std::string& kind, unsigned n_workers, std::uint64_t n_tasks,
               std::uint64_t work_iters) {
    auto work_fn = [work_iters] {
        volatile std::uint64_t sink = cpu_work(work_iters);
        (void)sink;
    };

    auto t0 = Clock::now();
    Pool pool(n_workers);
    for (std::uint64_t i = 0; i < n_tasks; ++i) {
        pool.submit(work_fn);
    }
    while (pool.completed() < n_tasks) {
        std::this_thread::yield();
    }
    auto t1 = Clock::now();
    double avg_wait_ns = pool.avg_wait_ns();
    // Destructor (joining every worker) runs here, after every task has
    // already completed and every deque is already empty -- shutdown
    // itself is excluded from the timed window.

    double elapsed_s = std::chrono::duration<double>(t1 - t0).count();
    double throughput = elapsed_s > 0.0 ? static_cast<double>(n_tasks) / elapsed_s : 0.0;

    fmt::print(
        "kind={} workers={} tasks={} work_iters={} completed={} elapsed_ms={:.3f} "
        "throughput_tasks_per_sec={:.1f} avg_queue_wait_us={:.3f}\n",
        kind, n_workers, n_tasks, work_iters, n_tasks, elapsed_s * 1000.0, throughput,
        avg_wait_ns / 1000.0);
}

} // namespace

int main(int argc, char** argv) {
    std::string kind = "single";
    unsigned n_workers = std::thread::hardware_concurrency();
    if (n_workers == 0) {
        n_workers = 4;
    }
    std::uint64_t n_tasks = 6000;
    std::uint64_t work_iters = 4000;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--kind" && i + 1 < argc) {
            kind = argv[++i];
        } else if (arg == "--workers" && i + 1 < argc) {
            n_workers = static_cast<unsigned>(std::strtoul(argv[++i], nullptr, 10));
        } else if (arg == "--tasks" && i + 1 < argc) {
            n_tasks = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "--work-iters" && i + 1 < argc) {
            work_iters = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print(
                "usage: pool_bench --kind single|stealing [--workers W] "
                "[--tasks N] [--work-iters I]\n");
            return 0;
        }
    }

    if (n_workers == 0) {
        n_workers = 1;
    }

    if (kind == "single") {
        run_bench<SingleQueuePool>(kind, n_workers, n_tasks, work_iters);
    } else if (kind == "stealing") {
        run_bench<WorkStealingPool>(kind, n_workers, n_tasks, work_iters);
    } else {
        fmt::print(stderr, "error: --kind must be 'single' or 'stealing', got '{}'\n", kind);
        return 1;
    }

    return 0;
}
