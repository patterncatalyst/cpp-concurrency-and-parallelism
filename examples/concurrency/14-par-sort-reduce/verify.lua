#!/usr/bin/env lua5.4
-- concurrency/14-par-sort-reduce — verify.lua
--
-- Plain Lua 5.4, no external modules, run once inside the demo's container
-- against the binary that same image just built (this project's assertion
-- harness convention — see 20-mechanical-sympathy/verify.lua for the
-- original statement of it).
--
-- par_sort_reduce prints one num_available_cpus= header line, then one
-- policy=... line per execution policy (seq, par, par_unseq) with a
-- sort_hash, a reduce_sum, and distinct_cpus. What this harness checks:
--
--   correctness (HARD) -- sort_hash and reduce_sum must be IDENTICAL across
--     seq/par/par_unseq within a trial, and identical across trials too
--     (the input is generated from a fixed seed, so a correct, deterministic
--     program must reproduce the same hash/sum every run). Sorting and
--     reducing are correctness operations; the execution policy changes how
--     the work is scheduled, never what the answer is.
--   CPU usage (SOFT) -- the par policy's distinct_cpus should exceed 1 in at
--     least one trial, when the container's own cpuset actually offers 2+
--     CPUs (num_available_cpus>=2). This is checked as a soft signal, not a
--     hard requirement: the standard PERMITS std::execution::par to run its
--     callable from multiple threads, but doesn't require a parallel STL
--     implementation to split any specific workload across more than one --
--     a correct oneTBB-backed libstdc++ build may still choose not to for a
--     given size/shape, and a busy shared host can mute the signal even when
--     it would otherwise show up. No speedup ratio is asserted anywhere in
--     this file -- sort_ms/reduce_ms are reported for context only.
--
-- Exits 0 on pass (WARN allowed inside a pass). Exits non-zero, printing a
-- line starting "FAIL"/"RESULT: FAIL", on any hard failure: binary missing,
-- output unparseable, or a hash/sum that doesn't match across policies or
-- trials.

local BIN = os.getenv("PAR_SORT_REDUCE_BIN") or "/usr/local/bin/par_sort_reduce"
local TRIALS = tonumber(os.getenv("PAR_SORT_REDUCE_TRIALS") or "3")
local N = tonumber(os.getenv("PAR_SORT_REDUCE_N") or "2000000")
local W = tonumber(os.getenv("PAR_SORT_REDUCE_W") or "30")

local POLICIES = { "seq", "par", "par_unseq" }

local function run_once()
    local cmd = string.format("%s -n %d -w %d", BIN, N, W)
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

    local num_cpus = tonumber(output:match("num_available_cpus=(%d+)"))
    if not num_cpus then
        error("could not parse num_available_cpus from output:\n" .. output)
    end

    local policies = {}
    for policy, sort_ms, sort_hash, reduce_ms, reduce_sum, distinct_cpus in
        output:gmatch(
            "policy=([%a_]+)%s+sort_ms=([%d%.]+) sort_hash=(%x+) reduce_ms=([%d%.]+) " ..
            "reduce_sum=(%d+) distinct_cpus=(%d+)") do
        policies[policy] = {
            sort_ms = tonumber(sort_ms),
            sort_hash = sort_hash,
            reduce_ms = tonumber(reduce_ms),
            reduce_sum = tonumber(reduce_sum),
            distinct_cpus = tonumber(distinct_cpus),
        }
    end

    for _, name in ipairs(POLICIES) do
        if not policies[name] then
            error("could not parse policy=" .. name .. " line from output:\n" .. output)
        end
    end

    return num_cpus, policies
end

print(string.format(
    "== verify.lua: 14-par-sort-reduce -- n=%d w=%d trials=%d ==", N, W, TRIALS))

local hard_failures = 0
local min_num_cpus = math.huge
local saw_par_multi_cpu = false
local reference_hash, reference_sum

for trial = 1, TRIALS do
    local ok, num_cpus, policies = pcall(run_once)
    if not ok then
        print("  FAIL: trial " .. trial .. " errored: " .. tostring(num_cpus))
        hard_failures = hard_failures + 1
    else
        min_num_cpus = math.min(min_num_cpus, num_cpus)
        print(string.format("  [trial %d] num_available_cpus=%d", trial, num_cpus))
        for _, name in ipairs(POLICIES) do
            local p = policies[name]
            print(string.format(
                "    policy=%-9s sort_ms=%8.3f sort_hash=%s reduce_ms=%8.3f " ..
                "reduce_sum=%d distinct_cpus=%d",
                name, p.sort_ms, p.sort_hash, p.reduce_ms, p.reduce_sum, p.distinct_cpus))
        end

        -- Hard: every policy within this trial must agree exactly with seq.
        local seq = policies.seq
        for _, name in ipairs({ "par", "par_unseq" }) do
            local p = policies[name]
            if p.sort_hash ~= seq.sort_hash then
                print(string.format(
                    "  FAIL: trial %d %s sort_hash=%s differs from seq sort_hash=%s",
                    trial, name, p.sort_hash, seq.sort_hash))
                hard_failures = hard_failures + 1
            end
            if p.reduce_sum ~= seq.reduce_sum then
                print(string.format(
                    "  FAIL: trial %d %s reduce_sum=%d differs from seq reduce_sum=%d",
                    trial, name, p.reduce_sum, seq.reduce_sum))
                hard_failures = hard_failures + 1
            end
        end

        -- Hard: deterministic across trials too (fixed seed, fixed n/w).
        if reference_hash == nil then
            reference_hash = seq.sort_hash
            reference_sum = seq.reduce_sum
        else
            if seq.sort_hash ~= reference_hash then
                print(string.format(
                    "  FAIL: trial %d sort_hash=%s differs from trial 1's %s " ..
                    "(expected deterministic for a fixed seed/n/w)",
                    trial, seq.sort_hash, reference_hash))
                hard_failures = hard_failures + 1
            end
            if seq.reduce_sum ~= reference_sum then
                print(string.format(
                    "  FAIL: trial %d reduce_sum=%d differs from trial 1's %d",
                    trial, seq.reduce_sum, reference_sum))
                hard_failures = hard_failures + 1
            end
        end

        if policies.par.distinct_cpus > 1 then
            saw_par_multi_cpu = true
        end
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness failure(s))", hard_failures))
    os.exit(1)
end

print("  correctness: PASS (seq/par/par_unseq agree exactly, every trial)")

if min_num_cpus >= 2 then
    if saw_par_multi_cpu then
        print(string.format(
            "  cpu usage: PASS (par touched more than 1 of the %d available CPUs " ..
            "in at least one of %d trials)",
            min_num_cpus, TRIALS))
    else
        print(string.format(
            "  cpu usage: WARN (par never touched more than 1 of the %d available " ..
            "CPUs in %d trials. Correctness still holds -- the standard permits, but " ..
            "does not require, a parallel STL implementation to split this workload " ..
            "across more than one thread; libstdc++'s PSTL-over-TBB backend may have " ..
            "judged this n/w combination not worth splitting, or a busy shared host " ..
            "kept it on one core.)",
            min_num_cpus, TRIALS))
    end
else
    print(string.format(
        "  cpu usage: WARN (this container's cpuset offers only %d CPU -- " ..
        "distinct_cpus>1 is not physically achievable here regardless of how " ..
        "correct the code is. Re-run with a higher `docker run --cpus` to see the " ..
        "real signal.)",
        min_num_cpus))
end

print("RESULT: PASS")
os.exit(0)
