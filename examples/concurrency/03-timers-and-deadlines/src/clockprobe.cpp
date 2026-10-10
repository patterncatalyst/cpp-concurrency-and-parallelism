// concurrency/03-timers-and-deadlines — clockprobe.
//
// Doc 3's vDSO section: `clock_gettime(CLOCK_MONOTONIC, ...)` -- what
// `steady_clock::now()` calls underneath -- is a vDSO read, not a syscall,
// so repeated reads produce zero `clock_gettime` lines under `strace -e
// trace=clock_gettime`. Sleeping is the opposite: the kernel has to take the
// thread off the run queue, so `nanosleep`/`clock_nanosleep` DO show up.
//
// This program is the proof-of-absence half of that claim: it reads
// steady_clock::now() a few thousand times (accumulating the readings into a
// sum so the optimizer can't delete the loop), then makes exactly one
// `std::this_thread::sleep_for` call. Trace it from the host (strace is not
// expected to be present inside the minimal runtime image -- see verify.lua
// and the Containerfile comment) with:
//
//   strace -e trace=clock_gettime,nanosleep,clock_nanosleep ./clockprobe
//
// and the clock_gettime line count should be exactly zero while a
// nanosleep/clock_nanosleep line appears for the one sleep_for call.

#include <chrono>
#include <cstdio>
#include <thread>

int main() {
    constexpr int kReads = 5000;
    long long sum = 0;
    for (int i = 0; i < kReads; ++i) {
        // Each of these is a clock_gettime(CLOCK_MONOTONIC, ...) call under
        // the hood -- a vDSO read, no syscall, no context switch.
        sum += std::chrono::steady_clock::now().time_since_epoch().count();
    }
    std::printf("clockprobe: reads=%d checksum_nonzero=%d\n", kReads, sum != 0 ? 1 : 0);

    // Sleeping, unlike reading the clock, really does trap into the kernel:
    // the thread has to come off the run queue and be scheduled back on at
    // wakeup. This is the one syscall-producing call in this program.
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    std::printf("clockprobe: slept_ms=5\n");

    return 0;
}
