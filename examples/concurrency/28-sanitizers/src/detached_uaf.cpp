// concurrency/28-sanitizers — a real heap-use-after-free from a detached
// thread, caught by AddressSanitizer, plus its std::shared_ptr fix.
//
// --mode uaf:    main allocates a heap buffer, hands a RAW pointer to a
//                detached worker thread, then frees the buffer on the
//                main thread. The worker sleeps briefly (so the free
//                genuinely happens first, not "maybe") and then reads
//                through the now-dangling pointer. AddressSanitizer poisons
//                every byte of a heap allocation's shadow memory the
//                instant `delete[]` runs, so the worker's read trips the
//                instant it executes -- a genuine, concurrency-born
//                use-after-free: the bug exists because two threads
//                disagree about who owns the buffer's lifetime, even
//                though ASan itself has no model of threads at all. It
//                only sees one thread read memory another thread already
//                freed.
// --mode fixed:  the identical shape, except the detached worker captures
//                a std::shared_ptr<int[]> BY VALUE instead of a raw
//                pointer. Its own copy keeps the reference count above
//                zero for as long as the worker is still running, even
//                though main's own shared_ptr is reset immediately --
//                there is no free to race against at all.
//
// Usage:
//   detached_uaf --mode uaf|fixed
//
// A detached thread does not keep the process alive on its own, so both
// modes have main sleep briefly after handing off the buffer, giving the
// worker time to actually run before the process exits. Under
// AddressSanitizer, --mode uaf never reaches its own "completed" print --
// ASan halts the process (its default behavior) the moment the dangling
// read happens.

#include <chrono>
#include <cstdio>
#include <memory>
#include <string>
#include <thread>

#include <fmt/core.h>

namespace {

constexpr int kBufferSize = 64;
constexpr auto kWorkerDelay = std::chrono::milliseconds(150);
constexpr auto kMainDelay = std::chrono::milliseconds(400);

// noinline so both the allocating path (run_uaf) and this reading path
// show up as distinct frames in ASan's use-after-free report -- "naming
// both the allocating and freeing call stacks" means the report's three
// stacks (the faulting access, the allocation site, the free site) each
// resolve to a real, named function in this file, not an inlined blob.
__attribute__((noinline))
void detached_worker_raw(int* buffer) {
    std::this_thread::sleep_for(kWorkerDelay);
    // Use-after-free: `buffer` was deleted by main before this runs.
    int sum = 0;
    for (int i = 0; i < kBufferSize; ++i) {
        sum += buffer[i];
    }
    fmt::print("mode=uaf detached_worker observed sum={} (should never print under ASan)\n", sum);
}

__attribute__((noinline))
void run_uaf() {
    int* buffer = new int[kBufferSize];
    for (int i = 0; i < kBufferSize; ++i) buffer[i] = i;

    std::thread worker(detached_worker_raw, buffer);
    worker.detach();

    delete[] buffer; // freed on the main thread while the detached worker
                      // still holds the identical raw pointer

    // A detached thread does not keep the process alive on its own --
    // main has to outlive the window the worker needs to actually run its
    // read, or the process exits before the bug ever executes.
    std::this_thread::sleep_for(kMainDelay);
    fmt::print("mode=uaf result=completed-without-asan-catching-it\n");
}

__attribute__((noinline))
void detached_worker_shared(std::shared_ptr<int[]> buffer) {
    std::this_thread::sleep_for(kWorkerDelay);
    int sum = 0;
    for (int i = 0; i < kBufferSize; ++i) {
        sum += buffer[i];
    }
    fmt::print("mode=fixed detached_worker observed sum={}\n", sum);
}

__attribute__((noinline))
void run_fixed() {
    auto buffer = std::shared_ptr<int[]>(new int[kBufferSize]);
    for (int i = 0; i < kBufferSize; ++i) buffer[i] = i;

    // Captured by value: the worker's own copy of the shared_ptr keeps
    // the allocation's reference count above zero for as long as it's
    // still running, regardless of what main does with its own copy.
    std::thread worker(detached_worker_shared, buffer);
    worker.detach();

    buffer.reset(); // main's own reference goes away; no free happens
                     // here at all -- the worker's copy is still live

    std::this_thread::sleep_for(kMainDelay);
    fmt::print("mode=fixed result=ok\n");
}

} // namespace

int main(int argc, char** argv) {
    std::string mode = "fixed";
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--mode" && i + 1 < argc) {
            mode = argv[++i];
        } else if (arg == "-h" || arg == "--help") {
            fmt::print("usage: detached_uaf --mode uaf|fixed\n");
            return 0;
        }
    }

    if (mode == "uaf") {
        run_uaf();
    } else {
        run_fixed();
    }

    return 0;
}
