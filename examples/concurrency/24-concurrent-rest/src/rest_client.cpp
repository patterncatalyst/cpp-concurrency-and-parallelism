// concurrency/24-concurrent-rest — rest_client
//
// A small concurrent HTTP load generator built on the same
// Boost.Asio/Beast C++20-coroutine stack as rest_server.cpp, used in place
// of wrk/hey so the whole demo (server + client) builds from one
// conanfile and runs with no extra tooling inside the container.
//
// Concurrency model: --concurrency worker coroutines are co_spawn'd onto a
// *single*-threaded io_context. Each worker claims one unit of work at a
// time from a shared counter (an atomic fetch_sub, so exactly --requests
// units are claimed in total across all workers, no more and no less) and
// issues one HTTP GET over a fresh, short-lived connection
// (Connection: close) before claiming its next unit. The number of
// requests actually in flight against the server at any instant is
// therefore bounded by --concurrency -- which is the knob this demo turns
// above and below rest_server's --cap to exercise the shed path.
//
// Every request is one of exactly three outcomes, counted atomically:
//   status_200    — accepted and handled
//   status_503    — shed by the server's in-flight cap
//   other_errors  — connect/write/read failure, timeout, or any other
//                   HTTP status; this must be 0 for the demo to be
//                   considered correct (no dropped/reset/hung request)
//
// CLI (all optional, "--flag value"):
//   --host H          server host          (default 127.0.0.1)
//   --port N          server port          (default 18080)
//   --concurrency N   concurrent workers   (default 8)
//   --requests N      total requests       (default 100)
//   --timeout-ms N    per-request deadline (default 5000)
//
// Prints exactly one summary line to stdout on completion, in the same
// space-separated key=value form every verify.lua in this project parses:
//   SUMMARY requests=400 status_200=210 status_503=190 other_errors=0 min_ms=0.512 median_ms=16.204 max_ms=42.881

#include "cli.hpp"

#include <boost/asio/as_tuple.hpp>
#include <boost/asio/awaitable.hpp>
#include <boost/asio/co_spawn.hpp>
#include <boost/asio/detached.hpp>
#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/tcp.hpp>
#include <boost/asio/this_coro.hpp>
#include <boost/beast/core.hpp>
#include <boost/beast/http.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

namespace beast = boost::beast;
namespace http = beast::http;
namespace net = boost::asio;
using tcp = net::ip::tcp;

namespace {

std::atomic<uint64_t> g_status_200{0};
std::atomic<uint64_t> g_status_503{0};
std::atomic<uint64_t> g_other_errors{0};

std::mutex g_latency_mu;
std::vector<double> g_latency_ms; // elapsed time for status_200 responses only

net::awaitable<void> one_request(const tcp::resolver::results_type& endpoints,
                                  std::chrono::milliseconds timeout) {
    try {
        beast::tcp_stream stream(co_await net::this_coro::executor);
        stream.expires_after(timeout);

        auto start = std::chrono::steady_clock::now();

        auto [cec, cep] = co_await stream.async_connect(
            endpoints, net::as_tuple(net::use_awaitable));
        (void)cep;
        if (cec) {
            g_other_errors.fetch_add(1, std::memory_order_relaxed);
            co_return;
        }

        http::request<http::empty_body> req{http::verb::get, "/", 11};
        req.set(http::field::host, "127.0.0.1");
        req.set(http::field::user_agent, "rest_client/24-concurrent-rest");
        req.keep_alive(false);
        req.prepare_payload();

        auto [wec, wn] = co_await http::async_write(
            stream, req, net::as_tuple(net::use_awaitable));
        (void)wn;
        if (wec) {
            g_other_errors.fetch_add(1, std::memory_order_relaxed);
            co_return;
        }

        beast::flat_buffer buffer;
        http::response<http::string_body> res;
        auto [rec, rn] = co_await http::async_read(
            stream, buffer, res, net::as_tuple(net::use_awaitable));
        (void)rn;
        // end_of_stream after a full response is a normal consequence of
        // the server's Connection: close -- not a failure.
        if (rec && rec != http::error::end_of_stream) {
            g_other_errors.fetch_add(1, std::memory_order_relaxed);
            co_return;
        }

        double elapsed_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - start).count();

        if (res.result() == http::status::ok) {
            g_status_200.fetch_add(1, std::memory_order_relaxed);
            std::lock_guard<std::mutex> lk(g_latency_mu);
            g_latency_ms.push_back(elapsed_ms);
        } else if (res.result() == http::status::service_unavailable) {
            g_status_503.fetch_add(1, std::memory_order_relaxed);
        } else {
            g_other_errors.fetch_add(1, std::memory_order_relaxed);
        }

        beast::error_code sec;
        stream.socket().shutdown(tcp::socket::shutdown_both, sec);
    } catch (...) {
        g_other_errors.fetch_add(1, std::memory_order_relaxed);
    }
}

net::awaitable<void> worker(tcp::resolver::results_type endpoints,
                             std::atomic<int64_t>& remaining,
                             std::chrono::milliseconds timeout) {
    for (;;) {
        int64_t claimed = remaining.fetch_sub(1, std::memory_order_acq_rel);
        if (claimed <= 0) {
            co_return; // no work left -- every unit already claimed
        }
        co_await one_request(endpoints, timeout);
    }
}

} // namespace

int main(int argc, char** argv) {
    const std::string host = cli::get(argc, argv, "--host", "127.0.0.1");
    const std::string port = cli::get(argc, argv, "--port", "18080");
    const int concurrency = static_cast<int>(cli::get_long(argc, argv, "--concurrency", 8));
    const int64_t total_requests = cli::get_long(argc, argv, "--requests", 100);
    const int timeout_ms = static_cast<int>(cli::get_long(argc, argv, "--timeout-ms", 5000));

    net::io_context ioc;
    tcp::resolver resolver(ioc);
    auto endpoints = resolver.resolve(host, port);

    std::atomic<int64_t> remaining{total_requests};
    for (int i = 0; i < concurrency; ++i) {
        net::co_spawn(
            ioc, worker(endpoints, remaining, std::chrono::milliseconds(timeout_ms)),
            net::detached);
    }
    ioc.run();

    double min_ms = 0.0, median_ms = 0.0, max_ms = 0.0;
    {
        std::lock_guard<std::mutex> lk(g_latency_mu);
        if (!g_latency_ms.empty()) {
            std::sort(g_latency_ms.begin(), g_latency_ms.end());
            min_ms = g_latency_ms.front();
            max_ms = g_latency_ms.back();
            median_ms = g_latency_ms[g_latency_ms.size() / 2];
        }
    }

    const uint64_t s200 = g_status_200.load();
    const uint64_t s503 = g_status_503.load();
    const uint64_t other = g_other_errors.load();
    const uint64_t total_done = s200 + s503 + other;

    std::printf(
        "SUMMARY requests=%llu status_200=%llu status_503=%llu other_errors=%llu "
        "min_ms=%.3f median_ms=%.3f max_ms=%.3f\n",
        static_cast<unsigned long long>(total_done),
        static_cast<unsigned long long>(s200),
        static_cast<unsigned long long>(s503),
        static_cast<unsigned long long>(other),
        min_ms, median_ms, max_ms);

    return 0;
}
