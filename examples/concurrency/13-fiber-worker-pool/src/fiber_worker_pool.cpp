// concurrency/13-fiber-worker-pool — a worker pool over a buffered
// channel, built two ways (fibers vs. threads), plus the guard-page
// stack-overflow demonstration.
//
// Chapter 13's central claim is that a fiber and an OS thread are the same
// shape of worker -- something that pulls work items off a shared queue
// and processes them -- at very different memory cost per unit. This demo
// builds that exact worker loop ONCE and runs it over two different units
// of concurrency selected by --mode:
//
//   --mode fiber    N boost::fibers::fiber workers under the default
//                   round_robin scheduler, all on this one OS thread.
//   --mode thread    N std::thread workers.
//
// Both modes pop from the same boost::fibers::buffered_channel<uint64_t>
// -- a channel is explicitly safe to use from a plain OS thread with no
// fiber scheduler running anything else on it (every thread has an
// implicit "main fiber" the channel's blocking operations suspend), which
// is what makes sharing one worker loop between the two modes possible.
//
// A third mode, `guard-page`, is unrelated to the pool and demonstrates
// Boost.Context's protected_fixedsize_stack turning a fiber stack overflow
// into an immediate, deterministic SIGSEGV instead of silent memory
// corruption. It runs in a forked child (so the demo process itself never
// crashes) under a hard alarm-based timeout (so the demo always
// terminates even if something about the guard page doesn't fire the way
// expected on a given kernel/arch).
//
// Usage:
//   fiber_worker_pool pool --mode fiber|thread [--workers N] [--items N]
//   fiber_worker_pool guard-page
//
// Prints one key=value line per invocation a shell or a Lua harness can
// parse without any special grammar, e.g.:
//
//   mode=fiber workers=8 items=100000 processed=100000 sum=333338333350000 \
//       elapsed_ms=12.345 rss_kb=9876
//
//   guard_page_signaled=true guard_page_signal=11 guard_page_timed_out=false

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include <csignal>
#include <sys/wait.h>
#include <unistd.h>

#include <boost/context/protected_fixedsize_stack.hpp>
#include <boost/fiber/buffered_channel.hpp>
#include <boost/fiber/fiber.hpp>

#include <fmt/core.h>

namespace {

using Channel = boost::fibers::buffered_channel<std::uint64_t>;

// Must be a power of two -- boost::fibers::buffered_channel's constructor
// throws fiber_error otherwise.
constexpr std::size_t kChannelCapacity = 1024;

// ════════════════════════════════════════════════════════════════════════
// The worker pool: one loop, shared by both the fiber mode and the thread
// mode. Each popped item contributes to two shared counters -- a count
// (exactly how many items this worker processed) and a sum of squares
// (so a correctness check can catch double-processing or dropped items,
// not just a wrong total count).
// ════════════════════════════════════════════════════════════════════════

void worker_loop(Channel& channel, std::atomic<std::uint64_t>& processed,
                  std::atomic<std::uint64_t>& sum_of_squares) {
    std::uint64_t item = 0;
    while (channel.pop(item) == boost::fibers::channel_op_status::success) {
        sum_of_squares.fetch_add(item * item, std::memory_order_relaxed);
        processed.fetch_add(1, std::memory_order_relaxed);
    }
}

// Peak resident set size for this process, in KiB, via /proc/self/status.
// Purely observational (see verify.lua: this is a soft/informational
// signal, never a hard pass/fail threshold) -- returns 0 if unavailable.
std::uint64_t read_peak_rss_kb() {
    std::FILE* f = std::fopen("/proc/self/status", "r");
    if (!f) {
        return 0;
    }
    unsigned long kb = 0;
    char line[256];
    while (std::fgets(line, sizeof(line), f) != nullptr) {
        if (std::sscanf(line, "VmHWM: %lu kB", &kb) == 1) {
            break;
        }
    }
    std::fclose(f);
    return static_cast<std::uint64_t>(kb);
}

int run_pool(const std::string& mode, int num_workers, std::uint64_t num_items) {
    if (mode != "fiber" && mode != "thread") {
        fmt::print(stderr, "error: --mode must be 'fiber' or 'thread' (got '{}')\n", mode);
        return 1;
    }

    Channel channel(kChannelCapacity);
    std::atomic<std::uint64_t> processed{0};
    std::atomic<std::uint64_t> sum_of_squares{0};

    const auto start = std::chrono::steady_clock::now();

    if (mode == "fiber") {
        std::vector<boost::fibers::fiber> workers;
        workers.reserve(static_cast<std::size_t>(num_workers));
        for (int i = 0; i < num_workers; ++i) {
            workers.emplace_back(worker_loop, std::ref(channel), std::ref(processed),
                                  std::ref(sum_of_squares));
        }
        for (std::uint64_t item = 1; item <= num_items; ++item) {
            channel.push(item);
        }
        channel.close();
        for (auto& f : workers) {
            f.join();
        }
    } else {
        std::vector<std::thread> workers;
        workers.reserve(static_cast<std::size_t>(num_workers));
        for (int i = 0; i < num_workers; ++i) {
            workers.emplace_back(worker_loop, std::ref(channel), std::ref(processed),
                                  std::ref(sum_of_squares));
        }
        for (std::uint64_t item = 1; item <= num_items; ++item) {
            channel.push(item);
        }
        channel.close();
        for (auto& t : workers) {
            t.join();
        }
    }

    const auto end = std::chrono::steady_clock::now();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(end - start).count();
    const std::uint64_t rss_kb = read_peak_rss_kb();

    fmt::print(
        "mode={} workers={} items={} processed={} sum={} elapsed_ms={:.3f} rss_kb={}\n",
        mode, num_workers, num_items, processed.load(), sum_of_squares.load(), elapsed_ms, rss_kb);

    return 0;
}

// ════════════════════════════════════════════════════════════════════════
// Guard-page demonstration. A deliberately recursive function with a
// sizable per-frame local blows through a small protected_fixedsize_stack
// fiber stack in a handful of calls -- bounded and fast, never anywhere
// near the depth== kMaxDepth safety bound below. protected_fixedsize_stack
// maps one extra PROT_NONE guard page beyond the requested stack size, so
// the overrun faults immediately (SIGSEGV) instead of silently corrupting
// whatever memory happens to sit past the end of the mapping.
//
// This runs in a forked child so the crash never takes down the demo
// process itself, under a parent-side alarm so the demo always terminates
// even if, on some kernel/arch, the overflow doesn't fault the way
// expected.
// ════════════════════════════════════════════════════════════════════════

constexpr std::size_t kGuardStackBytes = 65536; // fiber stack, excluding the guard page itself
constexpr std::size_t kFrameLocalBytes = 4096;   // per-recursion local; overflows the stack in ~16 calls
constexpr int kMaxRecursionDepth = 1'000'000;    // unreachable safety bound, not the expected exit path

#if defined(__GNUC__) || defined(__clang__)
#define FIBER_DEMO_NOINLINE __attribute__((noinline))
#else
#define FIBER_DEMO_NOINLINE
#endif

// volatile (both the array and the post-call write) keeps the optimizer
// from eliminating `padding` as dead AND, just as important, from
// tail-call-optimizing this into a loop that reuses one stack frame: the
// recursive call is otherwise in tail position, and a TCO'd version would
// never grow the stack at all, silently defeating the whole demonstration.
// The volatile write to padding[0] *after* the recursive call returns
// gives the optimizer a real reason the current frame must stay live
// until that call comes back, which rules out the tail-call rewrite.
FIBER_DEMO_NOINLINE void recurse_until_guard_page(int depth) {
    volatile unsigned char padding[kFrameLocalBytes];
    padding[0] = static_cast<unsigned char>(depth & 0xFF);
    padding[kFrameLocalBytes - 1] = padding[0];
    if (depth < kMaxRecursionDepth) {
        recurse_until_guard_page(depth + 1);
        padding[0] = static_cast<unsigned char>(padding[0] + 1); // defeats TCO -- see above
    }
}

void guard_page_fiber_body() {
    recurse_until_guard_page(0);
    // Unreachable in practice: the recursion above overflows the 64 KiB
    // stack (at ~4 KiB/frame) long before kMaxRecursionDepth.
}

[[noreturn]] void run_guard_page_child() {
    // Make sure nothing upstream of this process has redirected SIGSEGV
    // away from its default (terminating) disposition.
    std::signal(SIGSEGV, SIG_DFL);

    boost::context::protected_fixedsize_stack alloc(kGuardStackBytes);
    boost::fibers::fiber f(std::allocator_arg, alloc, guard_page_fiber_body);
    f.join();

    // Reached only if the stack somehow absorbed the full recursion depth
    // without faulting -- not the expected outcome, but still a clean,
    // bounded exit rather than a hang. _exit() (POSIX, <unistd.h>) rather
    // than std::exit(): skip atexit handlers/stdio flushing, matching
    // exactly what the fork()+exec-less child needs.
    _exit(0);
}

int run_guard_page_demo() {
    // A no-op SIGALRM handler: its only job is to interrupt the blocking
    // waitpid() below with EINTR if the child somehow never terminates,
    // rather than letting the default SIGALRM disposition kill this
    // (parent) process too.
    std::signal(SIGALRM, [](int) {});

    const pid_t pid = fork();
    if (pid < 0) {
        fmt::print(stderr, "error: fork() failed\n");
        return 1;
    }
    if (pid == 0) {
        run_guard_page_child(); // never returns
    }

    alarm(5);
    int status = 0;
    const pid_t waited = waitpid(pid, &status, 0);
    const bool timed_out = (waited < 0);
    alarm(0);

    bool signaled = false;
    int sig = 0;
    if (timed_out) {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
    } else {
        signaled = WIFSIGNALED(status) != 0;
        sig = signaled ? WTERMSIG(status) : 0;
    }

    fmt::print(
        "guard_page_signaled={} guard_page_signal={} guard_page_timed_out={}\n",
        signaled ? "true" : "false", sig, timed_out ? "true" : "false");

    return 0;
}

} // namespace

int main(int argc, char** argv) {
    const std::string action = argc > 1 ? argv[1] : "pool";

    if (action == "guard-page") {
        return run_guard_page_demo();
    }

    if (action != "pool") {
        fmt::print(stderr, "usage: fiber_worker_pool pool --mode fiber|thread [--workers N] [--items N]\n");
        fmt::print(stderr, "       fiber_worker_pool guard-page\n");
        return 1;
    }

    std::string mode = "fiber";
    int workers = 8;
    std::uint64_t items = 100'000;

    for (int i = 2; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--mode" && i + 1 < argc) {
            mode = argv[++i];
        } else if (arg == "--workers" && i + 1 < argc) {
            workers = std::atoi(argv[++i]);
        } else if (arg == "--items" && i + 1 < argc) {
            items = std::strtoull(argv[++i], nullptr, 10);
        }
    }

    return run_pool(mode, workers, items);
}
