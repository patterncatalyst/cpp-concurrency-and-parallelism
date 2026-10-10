// concurrency/10-futures-promises-packaged-tasks — launch-policy comparison.
//
// std::async's launch policy decides whether a callable actually runs
// concurrently (std::launch::async: new thread, starts immediately) or not
// at all until someone asks for the result (std::launch::deferred: runs
// synchronously, on the CALLER's own thread, inside the future's get()
// call). The default policy (async | deferred) lets the implementation
// pick either, silently, with no diagnostic either way.
//
// This program submits the same N trivial callables under all three
// policies, in three separate rounds, and has each callable report the
// thread id it actually ran on. Comparing that id against the submitting
// thread's own id turns the chapter's prose claim into something a Lua
// harness can check mechanically:
//
//   * std::launch::async  -> exec_tid must differ from submitter_tid, for
//                             every task, every time.
//   * std::launch::deferred -> exec_tid must EQUAL submitter_tid, for
//                               every task, every time (deferred work runs
//                               inside the get() call on the thread that
//                               calls it).
//   * default policy -> may go either way per call; this program reports
//     what it observed without asserting a direction, because an
//     implementation is conforming either way.
//
// Each task also does a small, fixed amount of busy work before reporting,
// and records start/end timestamps relative to the round's first
// submission, so that when every future is collected only after the whole
// round has been submitted, an async round's tasks can show genuine
// wall-clock overlap (visible by comparing start_ns/end_ns across tasks)
// while a deferred round's tasks execute strictly one at a time, each
// bounded by the previous task's own get() call.
//
// Usage:
//   launch_policy [-n TASK_COUNT] [-w WORK_ITERS]
//
// Prints one line per task per round in key=value form:
//   policy=async    task=0 submitter_tid=140... exec_tid=140... same_thread=false start_ns=12 end_ns=5102
//   policy=deferred task=0 submitter_tid=140... exec_tid=140... same_thread=true  start_ns=0  end_ns=4998
// and one summary line per round:
//   RESULT: policy=async    n=5 all_distinct_from_submitter=true
//   RESULT: policy=deferred n=5 all_same_as_submitter=true
//   RESULT: policy=default  n=5 distinct_count=5 same_count=0

#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <future>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <fmt/core.h>

namespace {

using Clock = std::chrono::steady_clock;

std::string tid_to_string(std::thread::id id) {
    std::ostringstream oss;
    oss << id;
    return oss.str();
}

struct TaskRecord {
    std::string exec_tid;
    std::int64_t start_ns;
    std::int64_t end_ns;
};

// The fixed, trivial workload every task performs before reporting --
// just enough to make a visible, non-instantaneous window on the
// start_ns/end_ns timeline, so overlap (or its absence) is observable.
auto make_task(Clock::time_point t0, std::uint64_t work_iters) {
    return [t0, work_iters]() -> TaskRecord {
        auto start = std::chrono::duration_cast<std::chrono::nanoseconds>(
            Clock::now() - t0).count();
        volatile std::uint64_t sink = 0;
        for (std::uint64_t i = 0; i < work_iters; ++i) {
            sink += i;
        }
        (void)sink;
        auto end = std::chrono::duration_cast<std::chrono::nanoseconds>(
            Clock::now() - t0).count();
        return TaskRecord{tid_to_string(std::this_thread::get_id()), start, end};
    };
}

// use_policy=false submits via the default (async|deferred) policy, by
// calling the single-argument std::async overload rather than passing an
// explicit std::launch value.
void run_round(const std::string& policy_name, std::launch policy, bool use_policy,
               std::size_t n, std::uint64_t work_iters) {
    std::string submitter_tid = tid_to_string(std::this_thread::get_id());
    auto t0 = Clock::now();

    std::vector<std::future<TaskRecord>> futures;
    futures.reserve(n);
    for (std::size_t i = 0; i < n; ++i) {
        auto task = make_task(t0, work_iters);
        if (use_policy) {
            futures.push_back(std::async(policy, task));
        } else {
            futures.push_back(std::async(task));
        }
    }

    std::size_t distinct_count = 0;
    std::size_t same_count = 0;
    for (std::size_t i = 0; i < n; ++i) {
        TaskRecord rec = futures[i].get();
        bool same_thread = (rec.exec_tid == submitter_tid);
        if (same_thread) {
            ++same_count;
        } else {
            ++distinct_count;
        }
        fmt::print(
            "policy={} task={} submitter_tid={} exec_tid={} same_thread={} start_ns={} end_ns={}\n",
            policy_name, i, submitter_tid, rec.exec_tid, same_thread ? "true" : "false",
            rec.start_ns, rec.end_ns);
    }

    if (policy_name == "async") {
        fmt::print("RESULT: policy=async n={} all_distinct_from_submitter={}\n",
                    n, distinct_count == n ? "true" : "false");
    } else if (policy_name == "deferred") {
        fmt::print("RESULT: policy=deferred n={} all_same_as_submitter={}\n",
                    n, same_count == n ? "true" : "false");
    } else {
        fmt::print("RESULT: policy=default n={} distinct_count={} same_count={}\n",
                    n, distinct_count, same_count);
    }
}

} // namespace

int main(int argc, char** argv) {
    std::size_t n = 5;
    std::uint64_t work_iters = 2'000'000ULL;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "-n" && i + 1 < argc) {
            n = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-w" && i + 1 < argc) {
            work_iters = std::strtoull(argv[++i], nullptr, 10);
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: launch_policy [-n TASK_COUNT] [-w WORK_ITERS]\n");
            return 0;
        }
    }

    run_round("async", std::launch::async, /*use_policy=*/true, n, work_iters);
    run_round("deferred", std::launch::deferred, /*use_policy=*/true, n, work_iters);
    run_round("default", std::launch::async, /*use_policy=*/false, n, work_iters);

    return 0;
}
