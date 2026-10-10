// concurrency/11-coroutines-in-depth — generator, Task<T>, and HALO.
//
// C++20 coroutines are a language feature with no standard-library
// coroutine TYPE at all (std::generator doesn't arrive until C++23; this
// project standardizes on C++20, so both types below are hand-rolled the
// way the chapter shows). Three things, in one translation unit:
//
//   1. Generator<T> — a co_yield-based lazy sequence (here, Fibonacci),
//      consumed finitely via an ordinary range-for + break. Demonstrates
//      promise_type's yield_value and that destroying a generator
//      suspended mid-co_yield is well-defined, not a leak.
//   2. Task<T> — a co_await-able coroutine type whose final_suspend
//      performs symmetric transfer (resumes the awaiting coroutine's
//      handle directly, a tail call, instead of calling .resume()
//      recursively), so a chain of co_await'd sub-tasks costs no extra
//      stack regardless of chain length.
//   3. HALO (Heap Allocation eLision Optimization) observation — two
//      probe coroutines with an instrumented promise_type::operator new
//      counting allocations and recording the requested frame size: one
//      "tiny" probe with no state live across a suspension point, one
//      "fat" probe carrying a 4 KiB buffer across a real internal
//      co_await. The standard only ever *permits* eliding the frame
//      allocation ([dcl.fct.def.coroutine]: "may", not "shall") when the
//      compiler can prove the frame doesn't outlive its caller — whether
//      a given toolchain actually takes that opportunity here is reported
//      as an observation, not asserted either way.
//
// Prints key=value lines a shell or a Lua harness can parse without any
// special grammar:
//
//   generator_sequence=0,1,1,2,3,5,8,13,21,34
//   task_result=23
//   tiny_frame_allocs=1 tiny_frame_bytes=48
//   fat_frame_allocs=1 fat_frame_bytes=4136 fat_buffer_bytes=4096

#include <array>
#include <coroutine>
#include <cstdint>
#include <exception>
#include <iterator>
#include <string>
#include <utility>
#include <vector>

#include <fmt/core.h>

namespace {

// ════════════════════════════════════════════════════════════════════════
// 1. Generator<T> — hand-rolled co_yield sequence (no std::generator: that
//    is C++23; this project targets C++20).
// ════════════════════════════════════════════════════════════════════════

template <typename T>
class Generator {
public:
    struct promise_type {
        T current_value{};

        Generator get_return_object() {
            return Generator{std::coroutine_handle<promise_type>::from_promise(*this)};
        }
        std::suspend_always initial_suspend() noexcept { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        std::suspend_always yield_value(T value) noexcept {
            current_value = std::move(value);
            return {};
        }
        void return_void() noexcept {}
        void unhandled_exception() { std::terminate(); }
    };

    struct iterator {
        std::coroutine_handle<promise_type> handle;

        bool operator!=(std::default_sentinel_t) const { return !handle.done(); }
        iterator& operator++() {
            handle.resume();
            return *this;
        }
        const T& operator*() const { return handle.promise().current_value; }
    };

    explicit Generator(std::coroutine_handle<promise_type> h) : handle_(h) {}
    Generator(Generator&& other) noexcept : handle_(std::exchange(other.handle_, {})) {}
    Generator(const Generator&) = delete;
    Generator& operator=(const Generator&) = delete;
    ~Generator() {
        if (handle_) {
            handle_.destroy();
        }
    }

    // Starts the coroutine (runs it to its first co_yield) and returns an
    // iterator over the rest. Breaking out of a range-for before the
    // sequence "ends" (it never does -- fibonacci() below loops forever)
    // destroys *this, which destroys a coroutine suspended mid-co_yield --
    // well-defined: it runs the destructors of any locals in scope at the
    // suspension point and frees the frame.
    iterator begin() {
        handle_.resume();
        return iterator{handle_};
    }
    std::default_sentinel_t end() { return {}; }

private:
    std::coroutine_handle<promise_type> handle_;
};

// An intentionally infinite generator -- consumed finitely below via an
// explicit break, the same shape the chapter uses with std::views::take.
Generator<std::uint64_t> fibonacci() {
    std::uint64_t a = 0;
    std::uint64_t b = 1;
    while (true) {
        co_yield a;
        const std::uint64_t next = a + b;
        a = b;
        b = next;
    }
}

// ════════════════════════════════════════════════════════════════════════
// 2. Task<T> — co_await-able coroutine with symmetric transfer.
// ════════════════════════════════════════════════════════════════════════

template <typename T>
class Task {
public:
    struct promise_type {
        T value{};
        std::exception_ptr exception;
        std::coroutine_handle<> continuation; // who co_await'd us, if anyone

        Task get_return_object() {
            return Task{std::coroutine_handle<promise_type>::from_promise(*this)};
        }
        std::suspend_always initial_suspend() noexcept { return {}; }

        // final_suspend performs the symmetric-transfer handoff: instead of
        // calling continuation.resume() here (which would nest one stack
        // frame per link in a chain of awaited tasks), it RETURNS the
        // handle to resume. The compiler turns that into a tail call, so a
        // chain of any length costs no extra stack.
        struct FinalAwaiter {
            bool await_ready() noexcept { return false; }
            std::coroutine_handle<> await_suspend(std::coroutine_handle<promise_type> h) noexcept {
                auto continuation = h.promise().continuation;
                return continuation ? continuation : std::noop_coroutine();
            }
            void await_resume() noexcept {}
        };
        FinalAwaiter final_suspend() noexcept { return {}; }

        void return_value(T v) { value = std::move(v); }
        void unhandled_exception() { exception = std::current_exception(); }
    };

    explicit Task(std::coroutine_handle<promise_type> h) : handle_(h) {}
    Task(Task&& other) noexcept : handle_(std::exchange(other.handle_, {})) {}
    Task(const Task&) = delete;
    Task& operator=(const Task&) = delete;
    ~Task() {
        if (handle_) {
            handle_.destroy();
        }
    }

    // Awaitable interface -- lets one Task be co_await'd from inside
    // another coroutine's body.
    bool await_ready() const noexcept { return false; }
    std::coroutine_handle<> await_suspend(std::coroutine_handle<> awaiting) noexcept {
        handle_.promise().continuation = awaiting;
        return handle_; // symmetric transfer: start running this task now
    }
    T await_resume() {
        if (handle_.promise().exception) {
            std::rethrow_exception(handle_.promise().exception);
        }
        return std::move(handle_.promise().value);
    }

    // Drives a root task to completion from non-coroutine code (main()).
    T run() {
        handle_.resume();
        if (handle_.promise().exception) {
            std::rethrow_exception(handle_.promise().exception);
        }
        return std::move(handle_.promise().value);
    }

private:
    std::coroutine_handle<promise_type> handle_;
};

// Two chained sub-tasks -- compute() co_awaits add_one() twice, exercising
// the symmetric-transfer path in FinalAwaiter both times.
Task<int> add_one(int x) {
    co_return x + 1;
}

Task<int> compute() {
    const int a = co_await add_one(10); // 11
    const int b = co_await add_one(a);  // 12
    co_return a + b;                    // 23
}

// ════════════════════════════════════════════════════════════════════════
// 3. HALO observation -- instrumented promise_type::operator new.
// ════════════════════════════════════════════════════════════════════════

struct FrameStats {
    std::uint64_t alloc_count = 0;
    std::uint64_t free_count = 0;
    std::size_t last_alloc_bytes = 0;
};

// ProbeTask<Tag> -- a minimal void-returning coroutine type whose
// promise_type overloads operator new/delete to record every coroutine
// frame allocation. Tag gives each instantiation (TinyTag, FatTag) its own
// independent static FrameStats, so the two probes below never share
// counters.
template <typename Tag>
class ProbeTask {
public:
    struct promise_type {
        inline static FrameStats stats{};

        static void* operator new(std::size_t sz) {
            stats.alloc_count += 1;
            stats.last_alloc_bytes = sz;
            return ::operator new(sz);
        }
        static void operator delete(void* p, std::size_t) noexcept {
            stats.free_count += 1;
            ::operator delete(p);
        }

        ProbeTask get_return_object() {
            return ProbeTask{std::coroutine_handle<promise_type>::from_promise(*this)};
        }
        std::suspend_always initial_suspend() noexcept { return {}; }
        std::suspend_always final_suspend() noexcept { return {}; }
        void return_void() noexcept {}
        void unhandled_exception() { std::terminate(); }
    };

    explicit ProbeTask(std::coroutine_handle<promise_type> h) : handle_(h) {}
    ProbeTask(ProbeTask&& other) noexcept : handle_(std::exchange(other.handle_, {})) {}
    ProbeTask(const ProbeTask&) = delete;
    ProbeTask& operator=(const ProbeTask&) = delete;
    ~ProbeTask() {
        if (handle_) {
            handle_.destroy();
        }
    }

    // Resumes until the coroutine reaches its final suspension point.
    void run() {
        while (!handle_.done()) {
            handle_.resume();
        }
    }

private:
    std::coroutine_handle<promise_type> handle_;
};

struct TinyTag {};
struct FatTag {};
using TinyProbe = ProbeTask<TinyTag>;
using FatProbe = ProbeTask<FatTag>;

constexpr std::size_t kFatBufferBytes = 4096;

// Nothing here is live across a suspension point (there is no internal
// co_await at all -- only the compiler-inserted initial/final suspends),
// so the compiler's liveness analysis owes this frame nothing beyond its
// fixed bookkeeping. Whether HALO additionally elides the allocation
// entirely depends on whether the toolchain can prove the frame doesn't
// outlive tiny_probe()'s caller -- see the key=value output.
TinyProbe tiny_probe() {
    co_return;
}

// A real internal co_await forces the compiler to keep `buffer` live
// across a genuine suspension point, so (unlike tiny_probe) this frame's
// size is NOT merely fixed bookkeeping -- it must be large enough to hold
// the buffer for as long as the coroutine is suspended.
FatProbe fat_probe() {
    std::array<unsigned char, kFatBufferBytes> buffer{};
    buffer[0] = 1;
    co_await std::suspend_always{};
    buffer[kFatBufferBytes - 1] = 2;
    // Touch both ends after resuming so neither write is dead code an
    // optimizer could remove, which would defeat the measurement.
    volatile unsigned char sink = static_cast<unsigned char>(buffer[0] + buffer[kFatBufferBytes - 1]);
    (void)sink;
    co_return;
}

std::string join_sequence(const std::vector<std::uint64_t>& values) {
    std::string out;
    for (std::size_t i = 0; i < values.size(); ++i) {
        if (i != 0) {
            out += ',';
        }
        out += fmt::format("{}", values[i]);
    }
    return out;
}

} // namespace

int main() {
    // 1. Generator: first 10 Fibonacci terms, consumed via range-for + break.
    std::vector<std::uint64_t> fib_values;
    {
        auto gen = fibonacci();
        int count = 0;
        for (auto value : gen) {
            fib_values.push_back(value);
            if (++count >= 10) {
                break; // destroys gen's coroutine suspended mid-co_yield
            }
        }
    }
    fmt::print("generator_sequence={}\n", join_sequence(fib_values));

    // 2. Task<T>: chained co_await through symmetric transfer.
    Task<int> task = compute();
    const int task_result = task.run();
    fmt::print("task_result={}\n", task_result);

    // 3. HALO observation -- informational, not asserted either way.
    TinyProbe tiny = tiny_probe();
    tiny.run();
    FatProbe fat = fat_probe();
    fat.run();

    fmt::print(
        "tiny_frame_allocs={} tiny_frame_bytes={}\n",
        TinyProbe::promise_type::stats.alloc_count,
        TinyProbe::promise_type::stats.last_alloc_bytes);
    fmt::print(
        "fat_frame_allocs={} fat_frame_bytes={} fat_buffer_bytes={}\n",
        FatProbe::promise_type::stats.alloc_count,
        FatProbe::promise_type::stats.last_alloc_bytes,
        kFatBufferBytes);

    return 0;
}
