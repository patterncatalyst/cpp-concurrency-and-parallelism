#!/usr/bin/env lua5.4
-- concurrency/15-thread-pool — verify.lua
--
-- HARD: both pool kinds (single-queue, work-stealing) complete every
-- submitted task exactly once, at every worker count tested. This is
-- never a performance number -- it's "did the pool lose or duplicate
-- work," which must hold regardless of host noise.
--
-- SOFT: (a) the work-stealing pool's throughput should land close to the
-- single-queue pool's at a low worker count and should pull ahead once
-- the worker count passes roughly eight -- the chapter's central claim,
-- but it depends on this container actually having enough real cores for
-- the single queue's lock to become contended, so a host/CI runner with
-- too few cores gets a WARN, not a FAIL. (b) the cgroup probe's derived
-- CPU-equivalent count is reported for inspection; by default this demo
-- runs without a --cpus limit, so cpu.max reads "max" (or the controller
-- isn't present under some runtimes) and the probe correctly falls back
-- to hardware_concurrency() -- that fallback is the EXPECTED outcome of
-- an unconstrained run, not a failure. Setting EXPECTED_CPU_EQUIVALENTS
-- (e.g. when manually running this image with `docker run --cpus=2`)
-- turns the comparison into a reported check, but still only a WARN on
-- mismatch, per this example's SOFT contract for the cgroup/quota
-- observation.

local POOL_BIN = os.getenv("POOL_BENCH_BIN") or "/usr/local/bin/pool_bench"
local CGROUP_BIN = os.getenv("CGROUP_PROBE_BIN") or "/usr/local/bin/cgroup_probe"
local N_TASKS = tonumber(os.getenv("POOL_BENCH_TASKS") or "6000")
local WORK_ITERS = tonumber(os.getenv("POOL_BENCH_WORK_ITERS") or "4000")
local LOW_WORKERS = tonumber(os.getenv("POOL_BENCH_LOW_WORKERS") or "2")
local HIGH_WORKERS = tonumber(os.getenv("POOL_BENCH_HIGH_WORKERS") or "16")
local MARGIN_PCT = 15.0 -- how close counts as "close" at the low worker count

local function run(cmd)
    local handle, perr = io.popen(cmd .. " 2>&1")
    if not handle then
        error(string.format("failed to launch %q: %s", cmd, tostring(perr)))
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
    if not ok then
        error(string.format("command failed (%s %s): %s\n--- output ---\n%s",
            tostring(why), tostring(code), cmd, output))
    end
    return output
end

local function run_pool(kind, workers)
    local cmd = string.format("%s --kind %s --workers %d --tasks %d --work-iters %d",
        POOL_BIN, kind, workers, N_TASKS, WORK_ITERS)
    local output = run(cmd)
    local completed = tonumber(output:match("completed=(%d+)"))
    local throughput = tonumber(output:match("throughput_tasks_per_sec=([%d%.]+)"))
    local avg_wait = tonumber(output:match("avg_queue_wait_us=([%d%.]+)"))
    if not (completed and throughput and avg_wait) then
        error("could not parse pool_bench output:\n" .. output)
    end
    return completed, throughput, avg_wait
end

print(string.format(
    "== verify.lua: 15-thread-pool -- tasks=%d work_iters=%d low_workers=%d high_workers=%d ==",
    N_TASKS, WORK_ITERS, LOW_WORKERS, HIGH_WORKERS))

local hard_failures = 0
local function fail(msg)
    print("  FAIL: " .. msg)
    hard_failures = hard_failures + 1
end

local results = {}

for _, kind in ipairs({"single", "stealing"}) do
    for _, workers in ipairs({LOW_WORKERS, HIGH_WORKERS}) do
        local ok, a, b, c = pcall(run_pool, kind, workers)
        if not ok then
            fail(string.format("kind=%s workers=%d errored: %s", kind, workers, tostring(a)))
        else
            local completed, throughput, avg_wait = a, b, c
            print(string.format(
                "  [kind=%-8s workers=%2d] completed=%d throughput=%.1f/s avg_queue_wait_us=%.2f",
                kind, workers, completed, throughput, avg_wait))
            if completed ~= N_TASKS then
                fail(string.format(
                    "kind=%s workers=%d completed %d tasks, expected %d",
                    kind, workers, completed, N_TASKS))
            end
            results[kind .. "_" .. workers] = throughput
        end
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness/execution failure(s))", hard_failures))
    os.exit(1)
end

print("  correctness: PASS (every submitted task completed exactly once, both pool kinds, both worker counts)")

-- SOFT: throughput shape (close at low worker count, stealing ahead at high).
local single_low = results["single_" .. LOW_WORKERS]
local stealing_low = results["stealing_" .. LOW_WORKERS]
local single_high = results["single_" .. HIGH_WORKERS]
local stealing_high = results["stealing_" .. HIGH_WORKERS]

if single_low and stealing_low and single_high and stealing_high then
    local low_margin_pct = (stealing_low - single_low) / single_low * 100.0
    local high_margin_pct = (stealing_high - single_high) / single_high * 100.0

    print(string.format(
        "  low workers (%d): single=%.1f/s stealing=%.1f/s (stealing is %.1f%% %s)",
        LOW_WORKERS, single_low, stealing_low, math.abs(low_margin_pct),
        low_margin_pct >= 0 and "faster" or "slower"))
    print(string.format(
        "  high workers (%d): single=%.1f/s stealing=%.1f/s (stealing is %.1f%% %s)",
        HIGH_WORKERS, single_high, stealing_high, math.abs(high_margin_pct),
        high_margin_pct >= 0 and "faster" or "slower"))

    if math.abs(low_margin_pct) <= MARGIN_PCT and high_margin_pct > 0 then
        print(string.format(
            "  throughput shape: PASS (close at %d workers, stealing ahead at %d workers)",
            LOW_WORKERS, HIGH_WORKERS))
    else
        print(
            "  throughput shape: WARN (expected close-then-ahead shape did not clearly show -- " ..
            "single-queue lock contention needs enough real cores and worker threads genuinely " ..
            "fighting over the one queue's mutex to manifest; a container with too few cores, " ..
            "or a host busy enough to mask the pattern, can mute the signal without the work-" ..
            "stealing design being wrong. Correctness still holds (checked above).")
    end
else
    print("  throughput shape: WARN (missing samples, could not compare)")
end

-- SOFT: cgroup probe.
local cgroup_ok, cgroup_out = pcall(run, CGROUP_BIN)
if not cgroup_ok then
    print("  cgroup probe: WARN (could not run cgroup_probe: " .. tostring(cgroup_out) .. ")")
else
    print("  [cgroup_probe] " .. cgroup_out:gsub("%s+$", ""))
    local source = cgroup_out:match("source=(%S+)")
    local cpu_equivalents = tonumber(cgroup_out:match("cpu_equivalents=(%d+)"))
    local hw = tonumber(cgroup_out:match("hardware_concurrency=(%d+)"))
    if not (source and cpu_equivalents and hw) then
        print("  cgroup probe: WARN (could not parse cgroup_probe output)")
    elseif source == "none" then
        print(
            "  cgroup probe: WARN (no cgroup CPU controller found in this runtime -- falling " ..
            "back to hardware_concurrency(), which is the documented, correct fallback " ..
            "behavior for this probe, not a failure)")
    else
        local expected_raw = os.getenv("EXPECTED_CPU_EQUIVALENTS")
        local expected = expected_raw and tonumber(expected_raw) or nil
        if expected == nil then
            print(string.format(
                "  cgroup probe: INFO (no EXPECTED_CPU_EQUIVALENTS set; this run's quota yields " ..
                "cpu_equivalents=%d against hardware_concurrency=%d -- run with " ..
                "`docker run --cpus=N` plus EXPECTED_CPU_EQUIVALENTS=N to turn this into a " ..
                "checked comparison)",
                cpu_equivalents, hw))
        elseif cpu_equivalents == expected then
            print(string.format(
                "  cgroup probe: PASS (cpu_equivalents=%d matches EXPECTED_CPU_EQUIVALENTS=%d)",
                cpu_equivalents, expected))
        else
            print(string.format(
                "  cgroup probe: WARN (cpu_equivalents=%d does not match " ..
                "EXPECTED_CPU_EQUIVALENTS=%d -- re-check the --cpus value this container was " ..
                "actually run with)",
                cpu_equivalents, expected))
        end
    end
end

print("RESULT: PASS")
os.exit(0)
