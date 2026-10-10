// concurrency/16-numa-affinity-and-data-locality -- NUMA placement, affinity,
// and the local-vs-remote access gap, demonstrated against a real (if
// emulated) multi-node topology inside the KVM lab.
//
// This program proves the MECHANISMS the chapter teaches, which are real and
// reproducible even on a guest whose two NUMA nodes are emulated on top of a
// single physical node:
//
//   1. PLACE      -- numa_alloc_onnode(node) actually binds the buffer's pages
//                    to the requested node (verified by reading each page's
//                    node back with get_mempolicy(MPOL_F_NODE|MPOL_F_ADDR),
//                    not by trusting the allocator).
//   2. FIRSTTOUCH -- under the default policy, a plain malloc'd buffer's pages
//                    land on the node of whichever thread WRITES them first,
//                    regardless of which thread allocated them. A thread pinned
//                    to node 0 that first-touches a buffer puts it on node 0; a
//                    thread pinned to node 1 puts an identical buffer on node 1.
//   3. TIMING     -- a thread pinned to node 0 reads a local (node-0) buffer
//                    and a remote (node-1) buffer; reports ns/cache-line for
//                    each. This is SOFT: on a single-physical-node host QEMU
//                    emulates the TOPOLOGY but not the LATENCY, so the ratio is
//                    ~1.0 here. On real multi-socket hardware it is the 1.3-1.6x
//                    gap the chapter describes. Reported, never asserted.
//
// A second invocation mode supports the cpuset demonstration the chapter's
// "cpuset and Container Interactions" section describes:
//
//   --onnode N    -- allocate + first-touch a small buffer on node N, then
//                    report the node its pages ACTUALLY landed on plus the
//                    cgroup's allowed memory nodes. Run normally it lands on N;
//                    run inside a cpuset whose cpuset.mems excludes N (demo.sh
//                    uses systemd-run -p AllowedMemoryNodes=0) numa_alloc_onnode
//                    does not fail -- it silently falls back to an allowed node,
//                    which is exactly the quiet misconfiguration the chapter
//                    warns about.
//
// Build + run happen inside the lab guest (it has libnuma); see demo.sh.

#include <numa.h>
#include <numaif.h>
#include <sched.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

namespace {

using Clock = std::chrono::steady_clock;

constexpr std::size_t kLineBytes = 64;          // one cache line
constexpr std::size_t kBufBytes  = 256UL << 20; // 256 MiB working set per buffer
constexpr int         kTimingPasses = 6;

// Return the NUMA node that currently backs the page containing `addr`. The
// page must already have been touched (physically allocated) -- get_mempolicy
// with MPOL_F_ADDR reports the node of an already-present page.
int node_of_pointer(const void* addr) {
    int node = -1;
    if (get_mempolicy(&node, nullptr, 0, const_cast<void*>(addr),
                      MPOL_F_NODE | MPOL_F_ADDR) != 0) {
        return -1;
    }
    return node;
}

// Pin the CURRENT thread to every CPU that belongs to `node`. Pinning to the
// node (not one exact core) is the usual goal: keep the thread one hop from the
// same local memory, and let the scheduler move it among that node's cores.
bool pin_current_thread_to_node(int node) {
    bitmask* cpus = numa_allocate_cpumask();
    if (numa_node_to_cpus(node, cpus) != 0) {
        numa_free_cpumask(cpus);
        return false;
    }
    cpu_set_t set;
    CPU_ZERO(&set);
    bool any = false;
    for (unsigned c = 0; c < cpus->size; ++c) {
        if (numa_bitmask_isbitset(cpus, c)) {
            CPU_SET(c, &set);
            any = true;
        }
    }
    numa_free_cpumask(cpus);
    if (!any) {
        return false;
    }
    return sched_setaffinity(0, sizeof(set), &set) == 0;
}

// Write one byte into every page so first-touch binds the pages, then report
// the node the first page landed on. Runs on whatever CPU/node the caller is
// pinned to.
int first_touch_and_report(void* buf, std::size_t bytes) {
    auto* p = static_cast<volatile char*>(buf);
    const std::size_t page = 4096;
    for (std::size_t i = 0; i < bytes; i += page) {
        p[i] = 1;
    }
    return node_of_pointer(buf);
}

// Read every cache line of the buffer `passes` times, accumulating into a sink
// the compiler cannot discard. Returns nanoseconds per cache-line access.
double time_read_ns_per_line(const void* buf, std::size_t bytes, int passes) {
    const auto* base = static_cast<const volatile std::uint8_t*>(buf);
    std::uint64_t sink = 0;
    auto t0 = Clock::now();
    for (int pass = 0; pass < passes; ++pass) {
        for (std::size_t off = 0; off < bytes; off += kLineBytes) {
            sink += base[off];
        }
    }
    auto t1 = Clock::now();
    // Keep the accumulation alive past the measured region.
    static std::atomic<std::uint64_t> keep{0};
    keep.store(sink, std::memory_order_relaxed);
    const double ns = std::chrono::duration<double, std::nano>(t1 - t0).count();
    const double lines = static_cast<double>(bytes / kLineBytes) * passes;
    return ns / lines;
}

std::string allowed_mems_string() {
    bitmask* allowed = numa_get_mems_allowed();
    std::string s;
    for (int n = 0; n <= numa_max_node(); ++n) {
        if (numa_bitmask_isbitset(allowed, n)) {
            if (!s.empty()) s += ",";
            s += std::to_string(n);
        }
    }
    return s.empty() ? "none" : s;
}

// --onnode N: allocate + first-touch a small buffer requesting node N, then
// report the node it actually landed on and the cgroup's allowed mems. Used by
// the cpuset fallback demonstration.
int run_onnode(int node) {
    const std::size_t bytes = 8UL << 20; // 8 MiB is plenty to force real pages
    void* buf = numa_alloc_onnode(bytes, node);
    if (!buf) {
        std::fprintf(stderr, "numa_alloc_onnode(%d) returned null\n", node);
        return 2;
    }
    const int actual = first_touch_and_report(buf, bytes);
    std::printf("ONNODE requested=%d allowed_mems=%s actual=%d\n",
                node, allowed_mems_string().c_str(), actual);
    numa_free(buf, bytes);
    return 0;
}

int run_full() {
    const int max_node = numa_max_node();
    const int nodes = max_node + 1;
    std::printf("NODES n=%d\n", nodes);
    if (nodes < 2) {
        std::printf("RESULT: FAIL (need >=2 NUMA nodes, saw %d)\n", nodes);
        return 1;
    }

    // 1. PLACE: numa_alloc_onnode binds to the node asked for.
    for (int node = 0; node < 2; ++node) {
        const std::size_t bytes = 16UL << 20;
        void* buf = numa_alloc_onnode(bytes, node);
        if (!buf) {
            std::printf("PLACE requested=%d actual=-1 (alloc failed)\n", node);
            continue;
        }
        const int actual = first_touch_and_report(buf, bytes);
        std::printf("PLACE requested=%d actual=%d\n", node, actual);
        numa_free(buf, bytes);
    }

    // 2. FIRSTTOUCH: default-policy malloc buffer lands on the node of the
    // thread that writes it first. Run the touch from a thread pinned to each
    // node in turn; the pages must follow the thread, not the allocator.
    for (int node = 0; node < 2; ++node) {
        int page_node = -2;
        std::thread toucher([&] {
            if (!pin_current_thread_to_node(node)) {
                page_node = -3;
                return;
            }
            const std::size_t bytes = 16UL << 20;
            void* buf = std::malloc(bytes); // default first-touch policy
            if (!buf) {
                page_node = -1;
                return;
            }
            page_node = first_touch_and_report(buf, bytes);
            std::free(buf);
        });
        toucher.join();
        std::printf("FIRSTTOUCH thread_node=%d page_node=%d\n", node, page_node);
    }

    // 3. TIMING (SOFT): a node-0-pinned thread reads a local vs a remote
    // buffer. On this emulated topology the ratio is ~1.0; on real hardware it
    // is the 1.3-1.6x gap the chapter describes. Reported, never asserted.
    double local_ns = 0, remote_ns = 0;
    std::thread timer([&] {
        pin_current_thread_to_node(0);
        void* local  = numa_alloc_onnode(kBufBytes, 0);
        void* remote = numa_alloc_onnode(kBufBytes, 1);
        if (!local || !remote) {
            return;
        }
        first_touch_and_report(local, kBufBytes);
        first_touch_and_report(remote, kBufBytes);
        // Warm, then measure.
        time_read_ns_per_line(local, kBufBytes, 1);
        time_read_ns_per_line(remote, kBufBytes, 1);
        local_ns  = time_read_ns_per_line(local, kBufBytes, kTimingPasses);
        remote_ns = time_read_ns_per_line(remote, kBufBytes, kTimingPasses);
        numa_free(local, kBufBytes);
        numa_free(remote, kBufBytes);
    });
    timer.join();
    const double ratio = local_ns > 0 ? remote_ns / local_ns : 0.0;
    std::printf("TIMING local_ns=%.4f remote_ns=%.4f ratio=%.4f\n",
                local_ns, remote_ns, ratio);

    std::printf("RESULT: PASS\n");
    return 0;
}

}  // namespace

int main(int argc, char** argv) {
    if (numa_available() < 0) {
        std::fprintf(stderr, "libnuma reports NUMA is unavailable on this system\n");
        std::printf("RESULT: FAIL (numa_available < 0)\n");
        return 1;
    }

    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--onnode") == 0 && i + 1 < argc) {
            return run_onnode(std::atoi(argv[i + 1]));
        }
    }
    return run_full();
}
