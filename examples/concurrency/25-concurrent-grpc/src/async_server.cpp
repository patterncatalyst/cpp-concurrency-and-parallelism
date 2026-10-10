// async_server.cpp — concurrency/25-concurrent-grpc's raw completion-queue
// async gRPC server (companion to _docs/25-concurrent-grpc-services.md).
//
// Implements the chapter's CallData pattern directly against
// grpc::ServerCompletionQueue (not the callback API): every call is a
// tiny state machine -- CREATE -> PROCESS -> (WRITE <-> DELAY)* -> FINISH
// -- tagged with `this`, re-arming itself at each phase and immediately
// spawning its own replacement the instant it leaves CREATE so the server
// never stops accepting new calls while an existing one is still being
// served.
//
// Two things this example adds on top of the chapter's minimal unary
// sketch:
//
//   1. Bounded admission. A single process-wide std::atomic<int> tracks
//      calls that have been accepted past CREATE; a configurable cap
//      (--cap) enforces an upper bound via a fetch_add-then-rollback
//      reservation, finishing any call that would exceed it with
//      RESOURCE_EXHAUSTED before it ever writes a message -- the gRPC
//      equivalent of a REST endpoint's 503, costing the server almost
//      nothing to issue.
//
//   2. Deliberate per-message pacing via grpc::Alarm. Each accepted call
//      schedules a non-blocking timer tag between successive Write()
//      calls instead of writing (and finishing) as fast as the CPU
//      allows. This is what makes the bounded-admission test meaningful:
//      without it, a small, fast stream could finish and free its slot
//      before concurrent_client's threads have all even started, masking
//      the cap entirely.
//
// Multiple completion queues, one dedicated servicing thread per queue
// (the chapter's sizing guidance), with the queue count derived from the
// container's cpu.max quota rather than std::thread::hardware_concurrency()
// -- the same cgroup-aware sizing concern 15-thread-pool's cgroup_probe and
// 32-concurrency-in-containers demonstrate, reimplemented locally here
// since every example in this project is self-contained.
//
// Graceful shutdown on SIGTERM/SIGINT: a signal handler only sets a
// volatile flag (signal-safe); main()'s loop reacts to it off-handler by
// calling Server::Shutdown(deadline) and then Shutdown() + drain (keep
// calling Next() until it returns false) on every completion queue before
// the process exits -- the chapter's explicit warning that skipping the
// per-queue drain abandons outstanding tags instead of completing them.

#include <grpcpp/grpcpp.h>
#include <grpcpp/alarm.h>

#include "echo.grpc.pb.h"

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

using echo::v1::Echo;
using echo::v1::EchoRequest;
using echo::v1::EchoResponse;

void log_line(const std::string& msg) {
    static std::mutex m;
    std::lock_guard<std::mutex> lk(m);
    std::cout << "[async_server] " << msg << std::endl;
}

// ---- cgroup-aware completion-queue/thread count -----------------------
// cpu.max (cgroup v2) holds "$QUOTA $PERIOD" in microseconds, or
// "max $PERIOD" when unlimited. Only v2 is read here (this demo's
// Containerfile and every container runtime it's documented against are
// cgroup v2); an unreadable or unlimited quota falls back to
// hardware_concurrency(), clamped to a small ceiling this workload never
// benefits from exceeding.
unsigned detect_cq_count() {
    unsigned hw = std::thread::hardware_concurrency();
    if (hw == 0) hw = 1;

    std::ifstream f("/sys/fs/cgroup/cpu.max");
    if (f) {
        std::string quota_tok, period_tok;
        if ((f >> quota_tok >> period_tok) && quota_tok != "max") {
            const long long quota = std::strtoll(quota_tok.c_str(), nullptr, 10);
            const long long period = std::strtoll(period_tok.c_str(), nullptr, 10);
            if (period > 0 && quota > 0) {
                long long cpus = (quota + period - 1) / period;  // ceil
                if (cpus < 1) cpus = 1;
                if (static_cast<unsigned>(cpus) < hw) {
                    return static_cast<unsigned>(cpus);
                }
            }
        }
    }
    return hw;
}

unsigned clamp_cq_count(unsigned n) {
    if (n < 1) return 1;
    if (n > 4) return 4;  // this demo's workload never needs more
    return n;
}

// ---- the CallData state machine ----------------------------------------
class CallData {
public:
    CallData(Echo::AsyncService* service, grpc::ServerCompletionQueue* cq,
             std::atomic<int>& inflight, int cap, int pacing_ms)
        : service_(service), cq_(cq), responder_(&ctx_), inflight_(inflight),
          cap_(cap), pacing_ms_(pacing_ms) {
        Proceed(true);
    }

    void Proceed(bool ok) {
        switch (status_) {
        case CREATE:
            status_ = PROCESS;
            service_->RequestServerStreamEcho(&ctx_, &request_, &responder_,
                                               cq_, cq_, this);
            break;

        case PROCESS: {
            if (!ok) {
                // The completion queue is shutting down and aborted this
                // pending accept; don't re-arm (issuing a fresh
                // RequestServerStreamEcho against an already-shutting-down
                // queue is exactly what would keep it from ever draining).
                delete this;
                return;
            }

            // Immediately seed this call's replacement so the server
            // never stops accepting new calls while this one runs -- the
            // chapter's CallData pattern, unchanged.
            new CallData(service_, cq_, inflight_, cap_, pacing_ms_);

            // Bounded admission: reserve a slot, roll back if the
            // reservation pushed the server over cap_. fetch_add returns
            // the count BEFORE this reservation, so "before >= cap_" means
            // this call is the one that would exceed it.
            const int before = inflight_.fetch_add(1, std::memory_order_acq_rel);
            if (before >= cap_) {
                inflight_.fetch_sub(1, std::memory_order_acq_rel);
                admitted_ = false;
                status_ = FINISH;
                responder_.Finish(
                    grpc::Status(grpc::StatusCode::RESOURCE_EXHAUSTED,
                                 "in-flight cap reached"),
                    this);
                return;
            }

            admitted_ = true;
            remaining_ = request_.repeat_count() > 0 ? request_.repeat_count() : 1;
            seq_ = 0;
            WriteNext();
            break;
        }

        case WRITE:
            if (!ok) {
                FinishCall(grpc::Status(grpc::StatusCode::CANCELLED,
                                        "write failed"));
                return;
            }
            if (remaining_ > 0 && pacing_ms_ > 0) {
                status_ = DELAY;
                alarm_.Set(cq_,
                           std::chrono::system_clock::now() +
                               std::chrono::milliseconds(pacing_ms_),
                           this);
            } else if (remaining_ > 0) {
                WriteNext();
            } else {
                FinishCall(grpc::Status::OK);
            }
            break;

        case DELAY:
            if (!ok) {
                FinishCall(grpc::Status(grpc::StatusCode::CANCELLED,
                                        "alarm cancelled"));
                return;
            }
            WriteNext();
            break;

        case FINISH:
            if (admitted_) inflight_.fetch_sub(1, std::memory_order_acq_rel);
            delete this;
            break;
        }
    }

private:
    void WriteNext() {
        EchoResponse resp;
        resp.set_message(request_.message());
        resp.set_sequence(seq_++);
        --remaining_;
        status_ = WRITE;
        responder_.Write(resp, this);
    }

    void FinishCall(grpc::Status s) {
        status_ = FINISH;
        responder_.Finish(s, this);
    }

    enum CallStatus { CREATE, PROCESS, WRITE, DELAY, FINISH };

    Echo::AsyncService* service_;
    grpc::ServerCompletionQueue* cq_;
    grpc::ServerContext ctx_;
    EchoRequest request_;
    grpc::ServerAsyncWriter<EchoResponse> responder_;
    CallStatus status_ = CREATE;
    grpc::Alarm alarm_;

    std::atomic<int>& inflight_;
    int cap_;
    int pacing_ms_;
    bool admitted_ = false;
    int remaining_ = 0;
    int seq_ = 0;
};

void HandleRpcs(Echo::AsyncService& service, grpc::ServerCompletionQueue& cq,
                 std::atomic<int>& inflight, int cap, int pacing_ms) {
    new CallData(&service, &cq, inflight, cap, pacing_ms);  // seed first accept
    void* tag;
    bool ok;
    while (cq.Next(&tag, &ok)) {
        static_cast<CallData*>(tag)->Proceed(ok);
    }
}

volatile std::sig_atomic_t g_shutdown = 0;
void on_signal(int) { g_shutdown = 1; }

struct Args {
    std::string listen_addr = "127.0.0.1:50051";
    int cap = 4;
    int pacing_ms = 50;
    unsigned queues = 0;  // 0 == auto-detect from cpu.max
};

Args parse_args(int argc, char** argv) {
    Args a;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc) throw std::runtime_error("missing value for " + arg);
            return argv[++i];
        };
        if (arg == "--listen") a.listen_addr = next();
        else if (arg == "--cap") a.cap = std::stoi(next());
        else if (arg == "--pacing-ms") a.pacing_ms = std::stoi(next());
        else if (arg == "--queues") a.queues = static_cast<unsigned>(std::stoi(next()));
        else throw std::runtime_error("unknown argument: " + arg);
    }
    return a;
}

}  // namespace

int main(int argc, char** argv) {
    std::signal(SIGTERM, on_signal);
    std::signal(SIGINT, on_signal);

    Args args;
    try {
        args = parse_args(argc, argv);
    } catch (const std::exception& e) {
        log_line(std::string("bad arguments: ") + e.what());
        return 2;
    }

    const unsigned num_cq =
        args.queues != 0 ? args.queues : clamp_cq_count(detect_cq_count());

    Echo::AsyncService service;
    grpc::ServerBuilder builder;
    builder.AddListeningPort(args.listen_addr, grpc::InsecureServerCredentials());
    builder.RegisterService(&service);

    std::vector<std::unique_ptr<grpc::ServerCompletionQueue>> cqs;
    cqs.reserve(num_cq);
    for (unsigned i = 0; i < num_cq; ++i) {
        cqs.push_back(builder.AddCompletionQueue());
    }

    std::unique_ptr<grpc::Server> server = builder.BuildAndStart();
    if (!server) {
        log_line("failed to start gRPC server on " + args.listen_addr);
        return 1;
    }

    std::atomic<int> inflight{0};
    log_line("listening on " + args.listen_addr +
             " cap=" + std::to_string(args.cap) +
             " queues=" + std::to_string(num_cq) +
             " pacing_ms=" + std::to_string(args.pacing_ms));

    std::vector<std::jthread> workers;
    workers.reserve(num_cq);
    for (unsigned i = 0; i < num_cq; ++i) {
        workers.emplace_back([&service, &cq = *cqs[i], &inflight, &args] {
            HandleRpcs(service, cq, inflight, args.cap, args.pacing_ms);
        });
    }

    // Poll for the shutdown signal off the handler (signal-safe: the
    // handler only sets a volatile flag, the same discipline the sibling
    // statelessness tutorial's pricing_svc.cpp control thread uses).
    while (!g_shutdown) {
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }

    log_line("signal received; shutting down (draining in-flight calls)");
    server->Shutdown(std::chrono::system_clock::now() + std::chrono::seconds(5));
    for (auto& cq : cqs) cq->Shutdown();

    // jthread destructors join once each cq's Next() loop returns false,
    // which happens only after that cq is both Shutdown() and fully
    // drained of pending tags -- the chapter's required drain-before-exit.
    workers.clear();

    log_line("drained cleanly; exiting");
    return 0;
}
