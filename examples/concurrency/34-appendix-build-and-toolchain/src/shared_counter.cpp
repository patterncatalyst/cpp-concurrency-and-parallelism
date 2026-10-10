// concurrency/34-appendix-build-and-toolchain — the appendix's own tiny
// reference program.
//
// This is deliberately the simplest possible multi-threaded program: four
// threads each increment a shared counter kItersPerThread times. Two
// paths:
//
//   (default)        -- increments an std::atomic<uint64_t> with
//                        fetch_add. Correct and race-free by
//                        construction: final_count == expected always,
//                        on every compiler, every time.
//   --inject-race    -- increments a PLAIN (non-atomic) uint64_t with an
//                        unsynchronized read-modify-write instead. A
//                        genuine data race: a ThreadSanitizer-instrumented
//                        build flags it; final_count may or may not equal
//                        expected (lost updates are an expected symptom
//                        of the race, not something this path tries to
//                        avoid -- the point is for a TSan build to catch
//                        the race, not for the arithmetic to come out
//                        right despite it).
//
// --inject-race is OFF by default, matching the appendix's reference
// program: the chapter's CMakePresets.json gives this exact tiny program
// a clang-tsan leg, and the race is reachable only behind the flag so
// the default (safe) build and run stays fully correct and useful for
// the gcc-vs-clang output-parity check the appendix also describes.
//
// Prints one line in a key=value form a shell or Lua harness can parse
// without any special grammar:
//
//   mode=safe final_count=800000 expected=800000

#include <atomic>
#include <cstdint>
#include <cstring>
#include <thread>
#include <vector>

#include <fmt/core.h>

namespace {

constexpr unsigned kThreads = 4;
constexpr std::uint64_t kItersPerThread = 200'000ULL;

// Deliberately unsynchronized: no std::atomic, no mutex. Only ever
// touched from increment_racy(), which is only ever invoked behind
// --inject-race. A ThreadSanitizer-instrumented build of this translation
// unit reliably flags the concurrent, unsynchronized read-modify-write
// below as a data race.
std::uint64_t g_unsynchronized_counter = 0;

void increment_safe(std::atomic<std::uint64_t>& counter, std::uint64_t iters) {
    for (std::uint64_t i = 0; i < iters; ++i) {
        counter.fetch_add(1, std::memory_order_relaxed);
    }
}

void increment_racy(std::uint64_t iters) {
    for (std::uint64_t i = 0; i < iters; ++i) {
        // Deliberately unsynchronized read-modify-write on a plain
        // shared counter -- the injected race. Reachable only behind
        // --inject-race.
        g_unsynchronized_counter = g_unsynchronized_counter + 1;
    }
}

} // namespace

int main(int argc, char** argv) {
    bool inject_race = false;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--inject-race") == 0) {
            inject_race = true;
        } else if (std::strcmp(argv[i], "-h") == 0 || std::strcmp(argv[i], "--help") == 0) {
            fmt::print("usage: shared_counter [--inject-race]\n");
            return 0;
        }
    }

    const std::uint64_t expected = static_cast<std::uint64_t>(kThreads) * kItersPerThread;
    std::vector<std::thread> workers;
    workers.reserve(kThreads);

    if (inject_race) {
        for (unsigned i = 0; i < kThreads; ++i) {
            workers.emplace_back(increment_racy, kItersPerThread);
        }
        for (auto& t : workers) {
            t.join();
        }
        fmt::print("mode=racy final_count={} expected={}\n",
            g_unsynchronized_counter, expected);
    } else {
        std::atomic<std::uint64_t> counter{0};
        for (unsigned i = 0; i < kThreads; ++i) {
            workers.emplace_back(increment_safe, std::ref(counter), kItersPerThread);
        }
        for (auto& t : workers) {
            t.join();
        }
        fmt::print("mode=safe final_count={} expected={}\n",
            counter.load(), expected);
    }

    return 0;
}
