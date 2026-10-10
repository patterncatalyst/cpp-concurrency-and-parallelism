#!/usr/bin/env lua5.4
-- concurrency/02-machine-underneath — verify.lua
--
-- Same assertion-harness contract as the rest of the project (see
-- 20-mechanical-sympathy/verify.lua for the canonical statement of it):
-- plain Lua 5.4, no required arguments, env vars for overrides, a
-- readable running summary, exit 0 on pass (a WARN may still pass),
-- non-zero on any hard failure.
--
-- What this example checks:
--   1. The cache_latency binary runs and prints one parseable line per
--      working-set step, in increasing size order (hard -- a parse
--      failure or a missing step means the demo itself is broken).
--   2. Latency is monotonically non-decreasing across the cache-size
--      steps (hard). Doc 02's whole point is that a bigger working set
--      can only match or lose to a smaller one, never beat it: once a
--      step no longer fits in a given cache level, the hit rate against
--      that level can only get worse as the working set keeps growing,
--      never better. A decrease here would mean either a measurement bug
--      or a hardware/virtualization surprise worth knowing about, so it
--      fails loudly rather than averaging over it.
--   3. The exact ns/access values and the step-to-step speed ratios are
--      SOFT/informational: they depend on the host's real cache sizes
--      and clock, which this harness has no way to know in advance, and
--      are printed for a human to read rather than compared to a
--      hard-coded expectation.

local BIN = os.getenv("CACHE_LATENCY_BIN") or "/usr/local/bin/cache_latency"
local TRIALS = os.getenv("CACHE_LATENCY_TRIALS") or "3"
local ACCESSES = os.getenv("CACHE_LATENCY_ACCESSES")

local function run()
    local cmd = string.format("%s --trials %s", BIN, TRIALS)
    if ACCESSES then
        cmd = cmd .. string.format(" --accesses %s", ACCESSES)
    end
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

print("== verify.lua: 02-machine-underneath (cache-hierarchy latency) ==")

local ok, output = pcall(run)
if not ok then
    print("FAIL: cache_latency errored: " .. tostring(output))
    print("RESULT: FAIL")
    os.exit(1)
end

-- Parse every "step=... label=... size_kib=... ... ns_per_access=..." line,
-- in the order the binary printed them (which is increasing size order by
-- construction -- see kSteps in cache_latency.cpp).
local steps = {}
for line in output:gmatch("[^\r\n]+") do
    local step = line:match("step=(%d+)")
    local label = line:match("label=(%S+)")
    local size_kib = line:match("size_kib=(%d+)")
    local ns = line:match("ns_per_access=([%d%.]+)")
    if step and label and size_kib and ns then
        table.insert(steps, {
            step = tonumber(step),
            label = label,
            size_kib = tonumber(size_kib),
            ns_per_access = tonumber(ns),
        })
        print(string.format(
            "  [step %s] label=%-6s size_kib=%-8d ns_per_access=%.3f",
            step, label, tonumber(size_kib), tonumber(ns)))
    end
end

if #steps == 0 then
    print("RESULT: FAIL (no parseable step lines in cache_latency output)")
    print("--- raw output ---")
    print(output)
    os.exit(1)
end

local EXPECTED_STEPS = 5
if #steps ~= EXPECTED_STEPS then
    print(string.format(
        "RESULT: FAIL (expected %d step lines, parsed %d)",
        EXPECTED_STEPS, #steps))
    os.exit(1)
end

-- 1. Correctness -- every step parsed, sizes strictly increasing (sanity
-- check on the binary's own step table, not something that can drift at
-- runtime, but cheap to confirm).
local hard_failures = 0
for i = 2, #steps do
    if steps[i].size_kib <= steps[i - 1].size_kib then
        print(string.format(
            "  FAIL: step %d size_kib=%d did not increase over step %d size_kib=%d",
            steps[i].step, steps[i].size_kib, steps[i - 1].step, steps[i - 1].size_kib))
        hard_failures = hard_failures + 1
    end
end

-- 2. The hard claim: latency is monotonically non-decreasing across the
-- cache-size steps. A bigger working set is never faster than a smaller
-- one -- see the file header for why that's a property of the hardware,
-- not an artifact of this particular measurement.
for i = 2, #steps do
    local prev, cur = steps[i - 1], steps[i]
    if cur.ns_per_access < prev.ns_per_access then
        print(string.format(
            "  FAIL: latency decreased from step %d (%s, %.3f ns) to step %d (%s, %.3f ns) -- " ..
            "a bigger working set must never be faster",
            prev.step, prev.label, prev.ns_per_access,
            cur.step, cur.label, cur.ns_per_access))
        hard_failures = hard_failures + 1
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d failure(s))", hard_failures))
    os.exit(1)
end

print("  monotonicity: PASS (latency never decreased as the working set grew)")

-- SOFT/informational: the absolute ns values and how much slower DRAM is
-- than L1 on this machine. No assertion here -- it depends entirely on
-- the host's real hardware, which this harness doesn't assume in advance.
local first, last = steps[1], steps[#steps]
if first.ns_per_access > 0 then
    local ratio = last.ns_per_access / first.ns_per_access
    print(string.format(
        "  info: %s (%d KiB) = %.3f ns/access, %s (%d KiB) = %.3f ns/access (%.1fx slower)",
        first.label, first.size_kib, first.ns_per_access,
        last.label, last.size_kib, last.ns_per_access, ratio))
end

print("RESULT: PASS")
os.exit(0)
