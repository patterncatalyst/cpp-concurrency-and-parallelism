// concurrency/03-timers-and-deadlines — deadline_chain.
//
// A runnable version of Doc 3's "Propagating Deadlines Across Calls"
// section: the same four-function chain from the chapter's inline snippet
// (handle_request -> checkout_and_execute -> execute_query ->
// run_with_deadline), each hop sharing ONE steady_clock::time_point deadline
// computed once at the top, rather than re-deriving its own timeout.
//
// Two things this binary can do:
//
//   mode=chain (default) -- run the full three-hop chain once, with an
//   optional artificial delay injectable at any ONE named hop. The delay is
//   itself deadline-aware (it sleeps until min(now + delay, deadline), never
//   past the shared deadline) because that is exactly what a correct
//   implementation of "work" bounded by a deadline does -- a hop cannot
//   un-sleep past a deadline it already blew through, but it CAN refuse to
//   sleep past one it hasn't reached yet. This is what lets the demo prove
//   "the outer caller's total wall-clock budget is never exceeded regardless
//   of which hop is slow": no single hop can itself run past the deadline,
//   and every hop checks the deadline before doing any work at all.
//
//   mode=direct --direct <hop> -- call ONE hop function directly with a
//   deadline already 50ms in the past, bypassing the chain entirely. Proves
//   assertion (2) from the chapter's EXAMPLE SPEC: a hop that starts after
//   the deadline has already passed returns DeadlineExceeded WITHOUT doing
//   any work -- tracked here as a `work_performed` flag set only inside the
//   section of each hop that runs after its own deadline pre-check passes.
//
// Usage:
//   deadline_chain --budget-ms N [--delay-hop checkout|query|run|none] [--delay-ms M]
//   deadline_chain --direct checkout|query|run
//
// Output is one key=value line per run, trivial to parse:
//   mode=chain budget_ms=150 delay_hop=query delay_ms=2000 result=DeadlineExceeded elapsed_ms=150.412 trace=checkout_and_execute:ok,execute_query:deadline_exceeded_after_delay
//   mode=direct hop=run result=DeadlineExceeded work_performed=0 elapsed_ms=0.021

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;
using Deadline = Clock::time_point;

enum class Result { Ok, DeadlineExceeded };

const char* to_string(Result r) {
    return r == Result::Ok ? "Ok" : "DeadlineExceeded";
}

struct HopConfig {
    // Which single hop gets the artificial delay: "checkout", "query",
    // "run", or "none". All other hops ignore `delay`.
    std::string delay_hop = "none";
    std::chrono::milliseconds delay{0};
};

// Sleep for at most `requested`, but never past `deadline` -- the
// deadline-aware stand-in for "doing the hop's work" in this demo. A hop
// that oversleeps its own deadline would defeat the entire point of the
// chapter; clamping here is what makes "the total budget is never exceeded"
// true by construction rather than by luck.
void bounded_sleep(std::chrono::milliseconds requested, Deadline deadline) {
    if (requested.count() <= 0) return;
    Deadline wake = std::min(Clock::now() + requested, deadline);
    std::this_thread::sleep_until(wake);
}

// run_with_deadline — innermost hop, matches the chapter's snippet exactly
// in shape: check the deadline before doing anything, then do the work.
Result run_with_deadline(Deadline deadline, const HopConfig& cfg,
                          std::vector<std::string>& trace,
                          std::atomic<int>& work_performed) {
    if (Clock::now() >= deadline) {
        trace.push_back("run_with_deadline:deadline_exceeded_before_work");
        return Result::DeadlineExceeded;
    }
    work_performed.store(1, std::memory_order_relaxed);
    if (cfg.delay_hop == "run") {
        bounded_sleep(cfg.delay, deadline);
    }
    if (Clock::now() >= deadline) {
        trace.push_back("run_with_deadline:deadline_exceeded_after_delay");
        return Result::DeadlineExceeded;
    }
    trace.push_back("run_with_deadline:ok");
    return Result::Ok;
}

// execute_query — same deadline, not a fresh timeout; calls run_with_deadline
// with the identical time_point it was handed.
Result execute_query(Deadline deadline, const HopConfig& cfg,
                      std::vector<std::string>& trace,
                      std::atomic<int>& work_performed) {
    if (Clock::now() >= deadline) {
        trace.push_back("execute_query:deadline_exceeded_before_work");
        return Result::DeadlineExceeded;
    }
    work_performed.store(1, std::memory_order_relaxed);
    if (cfg.delay_hop == "query") {
        bounded_sleep(cfg.delay, deadline);
    }
    if (Clock::now() >= deadline) {
        trace.push_back("execute_query:deadline_exceeded_after_delay");
        return Result::DeadlineExceeded;
    }
    return run_with_deadline(deadline, cfg, trace, work_performed);
}

// checkout_and_execute — outermost hop below handle_request.
Result checkout_and_execute(Deadline deadline, const HopConfig& cfg,
                             std::vector<std::string>& trace,
                             std::atomic<int>& work_performed) {
    if (Clock::now() >= deadline) {
        trace.push_back("checkout_and_execute:deadline_exceeded_before_work");
        return Result::DeadlineExceeded;
    }
    work_performed.store(1, std::memory_order_relaxed);
    if (cfg.delay_hop == "checkout") {
        bounded_sleep(cfg.delay, deadline);
    }
    if (Clock::now() >= deadline) {
        trace.push_back("checkout_and_execute:deadline_exceeded_after_delay");
        return Result::DeadlineExceeded;
    }
    return execute_query(deadline, cfg, trace, work_performed);
}

// handle_request — computes the ONE deadline, once, at the top of the chain.
Result handle_request(std::chrono::milliseconds budget, const HopConfig& cfg,
                       std::vector<std::string>& trace,
                       std::atomic<int>& work_performed) {
    const Deadline deadline = Clock::now() + budget;
    return checkout_and_execute(deadline, cfg, trace, work_performed);
}

std::string join(const std::vector<std::string>& parts) {
    std::string out;
    for (std::size_t i = 0; i < parts.size(); ++i) {
        if (i) out += ',';
        out += parts[i];
    }
    return out;
}

void print_usage() {
    std::printf(
        "usage: deadline_chain --budget-ms N [--delay-hop checkout|query|run|none] [--delay-ms M]\n"
        "       deadline_chain --direct checkout|query|run\n");
}

} // namespace

int main(int argc, char** argv) {
    long budget_ms = 150;
    long delay_ms = 0;
    std::string delay_hop = "none";
    std::string direct_hop;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--budget-ms" && i + 1 < argc) {
            budget_ms = std::strtol(argv[++i], nullptr, 10);
        } else if (arg == "--delay-ms" && i + 1 < argc) {
            delay_ms = std::strtol(argv[++i], nullptr, 10);
        } else if (arg == "--delay-hop" && i + 1 < argc) {
            delay_hop = argv[++i];
        } else if (arg == "--direct" && i + 1 < argc) {
            direct_hop = argv[++i];
        } else if (arg == "-h" || arg == "--help") {
            print_usage();
            return 0;
        } else {
            std::fprintf(stderr, "unrecognized argument: %s\n", arg.c_str());
            print_usage();
            return 2;
        }
    }

    if (!direct_hop.empty()) {
        if (direct_hop != "checkout" && direct_hop != "query" && direct_hop != "run") {
            std::fprintf(stderr, "--direct must be one of checkout|query|run\n");
            return 2;
        }
        // A deadline already 50ms in the past: the hop must refuse to do any
        // work at all, immediately, with no sleep and no side effect.
        const Deadline expired_deadline = Clock::now() - std::chrono::milliseconds(50);
        HopConfig cfg; // delay_hop="none": irrelevant, the pre-check must fire first
        std::vector<std::string> trace;
        std::atomic<int> work_performed{0};

        const auto start = Clock::now();
        Result result;
        if (direct_hop == "checkout") {
            result = checkout_and_execute(expired_deadline, cfg, trace, work_performed);
        } else if (direct_hop == "query") {
            result = execute_query(expired_deadline, cfg, trace, work_performed);
        } else {
            result = run_with_deadline(expired_deadline, cfg, trace, work_performed);
        }
        const double elapsed_ms =
            std::chrono::duration<double, std::milli>(Clock::now() - start).count();

        std::printf("mode=direct hop=%s result=%s work_performed=%d elapsed_ms=%.3f\n",
                    direct_hop.c_str(), to_string(result),
                    work_performed.load(std::memory_order_relaxed), elapsed_ms);
        return 0;
    }

    if (delay_hop != "none" && delay_hop != "checkout" && delay_hop != "query" &&
        delay_hop != "run") {
        std::fprintf(stderr, "--delay-hop must be one of checkout|query|run|none\n");
        return 2;
    }

    HopConfig cfg;
    cfg.delay_hop = delay_hop;
    cfg.delay = std::chrono::milliseconds(delay_ms);

    std::vector<std::string> trace;
    std::atomic<int> work_performed{0};

    const auto start = Clock::now();
    const Result result =
        handle_request(std::chrono::milliseconds(budget_ms), cfg, trace, work_performed);
    const double elapsed_ms =
        std::chrono::duration<double, std::milli>(Clock::now() - start).count();

    std::printf("mode=chain budget_ms=%ld delay_hop=%s delay_ms=%ld result=%s elapsed_ms=%.3f trace=%s\n",
                budget_ms, delay_hop.c_str(), delay_ms, to_string(result), elapsed_ms,
                join(trace).c_str());
    return 0;
}
