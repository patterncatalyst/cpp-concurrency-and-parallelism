// concurrency/10-futures-promises-packaged-tasks — a packaged_task worker pool.
//
// A small fixed-size thread pool whose unit of work is std::packaged_task:
// submit() wraps any callable in a packaged_task<R()>, stores a type-erased
// std::function<void()> on the shared queue -- the task's own argument
// binding already done by the caller, exactly as the chapter describes --
// and hands back the task's own future immediately, without waiting for
// any task to run. packaged_task is itself move-only, so the std::function
// element wraps it in a shared_ptr purely to satisfy std::function's
// copy-constructible requirement; nothing here ever actually copies a task.
//
// Usage:
//   worker_pool --tasks N [--workers W] [--fail-at I]
//
// Submits N independent int-returning tasks through the pool (task i
// computes i*i). If --fail-at I is given (0 <= I < N), task I throws a
// std::runtime_error instead of returning, to make this chapter's
// exception-propagation claim observable: the exception set on that task's
// own packaged_task promise is rethrown, intact, at that SAME task's
// future::get() call -- and nowhere else. Every other task's future is
// completely unaffected.
//
// Prints one line per task in key=value form:
//   task=3 status=ok result=9
//   task=5 status=exception caught_at=get what="task 5 failed on purpose"
// and a final summary line:
//   RESULT: submitted=10 ok=9 exceptions=1 workers=4

#include <condition_variable>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>

#include <fmt/core.h>

namespace {

class ThreadPool {
public:
    explicit ThreadPool(std::size_t n) {
        workers_.reserve(n);
        for (std::size_t i = 0; i < n; ++i) {
            workers_.emplace_back([this] { run(); });
        }
    }

    ThreadPool(const ThreadPool&) = delete;
    ThreadPool& operator=(const ThreadPool&) = delete;

    ~ThreadPool() {
        {
            std::lock_guard<std::mutex> lk(mtx_);
            stop_ = true;
        }
        cv_.notify_all();
        for (auto& t : workers_) {
            t.join();
        }
    }

    // Wraps f in a std::packaged_task<R()>, queues a type-erased thunk that
    // invokes it, and returns the task's own future so the caller can
    // collect the result (or exception) later without blocking here.
    template <typename F>
    auto submit(F&& f) -> std::future<std::invoke_result_t<F>> {
        using R = std::invoke_result_t<F>;
        auto task = std::make_shared<std::packaged_task<R()>>(std::forward<F>(f));
        std::future<R> fut = task->get_future();
        {
            std::lock_guard<std::mutex> lk(mtx_);
            queue_.push_back([task] { (*task)(); });
        }
        cv_.notify_one();
        return fut;
    }

private:
    void run() {
        while (true) {
            std::function<void()> task;
            {
                std::unique_lock<std::mutex> lk(mtx_);
                cv_.wait(lk, [this] { return stop_ || !queue_.empty(); });
                if (stop_ && queue_.empty()) {
                    return;
                }
                task = std::move(queue_.front());
                queue_.pop_front();
            }
            // packaged_task's own call operator catches whatever the
            // wrapped callable throws and stores it in the shared state via
            // set_exception -- nothing here needs its own try/catch.
            task();
        }
    }

    std::mutex mtx_;
    std::condition_variable cv_;
    std::deque<std::function<void()>> queue_;
    std::vector<std::thread> workers_;
    bool stop_ = false;
};

} // namespace

int main(int argc, char** argv) {
    std::size_t n_tasks = 10;
    std::size_t n_workers = 4;
    long fail_at = -1;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--tasks" && i + 1 < argc) {
            n_tasks = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "--workers" && i + 1 < argc) {
            n_workers = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "--fail-at" && i + 1 < argc) {
            fail_at = std::strtol(argv[++i], nullptr, 10);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: worker_pool --tasks N [--workers W] [--fail-at I]\n");
            return 0;
        }
    }

    ThreadPool pool(n_workers);

    std::vector<std::future<int>> futures;
    futures.reserve(n_tasks);
    for (std::size_t i = 0; i < n_tasks; ++i) {
        bool should_fail = (fail_at >= 0 && static_cast<std::size_t>(fail_at) == i);
        futures.push_back(pool.submit([i, should_fail]() -> int {
            if (should_fail) {
                throw std::runtime_error(
                    "task " + std::to_string(i) + " failed on purpose");
            }
            return static_cast<int>(i * i);
        }));
    }

    std::size_t ok_count = 0;
    std::size_t exception_count = 0;
    for (std::size_t i = 0; i < futures.size(); ++i) {
        try {
            int result = futures[i].get();
            fmt::print("task={} status=ok result={}\n", i, result);
            ++ok_count;
        } catch (const std::exception& e) {
            fmt::print("task={} status=exception caught_at=get what=\"{}\"\n", i, e.what());
            ++exception_count;
        }
    }

    fmt::print("RESULT: submitted={} ok={} exceptions={} workers={}\n",
                n_tasks, ok_count, exception_count, n_workers);
    return 0;
}
