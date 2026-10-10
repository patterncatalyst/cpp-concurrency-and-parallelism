// concurrent_client.cpp — concurrency/25-concurrent-grpc's load generator.
//
// Launches `--calls N` concurrent ServerStreamEcho RPCs against
// async_server: one std::thread per call (genuine OS-level concurrency,
// even though each call itself uses the blocking/sync stub API -- the
// server never sees the difference, since the async CompletionQueue
// machinery under test is entirely server-side), all released from the
// same starting line via a std::latch so they actually overlap in time
// instead of trickling in one at a time and never exceeding the server's
// in-flight cap by accident.
//
// Every call reads its stream to completion (or its immediate terminal
// status, for a rejected call) and prints exactly one line this project's
// verify.lua parses:
//
//   call=<idx> status=<OK|RESOURCE_EXHAUSTED|OTHER> code=<int>
//       messages=<n> elapsed_ms=<ms>

#include <grpcpp/grpcpp.h>

#include "echo.grpc.pb.h"

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <latch>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

using echo::v1::Echo;
using echo::v1::EchoRequest;
using echo::v1::EchoResponse;

struct Args {
    std::string addr = "127.0.0.1:50051";
    int calls = 8;
    int repeat_count = 10;
    int deadline_ms = 5000;
};

Args parse_args(int argc, char** argv) {
    Args a;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) throw std::runtime_error("missing value for " + arg);
            return argv[++i];
        };
        if (arg == "--addr") a.addr = next();
        else if (arg == "--calls") a.calls = std::stoi(next());
        else if (arg == "--repeat-count") a.repeat_count = std::stoi(next());
        else if (arg == "--deadline-ms") a.deadline_ms = std::stoi(next());
        else throw std::runtime_error("unknown argument: " + arg);
    }
    return a;
}

// Block (bounded) until the channel reports GRPC_CHANNEL_READY, so a
// slow-starting server surfaces as a clean "could not connect" message
// here rather than as spurious UNAVAILABLE results mixed into the
// admission-control behavior this client exists to exercise.
bool wait_connected(grpc::Channel& channel, std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::system_clock::now() + timeout;
    grpc_connectivity_state state = channel.GetState(/*try_to_connect=*/true);
    while (state != GRPC_CHANNEL_READY) {
        if (std::chrono::system_clock::now() >= deadline) return false;
        channel.WaitForStateChange(state, deadline);
        state = channel.GetState(/*try_to_connect=*/true);
    }
    return true;
}

void run_one(int idx, std::shared_ptr<grpc::Channel> channel, int repeat_count,
             int deadline_ms, std::latch& start, std::mutex& out_mutex) {
    auto stub = Echo::NewStub(channel);

    grpc::ClientContext ctx;
    ctx.set_deadline(std::chrono::system_clock::now() +
                      std::chrono::milliseconds(deadline_ms));

    EchoRequest req;
    req.set_message("call-" + std::to_string(idx));
    req.set_repeat_count(repeat_count);

    start.arrive_and_wait();  // release every thread at (as near as the
                               // scheduler allows) the same instant

    const auto t0 = std::chrono::steady_clock::now();
    std::unique_ptr<grpc::ClientReader<EchoResponse>> reader(
        stub->ServerStreamEcho(&ctx, req));

    int messages = 0;
    EchoResponse resp;
    while (reader->Read(&resp)) {
        ++messages;
    }
    const grpc::Status status = reader->Finish();
    const double elapsed_ms = std::chrono::duration<double, std::milli>(
                                   std::chrono::steady_clock::now() - t0)
                                   .count();

    const char* status_word = "OTHER";
    if (status.ok()) {
        status_word = "OK";
    } else if (status.error_code() == grpc::StatusCode::RESOURCE_EXHAUSTED) {
        status_word = "RESOURCE_EXHAUSTED";
    }

    std::lock_guard<std::mutex> lk(out_mutex);
    std::cout << "call=" << idx << " status=" << status_word
              << " code=" << static_cast<int>(status.error_code())
              << " messages=" << messages << " elapsed_ms=" << elapsed_ms
              << "\n";
}

}  // namespace

int main(int argc, char** argv) {
    Args args;
    try {
        args = parse_args(argc, argv);
    } catch (const std::exception& e) {
        std::cerr << "bad arguments: " << e.what() << "\n";
        return 2;
    }
    if (args.calls < 1) {
        std::cerr << "--calls must be >= 1\n";
        return 2;
    }

    auto channel =
        grpc::CreateChannel(args.addr, grpc::InsecureChannelCredentials());
    if (!wait_connected(*channel, std::chrono::seconds(10))) {
        std::cerr << "could not connect to " << args.addr << " within 10s\n";
        return 1;
    }

    std::latch start(static_cast<std::ptrdiff_t>(args.calls));
    std::mutex out_mutex;
    std::vector<std::jthread> threads;
    threads.reserve(static_cast<std::size_t>(args.calls));
    for (int i = 0; i < args.calls; ++i) {
        threads.emplace_back(run_one, i, channel, args.repeat_count,
                              args.deadline_ms, std::ref(start),
                              std::ref(out_mutex));
    }
    threads.clear();  // jthread destructors join

    std::cout << "RESULT: client done, calls=" << args.calls << std::endl;
    return 0;
}
