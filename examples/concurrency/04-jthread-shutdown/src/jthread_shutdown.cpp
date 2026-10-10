// concurrency/04-jthread-shutdown — jthread_shutdown.
//
// A runnable version of Doc 4's "Running in a container" closing section:
// "A process whose signal handler calls request_stop() on every outstanding
// jthread and then returns lets each worker's stop_token loop notice on its
// next poll and exit cleanly, and lets main()'s jthread destructors join
// them all before the process exits on its own -- well inside the grace
// period, with no forced kill and no resources abandoned mid-write."
//
// Starts N jthread workers, each polling a stop_token in a tight loop.
// SIGTERM is this program's real termination signal (the one Kubernetes and
// `docker stop` both send before a SIGKILL grace period elapses). On
// receipt, every worker is asked to stop and every worker is joined before
// main() returns 0.
//
// One deliberate deviation from the chapter's literal phrasing, worth
// stating plainly: the SIGTERM handler here does NOT call request_stop()
// itself. std::stop_source::request_stop() is not guaranteed
// async-signal-safe -- it may touch an internal mutex and invoke any
// registered stop_callbacks, neither of which is safe to do from inside a
// signal handler. The handler instead does the one thing that IS safe
// there: a relaxed store to a lock-free std::atomic<bool>. The main thread
// polls that flag and performs every request_stop()/join() call itself,
// which preserves the chapter's actual claim (a real termination signal
// drives a clean, destructor/join-backed shutdown) without smuggling
// undefined behavior into the one code path a crash-safety chapter can
// least afford it in.
//
// Usage: jthread_shutdown [N_WORKERS]   (default 4)
//
// Log lines (stdout, flushed immediately so a container's log capture sees
// them even if the process is killed moments later):
//   main: started N worker(s)
//   main: SIGTERM received, calling request_stop() on N worker(s)
//   worker <id>: stop observed, exiting      (once per worker)
//   main: shutdown complete, all workers joined

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <stop_token>
#include <thread>
#include <vector>

namespace {

// Lock-free, async-signal-safe: the only thing the SIGTERM handler touches.
std::atomic<bool> g_sigterm_received{false};

extern "C" void handle_sigterm(int /*signum*/) {
    g_sigterm_received.store(true, std::memory_order_relaxed);
}

void worker(std::stop_token tok, int id) {
    while (!tok.stop_requested()) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    std::printf("worker %d: stop observed, exiting\n", id);
    std::fflush(stdout);
}

} // namespace

int main(int argc, char** argv) {
    int n_workers = 4;
    if (argc > 1) {
        n_workers = std::atoi(argv[1]);
    }
    if (n_workers < 1) {
        n_workers = 1;
    }

    // SIG_ERR would mean the handler couldn't be installed at all -- treat
    // that as fatal rather than silently running with the default
    // terminate-the-process SIGTERM disposition, which would defeat the
    // entire point of this demo.
    if (std::signal(SIGTERM, handle_sigterm) == SIG_ERR) {
        std::fprintf(stderr, "failed to install SIGTERM handler\n");
        return 1;
    }

    std::vector<std::jthread> workers;
    workers.reserve(n_workers);
    for (int i = 0; i < n_workers; ++i) {
        workers.emplace_back(worker, i);
    }

    std::printf("main: started %d worker(s)\n", n_workers);
    std::fflush(stdout);

    while (!g_sigterm_received.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    }

    std::printf("main: SIGTERM received, calling request_stop() on %d worker(s)\n", n_workers);
    std::fflush(stdout);

    for (auto& w : workers) {
        w.request_stop();
    }
    for (auto& w : workers) {
        w.join();
    }

    std::printf("main: shutdown complete, all workers joined\n");
    std::fflush(stdout);

    return 0;
}
