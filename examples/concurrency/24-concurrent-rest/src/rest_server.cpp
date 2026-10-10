// concurrency/24-concurrent-rest — rest_server
//
// The minimal Boost.Beast async HTTP server from Doc 24, built out into a
// runnable demo of the chapter's back-pressure + overload-shedding pair:
// a fixed in-flight-request cap enforced with an atomic counter, and a
// cheap HTTP 503 (+ Retry-After) shed path that never touches the handler
// that does the (simulated) work.
//
// Concurrency model: one coroutine per connection (C++20
// boost::asio::awaitable, co_spawn'd from the listener), matching the
// chapter's "A Minimal Boost.Beast Server" section -- no thread is ever
// named explicitly; where a session's code actually runs is decided by
// whichever worker thread's io_context::run() call is free when its
// socket becomes readable. The worker-thread *count*, though, is sized
// off the container's cgroup v2 cpu.max quota rather than
// hardware_concurrency() (see detect_worker_threads below), per the
// chapter's "Running in a container" section -- falling back to
// hardware_concurrency() (clamped small) when no quota is set, e.g. a
// plain `docker run` with no --cpus.
//
// Each accepted connection is intentionally single-request
// (Connection: close): the client in this demo opens a fresh connection
// per request, so there is no idle keep-alive connection for graceful
// shutdown to wait out -- every in-flight session is a bounded
// read -> (maybe work) -> write cycle a few tens of milliseconds long.
// That keeps SIGTERM-triggered drain near-instant, which is what lets
// the whole demo terminate deterministically inside one container run.
//
// CLI (all optional, "--flag value"):
//   --port N         listen port                         (default 18080)
//   --cap N          in-flight-request shed threshold     (default 16)
//   --work-ms N      simulated per-accepted-request work  (default 15)
//   --threads N      override auto-detected worker count  (default: auto)
//   --pidfile PATH   write our PID here before listening  (default /tmp/rest_server.pid)
//   --readyfile PATH touch this after listen() succeeds   (default /tmp/rest_server.ready)
//
// Shutdown: SIGINT/SIGTERM closes the acceptor (stop accepting new
// connections); io_context::run() returns on every worker thread once the
// listener coroutine and all in-flight sessions have finished, and main()
// exits 0. verify.lua drives this end-to-end: start the server, load it
// past --cap with rest_client, send SIGTERM, assert a clean (exit-code 0)
// stop.

#include "cli.hpp"

#include <boost/asio/as_tuple.hpp>
#include <boost/asio/awaitable.hpp>
#include <boost/asio/co_spawn.hpp>
#include <boost/asio/detached.hpp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/signal_set.hpp>
#include <boost/asio/steady_timer.hpp>
#include <boost/asio/use_awaitable.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h> // getpid

namespace beast = boost::beast;
namespace http = beast::http;
namespace net = boost::asio;
using tcp = net::ip::tcp;

namespace {

std::atomic<int> g_in_flight{0};
std::atomic<uint64_t> g_count_200{0};
std::atomic<uint64_t> g_count_503{0};

void write_file(const std::string& path, const std::string& contents) {
    std::ofstream f(path, std::ios::trunc);
    f << contents;
}

// Size the io_context's worker-thread pool off the container's cgroup v2
// CPU quota (cpu.max: "<quota> <period>", or "max <period>" for no limit)
// rather than std::thread::hardware_concurrency() -- the exact trap Doc
// 24's "Running in a container" section describes: hardware_concurrency()
// reports the host's core count even inside a quota-throttled container,
// so a pool sized off it can spin up far more runner threads than the
// quota can actually schedule at once. --threads always wins when given;
// the auto-detected value is clamped to a small ceiling since this is a
// demo, not a production sizing formula.
unsigned detect_worker_threads(long override_threads) {
    if (override_threads > 0) {
        return static_cast<unsigned>(override_threads);
    }

    unsigned hw = std::max(1u, std::thread::hardware_concurrency());

    std::ifstream f("/sys/fs/cgroup/cpu.max");
    if (f) {
        std::string quota, period;
        f >> quota >> period;
        if (!quota.empty() && quota != "max" && !period.empty()) {
            long q = std::strtol(quota.c_str(), nullptr, 10);
            long p = std::strtol(period.c_str(), nullptr, 10);
            if (q > 0 && p > 0) {
                // Round up: a 1.5-core quota still needs 2 runner threads
                // to use the full budget without starving either.
                hw = std::max<long>(1, (q + p - 1) / p);
            }
        }
    }

    return std::min(hw, 8u);
}

net::awaitable<void> session(tcp::socket socket, int cap, int work_ms) {
    beast::tcp_stream stream(std::move(socket));
    beast::flat_buffer buffer;
    http::request<http::string_body> req;

    stream.expires_after(std::chrono::seconds(10));
    auto [rec, rn] = co_await http::async_read(
        stream, buffer, req, net::as_tuple(net::use_awaitable));
    (void)rn;
    if (rec) {
        co_return; // client closed early, or the read timed out
    }

    // The capacity gate: claim a slot optimistically, then check it. The
    // shed path below gives the slot straight back and does no further
    // work -- a shedding request must not itself consume the capacity
    // it's protecting.
    int slot = g_in_flight.fetch_add(1, std::memory_order_acq_rel) + 1;
    bool accepted = slot <= cap;
    if (!accepted) {
        g_in_flight.fetch_sub(1, std::memory_order_acq_rel);
    } else {
        // Stand-in for real handler work (a downstream call, a DB query):
        // just long enough, and non-blocking, so a burst of concurrent
        // requests actually overlaps instead of draining one at a time
        // faster than the cap could ever be observed.
        net::steady_timer timer(stream.get_executor(), std::chrono::milliseconds(work_ms));
        auto [tec] = co_await timer.async_wait(net::as_tuple(net::use_awaitable));
        (void)tec;
    }

    http::response<http::string_body> res{
        accepted ? http::status::ok : http::status::service_unavailable,
        req.version()};
    res.set(http::field::server, "cpp-concurrent-rest-demo");
    res.set(http::field::content_type, "application/json");
    if (accepted) {
        g_count_200.fetch_add(1, std::memory_order_relaxed);
        res.body() = R"({"status":"ok"})";
    } else {
        g_count_503.fetch_add(1, std::memory_order_relaxed);
        res.set(http::field::retry_after, "1");
        res.body() = R"({"status":"overloaded"})";
    }
    res.keep_alive(false); // one request per connection, by design
    res.prepare_payload();

    auto [wec, wn] = co_await http::async_write(
        stream, res, net::as_tuple(net::use_awaitable));
    (void)wec;
    (void)wn;

    // The in-flight slot is held for the full accepted-but-not-yet-handled
    // window: from the optimistic claim above through the response write,
    // not just the simulated work.
    if (accepted) {
        g_in_flight.fetch_sub(1, std::memory_order_acq_rel);
    }

    beast::error_code sec;
    stream.socket().shutdown(tcp::socket::shutdown_send, sec);
}

net::awaitable<void> listener(tcp::acceptor& acceptor, int cap, int work_ms) {
    for (;;) {
        auto [ec, socket] = co_await acceptor.async_accept(
            net::as_tuple(net::use_awaitable));
        if (ec) {
            // acceptor.close() on shutdown completes this with
            // operation_aborted -- time to stop, not an error to report.
            co_return;
        }
        net::co_spawn(acceptor.get_executor(), session(std::move(socket), cap, work_ms),
                       net::detached);
    }
}

} // namespace

int main(int argc, char** argv) {
    const int port = static_cast<int>(cli::get_long(argc, argv, "--port", 18080));
    const int cap = static_cast<int>(cli::get_long(argc, argv, "--cap", 16));
    const int work_ms = static_cast<int>(cli::get_long(argc, argv, "--work-ms", 15));
    const long threads_override = cli::get_long(argc, argv, "--threads", 0);
    const std::string pidfile = cli::get(argc, argv, "--pidfile", "/tmp/rest_server.pid");
    const std::string readyfile = cli::get(argc, argv, "--readyfile", "/tmp/rest_server.ready");

    const unsigned num_threads = detect_worker_threads(threads_override);

    write_file(pidfile, std::to_string(::getpid()) + "\n");

    net::io_context ioc{static_cast<int>(num_threads)};

    tcp::acceptor acceptor(ioc);
    tcp::endpoint endpoint(net::ip::make_address("127.0.0.1"), static_cast<unsigned short>(port));
    acceptor.open(endpoint.protocol());
    acceptor.set_option(net::socket_base::reuse_address(true));
    acceptor.bind(endpoint);
    acceptor.listen(net::socket_base::max_listen_connections);

    net::signal_set signals(ioc, SIGINT, SIGTERM);
    signals.async_wait([&acceptor](const boost::system::error_code&, int signo) {
        std::cerr << "rest_server: received signal " << signo
                  << ", draining in-flight requests...\n";
        boost::system::error_code ec;
        acceptor.close(ec);
    });

    net::co_spawn(ioc, listener(acceptor, cap, work_ms), net::detached);

    // Readiness marker only after listen() has actually succeeded --
    // verify.lua polls for this file before pointing a client at the port.
    write_file(readyfile, "ready\n");

    std::cerr << "rest_server: listening on 127.0.0.1:" << port
              << " cap=" << cap << " work_ms=" << work_ms
              << " threads=" << num_threads << "\n";

    std::vector<std::thread> pool;
    pool.reserve(num_threads > 0 ? num_threads - 1 : 0);
    for (unsigned i = 1; i < num_threads; ++i) {
        pool.emplace_back([&ioc] { ioc.run(); });
    }
    ioc.run();
    for (auto& t : pool) {
        t.join();
    }

    std::cerr << "rest_server: drained cleanly. total_200=" << g_count_200.load()
              << " total_503=" << g_count_503.load() << "\n";
    return 0;
}
