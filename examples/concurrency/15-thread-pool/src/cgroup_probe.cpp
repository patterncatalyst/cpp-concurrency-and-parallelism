// concurrency/15-thread-pool — cgroup-aware CPU-equivalent probe.
//
// std::thread::hardware_concurrency() reports the host's visible CPU
// topology (narrowed by cpuset, on a reasonably current glibc) but never
// reflects a cgroup CPU *quota* -- a pool sized off hardware_concurrency()
// alone inside a quota-limited container oversubscribes the budget it was
// actually given. This probe reads the quota directly and derives the
// CPU-equivalent count the kernel will actually schedule per period.
//
// Tries cgroup v2's unified `cpu.max` first: a single file holding
// "$QUOTA $PERIOD" in microseconds, or "max $PERIOD" when unlimited. Falls
// back to cgroup v1's split `cpu.cfs_quota_us` / `cpu.cfs_period_us` (a
// negative quota means unlimited there). If neither file is present at
// all -- a runtime without the cpu controller enabled, or a non-container
// environment -- reports that plainly rather than guessing.
//
// Usage: cgroup_probe
//
// Prints exactly one line, in key=value form:
//   source=cgroupv2 quota_us=200000 period_us=100000 cpu_equivalents=2 hardware_concurrency=64
//   source=cgroupv2 quota_us=-1 period_us=100000 cpu_equivalents=64 hardware_concurrency=64 note=unlimited_quota_fallback_to_hardware_concurrency
//   source=none quota_us=-1 period_us=-1 cpu_equivalents=64 hardware_concurrency=64 note=no_cgroup_cpu_controller_found

#include <cstdlib>
#include <fstream>
#include <optional>
#include <sstream>
#include <string>
#include <thread>

#include <fmt/core.h>

namespace {

struct Quota {
    std::string source;
    long long quota_us = -1; // -1 == unlimited
    long long period_us = -1;
    bool unlimited = false;
};

std::optional<std::string> read_file(const std::string& path) {
    std::ifstream f(path);
    if (!f) {
        return std::nullopt;
    }
    std::ostringstream ss;
    ss << f.rdbuf();
    std::string content = ss.str();
    if (content.empty()) {
        return std::nullopt;
    }
    return content;
}

std::optional<Quota> read_cgroup_v2() {
    auto content = read_file("/sys/fs/cgroup/cpu.max");
    if (!content) {
        return std::nullopt;
    }
    std::istringstream iss(*content);
    std::string quota_tok, period_tok;
    if (!(iss >> quota_tok >> period_tok)) {
        return std::nullopt;
    }
    Quota q;
    q.source = "cgroupv2";
    q.period_us = std::strtoll(period_tok.c_str(), nullptr, 10);
    if (quota_tok == "max") {
        q.unlimited = true;
        q.quota_us = -1;
    } else {
        q.quota_us = std::strtoll(quota_tok.c_str(), nullptr, 10);
    }
    return q;
}

std::optional<Quota> read_cgroup_v1() {
    auto quota_content = read_file("/sys/fs/cgroup/cpu/cpu.cfs_quota_us");
    auto period_content = read_file("/sys/fs/cgroup/cpu/cpu.cfs_period_us");
    if (!quota_content || !period_content) {
        return std::nullopt;
    }
    Quota q;
    q.source = "cgroupv1";
    q.quota_us = std::strtoll(quota_content->c_str(), nullptr, 10);
    q.period_us = std::strtoll(period_content->c_str(), nullptr, 10);
    q.unlimited = (q.quota_us < 0);
    return q;
}

} // namespace

int main() {
    unsigned hw = std::thread::hardware_concurrency();
    if (hw == 0) {
        // hardware_concurrency() is permitted by the standard to return 0
        // when it cannot determine the value; treat that as "unknown, but
        // at least 1" rather than dividing by it anywhere.
        hw = 1;
    }

    std::optional<Quota> q = read_cgroup_v2();
    if (!q) {
        q = read_cgroup_v1();
    }

    if (!q) {
        fmt::print(
            "source=none quota_us=-1 period_us=-1 cpu_equivalents={} hardware_concurrency={} "
            "note=no_cgroup_cpu_controller_found\n",
            hw, hw);
        return 0;
    }

    if (q->unlimited) {
        fmt::print(
            "source={} quota_us=-1 period_us={} cpu_equivalents={} hardware_concurrency={} "
            "note=unlimited_quota_fallback_to_hardware_concurrency\n",
            q->source, q->period_us, hw, hw);
        return 0;
    }

    long long cpu_equivalents = 1;
    if (q->period_us > 0) {
        cpu_equivalents = (q->quota_us + q->period_us - 1) / q->period_us; // ceil
        if (cpu_equivalents < 1) {
            cpu_equivalents = 1;
        }
    }

    fmt::print(
        "source={} quota_us={} period_us={} cpu_equivalents={} hardware_concurrency={}\n",
        q->source, q->quota_us, q->period_us, cpu_equivalents, hw);
    return 0;
}
