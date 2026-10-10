#!/usr/bin/env lua5.4
-- concurrency/20-mechanical-sympathy — verify.lua
--
-- This is the project's assertion harness convention: plain Lua 5.4 (no
-- external modules), run once inside the demo's container against the
-- binary that same image just built. Contract every example's verify.lua
-- in this project follows:
--
--   * No required arguments. Reads FALSE_SHARING_BIN / _N / _TRIALS env
--     vars for overrides, with sane defaults otherwise.
--   * Prints a readable, line-oriented summary to stdout as it goes.
--   * Exits 0 on pass. A pass MAY include a WARN line for a soft
--     assertion (see the timing check below) -- WARN does not fail the
--     run, only a hard correctness/parse failure does.
--   * Exits non-zero (and prints a line starting "FAIL"/"RESULT: FAIL")
--     on any hard failure: binary missing, output unparseable, or a
--     count that doesn't match the expected value.
--
-- What this example checks:
--   1. Correctness is padding-independent: both counters must equal N
--      EXACTLY in both --pad on and --pad off, every trial. This is a
--      hard assertion -- false sharing is a performance bug, never a
--      correctness bug, and a failure here would mean the demo program
--      itself is broken.
--   2. False sharing is real: the padded run's average elapsed_ms should
--      be lower than the unpadded run's. This is checked as a SOFT
--      assertion (warn, don't fail, if the margin is within a noise
--      floor) because the comparison runs on whatever cores the host
--      happens to hand the container -- on a busy shared host, or one
--      without true core isolation, the two hot threads may land on
--      cores that don't reproduce real contention cleanly every time.

local BIN = os.getenv("FALSE_SHARING_BIN") or "/usr/local/bin/false_sharing"
local N = tonumber(os.getenv("FALSE_SHARING_N") or "20000000")
local TRIALS = tonumber(os.getenv("FALSE_SHARING_TRIALS") or "3")
local NOISE_THRESHOLD_PCT = 5.0 -- below this, call the timing result noise

local function run_once(mode)
    local cmd = string.format("%s --pad %s -n %d", BIN, mode, N)
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

    local count_a = tonumber(output:match("count_a=(%d+)"))
    local count_b = tonumber(output:match("count_b=(%d+)"))
    local elapsed = tonumber(output:match("elapsed_ms=([%d%.]+)"))
    if not (count_a and count_b and elapsed) then
        error("could not parse false_sharing output:\n" .. output)
    end
    return count_a, count_b, elapsed
end

local function average(values)
    local sum = 0
    for _, v in ipairs(values) do
        sum = sum + v
    end
    return sum / #values
end

print(string.format(
    "== verify.lua: 20-mechanical-sympathy (false sharing) -- N=%d, trials=%d ==",
    N, TRIALS))

local hard_failures = 0
local unpadded_times = {}
local padded_times = {}

-- 1. Correctness -- both modes, every trial, exact counts.
for trial = 1, TRIALS do
    local ok, count_a, count_b, elapsed = pcall(run_once, "off")
    if not ok then
        print("  FAIL: unpadded trial " .. trial .. " errored: " .. tostring(count_a))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  [unpadded trial %d] count_a=%d count_b=%d elapsed_ms=%.3f",
            trial, count_a, count_b, elapsed))
        if count_a ~= N or count_b ~= N then
            print(string.format(
                "  FAIL: unpadded trial %d counts wrong (expected %d, got a=%d b=%d)",
                trial, N, count_a, count_b))
            hard_failures = hard_failures + 1
        end
        table.insert(unpadded_times, elapsed)
    end
end

for trial = 1, TRIALS do
    local ok, count_a, count_b, elapsed = pcall(run_once, "on")
    if not ok then
        print("  FAIL: padded trial " .. trial .. " errored: " .. tostring(count_a))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  [padded   trial %d] count_a=%d count_b=%d elapsed_ms=%.3f",
            trial, count_a, count_b, elapsed))
        if count_a ~= N or count_b ~= N then
            print(string.format(
                "  FAIL: padded trial %d counts wrong (expected %d, got a=%d b=%d)",
                trial, N, count_a, count_b))
            hard_failures = hard_failures + 1
        end
        table.insert(padded_times, elapsed)
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness/execution failure(s))", hard_failures))
    os.exit(1)
end

print("  correctness: PASS (both modes produced exact counts in every trial)")

-- 2. Timing -- soft assertion. Require correctness always (done above);
-- the timing margin is reported, and only turned into a hard failure if
-- the harness couldn't even average the samples.
if #unpadded_times == 0 or #padded_times == 0 then
    print("RESULT: FAIL (no timing samples collected)")
    os.exit(1)
end

local avg_unpadded = average(unpadded_times)
local avg_padded = average(padded_times)
local improvement_pct = (avg_unpadded - avg_padded) / avg_unpadded * 100.0

print(string.format(
    "  avg elapsed_ms: unpadded=%.3f padded=%.3f (padded is %.1f%% %s)",
    avg_unpadded, avg_padded, math.abs(improvement_pct),
    improvement_pct >= 0 and "faster" or "slower"))

if improvement_pct >= NOISE_THRESHOLD_PCT then
    print(string.format(
        "  timing: PASS (padded averaged %.1f%% faster, clearing the %.1f%% noise floor)",
        improvement_pct, NOISE_THRESHOLD_PCT))
else
    print(string.format(
        "  timing: WARN (padded was only %.1f%% faster/slower than unpadded, " ..
        "within the %.1f%% noise floor). False sharing's cost depends on " ..
        "landing the two hot threads on separate physical cores with real " ..
        "cache-coherence traffic between them; a busy shared host, SMT " ..
        "siblings, or a scheduler that migrates the threads can all mute " ..
        "the effect without making the fix wrong. Correctness still holds " ..
        "(checked above) -- see README for how to get a cleaner signal.",
        improvement_pct, NOISE_THRESHOLD_PCT))
end

print("RESULT: PASS")
os.exit(0)
