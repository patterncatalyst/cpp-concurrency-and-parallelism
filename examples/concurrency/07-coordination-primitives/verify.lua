#!/usr/bin/env lua5.4
-- concurrency/07-coordination-primitives — verify.lua
--
-- Plain Lua 5.4, no external modules, run inside the demo's container
-- against the binary that same image built (the project's verify.lua
-- convention -- see examples/concurrency/20-mechanical-sympathy/verify.lua
-- for the reference).
--
-- This example has no inherent timing noise -- a std::barrier's completion
-- function is a standard-guaranteed exactly-once-per-phase callback, not a
-- scheduling race -- so everything here is a HARD assertion:
--
--   1. The final merged total matches the closed-form expected sum.
--      Worker `id`'s contribution in phase `p` (both zero-indexed) is
--      (p+1)*(id+1), so the expected total is
--        (phases*(phases+1)/2) * (workers*(workers+1)/2).
--   2. stdout shows exactly one "completion" line per phase: every phase
--      number from 0 to phases-1 appears exactly once (never zero, never
--      more than once) -- proving the barrier's completion function ran
--      precisely as the standard guarantees, not zero times (a hung
--      phase) and not more than once (a broken barrier implementation or
--      a race in this program).

local BIN = os.getenv("BARRIER_WORKERS_BIN") or "/usr/local/bin/barrier_workers"
local WORKERS = tonumber(os.getenv("BARRIER_WORKERS_COUNT") or "4")
local PHASES = tonumber(os.getenv("BARRIER_WORKERS_PHASES") or "5")

local function run()
    local cmd = string.format("%s -w %d -p %d", BIN, WORKERS, PHASES)
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

print(string.format(
    "== verify.lua: 07-coordination-primitives -- workers=%d, phases=%d ==",
    WORKERS, PHASES))

local hard_failures = 0

local ok, output = pcall(run)
if not ok then
    print("  FAIL: barrier_workers errored: " .. tostring(output))
    print("RESULT: FAIL (1 execution failure)")
    os.exit(1)
end

print("  --- program output ---")
for line in output:gmatch("[^\n]+") do
    print("    " .. line)
end

-- 1. Exactly-once-per-phase completion-function invocation.
local phase_seen_count = {}
for p = 0, PHASES - 1 do
    phase_seen_count[p] = 0
end
for phase_str in output:gmatch("phase=(%d+) completion") do
    local phase = tonumber(phase_str)
    phase_seen_count[phase] = (phase_seen_count[phase] or 0) + 1
end

for p = 0, PHASES - 1 do
    local seen = phase_seen_count[p] or 0
    if seen == 0 then
        print(string.format("  FAIL: phase=%d never ran its completion function", p))
        hard_failures = hard_failures + 1
    elseif seen > 1 then
        print(string.format(
            "  FAIL: phase=%d ran its completion function %d times (expected exactly 1)",
            p, seen))
        hard_failures = hard_failures + 1
    end
end

if hard_failures == 0 then
    print(string.format(
        "  completion invocations: PASS (exactly one per phase, phases 0..%d)",
        PHASES - 1))
end

-- 2. The final merged total matches the closed-form expected sum.
local final_total = tonumber(output:match("final_total=(%d+)"))
local reported_workers = tonumber(output:match("workers=(%d+)"))
local reported_phases = tonumber(output:match("phases=(%d+)"))

if not final_total then
    print("  FAIL: could not parse final_total from program output")
    hard_failures = hard_failures + 1
else
    local expected_total =
        (PHASES * (PHASES + 1) // 2) * (WORKERS * (WORKERS + 1) // 2)
    print(string.format(
        "  final_total=%d expected=%d (closed form: phases*(phases+1)/2 * workers*(workers+1)/2)",
        final_total, expected_total))
    if final_total ~= expected_total then
        print(string.format(
            "  FAIL: final_total=%d does not match expected=%d", final_total, expected_total))
        hard_failures = hard_failures + 1
    else
        print("  final_total: PASS (matches the closed-form expected sum)")
    end
end

if reported_workers and reported_workers ~= WORKERS then
    print(string.format(
        "  FAIL: program reported workers=%d, expected %d", reported_workers, WORKERS))
    hard_failures = hard_failures + 1
end
if reported_phases and reported_phases ~= PHASES then
    print(string.format(
        "  FAIL: program reported phases=%d, expected %d", reported_phases, PHASES))
    hard_failures = hard_failures + 1
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
