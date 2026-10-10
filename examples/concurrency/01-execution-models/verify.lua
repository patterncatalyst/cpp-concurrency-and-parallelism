#!/usr/bin/env lua5.4
-- concurrency/01-execution-models — verify.lua
--
-- Plain Lua 5.4, no external modules, run once inside the demo's container
-- against the binary that same image just built -- this project's assertion
-- harness convention (see 20-mechanical-sympathy/verify.lua for the
-- original statement of it).
--
-- execution_models prints one num_available_cpus= line, then one
-- model=... line per execution model with three counted observables:
-- distinct_cpus, max_inflight, interleaves. What this harness checks, per
-- Doc 1's EXAMPLE SPEC:
--
--   sequential          -- HARD: interleaves==0, distinct_cpus==1, and (a
--                           strengthening this harness adds, true by the
--                           same single-threaded construction) max_inflight==1.
--                           False sharing/scheduling noise cannot produce a
--                           different sign here: there is exactly one thread
--                           in the whole process while this model runs, and
--                           it is pinned to one CPU by the program itself.
--   concurrent_pinned   -- HARD: distinct_cpus==1 (every worker self-pins to
--                           the same cpu id) and max_inflight>1 (many
--                           jthreads really do overlap while pinned to it).
--   parallel / both     -- HARD *when the container actually has 2+ CPUs
--                           available* (num_available_cpus>=2): distinct_cpus
--                           must exceed 1 in at least one of several trials.
--                           If the container's own cpuset only offers one
--                           CPU, these two models cannot physically touch a
--                           second one regardless of how correct the code
--                           is -- that case is reported as a SOFT WARN, not
--                           a failure, exactly like 20-mechanical-sympathy's
--                           timing check is soft when the environment can't
--                           reproduce the signal cleanly.
--
-- Exits 0 on pass (WARN allowed inside a pass). Exits non-zero, printing a
-- line starting "FAIL"/"RESULT: FAIL", on any hard failure: binary missing,
-- output unparseable, or a count that doesn't match its required sign.

local BIN = os.getenv("EXECUTION_MODELS_BIN") or "/usr/local/bin/execution_models"
local TRIALS = tonumber(os.getenv("EXECUTION_MODELS_TRIALS") or "3")

local function run_once()
    local handle, perr = io.popen(BIN .. " 2>&1")
    if not handle then
        error(string.format("failed to launch %q: %s", BIN, tostring(perr)))
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
    if not ok then
        error(string.format(
            "command failed (%s %s): %s\n--- output ---\n%s",
            tostring(why), tostring(code), BIN, output))
    end

    local num_cpus = tonumber(output:match("num_available_cpus=(%d+)"))
    if not num_cpus then
        error("could not parse num_available_cpus from output:\n" .. output)
    end

    local models = {}
    for model, distinct_cpus, max_inflight, interleaves in
        output:gmatch("model=(%a+) distinct_cpus=(%d+) max_inflight=(%d+) interleaves=(%d+)") do
        models[model] = {
            distinct_cpus = tonumber(distinct_cpus),
            max_inflight = tonumber(max_inflight),
            interleaves = tonumber(interleaves),
        }
    end

    for _, name in ipairs({"sequential", "concurrent_pinned", "parallel", "both"}) do
        if not models[name] then
            error("could not parse model=" .. name .. " line from output:\n" .. output)
        end
    end

    return num_cpus, models
end

print(string.format(
    "== verify.lua: 01-execution-models -- trials=%d ==", TRIALS))

local hard_failures = 0
local min_num_cpus = math.huge
local saw_parallel_multi_cpu = false
local saw_both_multi_cpu = false
local last_parallel, last_both

for trial = 1, TRIALS do
    local ok, num_cpus, models = pcall(run_once)
    if not ok then
        print("  FAIL: trial " .. trial .. " errored: " .. tostring(num_cpus))
        hard_failures = hard_failures + 1
    else
        min_num_cpus = math.min(min_num_cpus, num_cpus)
        print(string.format("  [trial %d] num_available_cpus=%d", trial, num_cpus))
        for _, name in ipairs({"sequential", "concurrent_pinned", "parallel", "both"}) do
            local m = models[name]
            print(string.format(
                "    model=%-18s distinct_cpus=%d max_inflight=%d interleaves=%d",
                name, m.distinct_cpus, m.max_inflight, m.interleaves))
        end

        local seq = models.sequential
        if seq.distinct_cpus ~= 1 then
            print(string.format(
                "  FAIL: trial %d sequential distinct_cpus=%d (want 1 -- single " ..
                "thread, pinned, should never touch a second CPU)",
                trial, seq.distinct_cpus))
            hard_failures = hard_failures + 1
        end
        if seq.interleaves ~= 0 then
            print(string.format(
                "  FAIL: trial %d sequential interleaves=%d (want 0 -- no other " ..
                "thread exists to interleave with)",
                trial, seq.interleaves))
            hard_failures = hard_failures + 1
        end
        if seq.max_inflight ~= 1 then
            print(string.format(
                "  FAIL: trial %d sequential max_inflight=%d (want 1 -- only one " ..
                "task is ever in flight in a single-threaded loop)",
                trial, seq.max_inflight))
            hard_failures = hard_failures + 1
        end

        local cp = models.concurrent_pinned
        if cp.distinct_cpus ~= 1 then
            print(string.format(
                "  FAIL: trial %d concurrent_pinned distinct_cpus=%d (want 1 -- " ..
                "every worker self-pins to the same cpu id)",
                trial, cp.distinct_cpus))
            hard_failures = hard_failures + 1
        end
        if cp.max_inflight <= 1 then
            print(string.format(
                "  FAIL: trial %d concurrent_pinned max_inflight=%d (want >1 -- " ..
                "many jthreads pinned to one CPU should still overlap in time)",
                trial, cp.max_inflight))
            hard_failures = hard_failures + 1
        end

        last_parallel = models.parallel
        last_both = models.both
        if models.parallel.distinct_cpus > 1 then
            saw_parallel_multi_cpu = true
        end
        if models.both.distinct_cpus > 1 then
            saw_both_multi_cpu = true
        end
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness failure(s))", hard_failures))
    os.exit(1)
end

print("  sequential/concurrent_pinned: PASS on every trial (exact, environment-independent)")

-- parallel / both: distinct_cpus>1 is only physically achievable when the
-- container's own cpuset actually offers 2+ CPUs. When it does, require the
-- signal to show up in at least one trial (HARD); when it can't, say so and
-- WARN instead of failing a correct program for an environment limit.
if min_num_cpus >= 2 then
    local ok = true
    if not saw_parallel_multi_cpu then
        print(string.format(
            "  FAIL: parallel model never touched more than 1 CPU in %d trial(s) " ..
            "despite %d CPUs being available (last trial: distinct_cpus=%d)",
            TRIALS, min_num_cpus, last_parallel.distinct_cpus))
        hard_failures = hard_failures + 1
        ok = false
    end
    if not saw_both_multi_cpu then
        print(string.format(
            "  FAIL: both (oversubscribed) model never touched more than 1 CPU in " ..
            "%d trial(s) despite %d CPUs being available (last trial: distinct_cpus=%d)",
            TRIALS, min_num_cpus, last_both.distinct_cpus))
        hard_failures = hard_failures + 1
        ok = false
    end
    if ok then
        print(string.format(
            "  parallel/both: PASS (both touched more than 1 of the %d available " ..
            "CPUs in at least one of %d trials)",
            min_num_cpus, TRIALS))
    end
else
    print(string.format(
        "  parallel/both: WARN (this container's cpuset offers only %d CPU -- " ..
        "distinct_cpus>1 is not physically achievable here regardless of how " ..
        "correct the code is. Re-run without a single-CPU constraint, e.g. " ..
        "without `docker run --cpus=1`, to see the real signal.)",
        min_num_cpus))
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
