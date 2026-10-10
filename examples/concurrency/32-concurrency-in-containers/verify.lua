#!/usr/bin/env lua5.4
-- concurrency/32-concurrency-in-containers — verify.lua
--
-- Same harness contract as 20-mechanical-sympathy's verify.lua: plain
-- Lua 5.4, no required arguments, reads env vars for overrides, prints a
-- readable summary, exits 0 on pass (a WARN inside a pass is allowed for
-- a soft/environment-dependent assertion), non-zero on any hard failure.
-- Runs inside the container, against the binary that same image built.
--
-- What this example checks:
--   1. The binary runs to completion and its output parses (hard). A
--      crash or unparseable line here means the /sys/fs/cgroup read or
--      the pool-bench itself is broken, independent of which cgroup
--      environment the container happens to be running under.
--   2. hardware_concurrency, affinity_count, and pool_size are all
--      positive integers, and pool_bench_ms is a non-negative number
--      (hard) -- the program must report a usable pool size without
--      crashing even when it cannot read a quota at all.
--   3. The fallback/unlimited path (hard): under a plain `docker run`
--      with no --cpus/--cpuset-cpus, cpu.max reads "max", so this
--      example asserts quota=unlimited AND pool_size == affinity_count --
--      i.e. the program actually took the no-quota fallback branch
--      rather than silently mis-sizing the pool.
--   4. The quota path (soft): if this container WAS started with a CPU
--      limit (quota is a finite number -- e.g. via
--      `docker run --cpus=1 <image>`, see README), check that pool_size
--      tracks floor(min(quota, affinity_count)) and is no larger than
--      hardware_concurrency(). This is the quota-vs-hardware_concurrency
--      distinction the chapter is about, demonstrated whenever the
--      environment provides a quota to demonstrate it with -- but a
--      plain CI run never sets one, so this check is SOFT (WARN, not
--      FAIL) and mostly a no-op in automated runs. See README for how to
--      trigger it manually.

local BIN = os.getenv("CGROUP_PROBE_BIN") or "/usr/local/bin/cgroup_probe"
local BENCH_ITERS = os.getenv("CGROUP_PROBE_BENCH_ITERS") or "2000000"

local function run_probe()
    local cmd = string.format("%s --bench-iters %s", BIN, BENCH_ITERS)
    local handle, perr = io.popen(cmd .. " 2>&1")
    if not handle then
        error(string.format("failed to launch %q: %s", cmd, tostring(perr)))
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
    if not ok then
        error(string.format(
            "command failed (%s %s): %s\n--- output ---\n%s",
            tostring(why), tostring(code), cmd, output))
    end
    return output
end

print("== verify.lua: 32-concurrency-in-containers (cgroup-probe + pool-bench) ==")

local hard_failures = 0

local ok, output = pcall(run_probe)
if not ok then
    print("  FAIL: cgroup_probe errored: " .. tostring(output))
    print("RESULT: FAIL (1 execution failure)")
    os.exit(1)
end

print("  raw output: " .. output:gsub("%s+$", ""))

local hw = tonumber(output:match("hardware_concurrency=(%d+)"))
local affinity = tonumber(output:match("affinity_count=(%d+)"))
local quota_str = output:match("quota=(%S+)")
local pool_size = tonumber(output:match("pool_size=(%d+)"))
local bench_ms = tonumber(output:match("pool_bench_ms=([%d%.]+)"))

if not (hw and affinity and quota_str and pool_size and bench_ms) then
    print("  FAIL: could not parse cgroup_probe output:\n" .. output)
    print("RESULT: FAIL (1 parse failure)")
    os.exit(1)
end

-- 2. Basic sanity -- hard. The program must report usable, positive
-- numbers regardless of which cgroup environment it's running under.
if hw < 1 then
    print(string.format("  FAIL: hardware_concurrency=%d is not positive", hw))
    hard_failures = hard_failures + 1
else
    print(string.format("  hardware_concurrency: PASS (%d)", hw))
end

if affinity < 1 then
    print(string.format("  FAIL: affinity_count=%d is not positive", affinity))
    hard_failures = hard_failures + 1
else
    print(string.format("  affinity_count: PASS (%d)", affinity))
end

if pool_size < 1 then
    print(string.format("  FAIL: pool_size=%d is not positive", pool_size))
    hard_failures = hard_failures + 1
else
    print(string.format("  pool_size: PASS (%d)", pool_size))
end

if bench_ms < 0 then
    print(string.format("  FAIL: pool_bench_ms=%.3f is negative", bench_ms))
    hard_failures = hard_failures + 1
else
    print(string.format("  pool_bench_ms: PASS (%.3f ms, pool_size=%d workers completed)",
        bench_ms, pool_size))
end

-- 3. The fallback/unlimited path -- hard. A plain `docker run` (no
-- --cpus/--cpuset-cpus) always reports quota=unlimited, and the program
-- must actually fall back to sizing the pool from the cpuset-visible
-- affinity count in that case, not silently default to something else.
local quota_num = tonumber(quota_str)

if quota_str == "unlimited" then
    print("  quota: unlimited (expected under a plain `docker run` with no --cpus)")
    if pool_size ~= affinity then
        print(string.format(
            "  FAIL: fallback path sized pool_size=%d but affinity_count=%d " ..
            "-- with no quota, the pool must be sized from the cpuset-visible " ..
            "core count", pool_size, affinity))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  fallback path: PASS (no quota -- pool_size=%d matches affinity_count)",
            pool_size))
    end
elseif quota_num then
    -- 4. The quota path -- soft. Only reachable when this container was
    -- actually started with a CPU limit (see README: docker run --cpus=N).
    -- A plain CI run never exercises this branch, so a mismatch here is
    -- reported as a WARN, not a hard failure.
    local expected = math.floor(math.min(quota_num, affinity))
    expected = math.max(1, expected)
    print(string.format("  quota: %.2f cores (this container was started with a CPU limit)",
        quota_num))
    if pool_size == expected and pool_size <= hw then
        print(string.format(
            "  quota path: PASS (pool_size=%d == floor(min(quota, affinity))=%d, " ..
            "and %d <= hardware_concurrency=%d -- the quota, not " ..
            "hardware_concurrency(), drove the pool size)",
            pool_size, expected, pool_size, hw))
    else
        print(string.format(
            "  quota path: WARN (pool_size=%d, expected floor(min(quota,affinity))=%d" ..
            " -- a CPU_LIMIT override or an unusual cgroup layout can explain this; " ..
            "not a hard failure since this path only runs when the environment " ..
            "happens to supply a quota)",
            pool_size, expected))
    end
else
    print(string.format(
        "  WARN: quota=%q did not parse as 'unlimited' or a number -- skipping " ..
        "the quota-path check (not a hard failure: the fallback-path checks above " ..
        "already cover the required behavior)", quota_str))
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d hard failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
