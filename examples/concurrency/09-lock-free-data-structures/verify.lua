#!/usr/bin/env lua5.4
-- concurrency/09-lock-free-data-structures — verify.lua
--
-- Plain Lua 5.4, no external modules, run once inside the demo's container
-- against the binary that same image just built -- the convention
-- 20-mechanical-sympathy's verify.lua establishes.
--
-- What this example checks:
--   1. Correctness is padding- and capacity-independent (HARD). Every item
--      pushed must be consumed exactly once, in order: the binary itself
--      checks this per-item (the producer pushes value `i` at logical
--      position `i`, so the consumer must read back exactly `v == h` at
--      position `h` -- any loss, duplication, or reordering surfaces as a
--      `mismatches` count), and verify.lua additionally cross-checks the
--      aggregate sum against the closed-form 0+1+...+N-1. This must hold
--      across both --pad settings and several capacities, including 1
--      (maximum contention, a single-slot ring).
--   2. Padded throughput >= unpadded throughput (SOFT). If `head` and
--      `tail` share a cache line (the unpadded layout), the consumer's
--      store to `head` invalidates the producer's cached copy of the whole
--      line, `tail` included, even though the producer never touches
--      `head`. Padding each cursor onto its own line removes that path.
--      This is checked as a soft/warn assertion, not a fixed percentage,
--      for the same reason Doc 20's false-sharing demo treats its own
--      timing check as soft: core placement and host contention can mute
--      the signal without making the fix wrong.

local BIN = os.getenv("SPSC_RING_BIN") or "/usr/local/bin/spsc_ring"
local CORRECTNESS_N = tonumber(os.getenv("SPSC_RING_CORRECTNESS_N") or "200000")
local TIMING_N = tonumber(os.getenv("SPSC_RING_TIMING_N") or "5000000")
-- Capacity 1 for the timing comparison: the chapter's own guidance is that
-- a one-slot ring (the tightest possible hand-off, forcing lockstep between
-- producer and consumer) gives the clearest false-sharing signal, since
-- every single push and pop touches a cursor regardless of capacity, but a
-- tiny capacity maximizes how often the two threads are both actively
-- spinning on each other's cursor at the same time.
local TIMING_CAPACITY = tonumber(os.getenv("SPSC_RING_TIMING_CAPACITY") or "1")
local TRIALS = tonumber(os.getenv("SPSC_RING_TRIALS") or "3")
local NOISE_THRESHOLD_PCT = 5.0 -- below this, call the timing result noise

-- Capacities exercised by the correctness sweep, including 1 (maximum
-- contention, a single-slot ring) per the chapter's EXAMPLE SPEC.
local CORRECTNESS_CAPACITIES = { 1, 2, 64, 1024 }

local function run_once(pad, capacity, n)
    local cmd = string.format("%s --pad %s --capacity %d -n %d", BIN, pad, capacity, n)
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

    local consumed = tonumber(output:match("consumed=(%d+)"))
    local mismatches = tonumber(output:match("mismatches=(%d+)"))
    local sum = tonumber(output:match("sum=(%d+)"))
    local expected_sum = tonumber(output:match("expected_sum=(%d+)"))
    local elapsed = tonumber(output:match("elapsed_ms=([%d%.]+)"))
    if not (consumed and mismatches and sum and expected_sum and elapsed) then
        error("could not parse spsc_ring output:\n" .. output)
    end
    return {
        consumed = consumed,
        mismatches = mismatches,
        sum = sum,
        expected_sum = expected_sum,
        elapsed_ms = elapsed,
    }
end

local function average(values)
    local sum = 0
    for _, v in ipairs(values) do sum = sum + v end
    return sum / #values
end

print(string.format(
    "== verify.lua: 09-lock-free-data-structures (SPSC ring) -- correctness_n=%d, timing_n=%d, trials=%d ==",
    CORRECTNESS_N, TIMING_N, TRIALS))

local hard_failures = 0

-- 1. Correctness sweep: every capacity, both pad settings, one run each --
-- the bug this checks for (a compiler/ordering mistake in the ring itself)
-- is not scheduling-flaky, so one run per combination is sufficient; the
-- timing section below is what repeats across trials.
for _, capacity in ipairs(CORRECTNESS_CAPACITIES) do
    for _, pad in ipairs({ "off", "on" }) do
        local ok, result = pcall(run_once, pad, capacity, CORRECTNESS_N)
        if not ok then
            print(string.format("  FAIL: pad=%s capacity=%d errored: %s", pad, capacity, tostring(result)))
            hard_failures = hard_failures + 1
        else
            print(string.format(
                "  [pad=%-3s capacity=%-5d] consumed=%d mismatches=%d sum=%d expected_sum=%d elapsed_ms=%.3f",
                pad, capacity, result.consumed, result.mismatches, result.sum,
                result.expected_sum, result.elapsed_ms))
            if result.consumed ~= CORRECTNESS_N then
                print(string.format(
                    "  FAIL: pad=%s capacity=%d consumed %d items, expected %d",
                    pad, capacity, result.consumed, CORRECTNESS_N))
                hard_failures = hard_failures + 1
            end
            if result.mismatches ~= 0 then
                print(string.format(
                    "  FAIL: pad=%s capacity=%d reported %d mismatches -- an item was lost, " ..
                    "duplicated, or delivered out of order",
                    pad, capacity, result.mismatches))
                hard_failures = hard_failures + 1
            end
            if result.sum ~= result.expected_sum then
                print(string.format(
                    "  FAIL: pad=%s capacity=%d sum %d != expected %d",
                    pad, capacity, result.sum, result.expected_sum))
                hard_failures = hard_failures + 1
            end
        end
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness failure(s) across capacities/padding)", hard_failures))
    os.exit(1)
end

print(string.format(
    "  correctness: PASS (every item consumed exactly once, in order, across %d capacities x 2 padding modes)",
    #CORRECTNESS_CAPACITIES))

-- 2. Timing -- soft assertion. Padded vs. unpadded throughput at a fixed,
-- contention-sensitive capacity, averaged over several trials.
local unpadded_times = {}
local padded_times = {}

for trial = 1, TRIALS do
    local ok, result = pcall(run_once, "off", TIMING_CAPACITY, TIMING_N)
    if not ok then
        print(string.format("  FAIL: unpadded timing trial %d errored: %s", trial, tostring(result)))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  [unpadded trial %d] consumed=%d mismatches=%d elapsed_ms=%.3f",
            trial, result.consumed, result.mismatches, result.elapsed_ms))
        if result.consumed ~= TIMING_N or result.mismatches ~= 0 or result.sum ~= result.expected_sum then
            print(string.format("  FAIL: unpadded timing trial %d produced incorrect output", trial))
            hard_failures = hard_failures + 1
        else
            table.insert(unpadded_times, result.elapsed_ms)
        end
    end
end

for trial = 1, TRIALS do
    local ok, result = pcall(run_once, "on", TIMING_CAPACITY, TIMING_N)
    if not ok then
        print(string.format("  FAIL: padded timing trial %d errored: %s", trial, tostring(result)))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  [padded   trial %d] consumed=%d mismatches=%d elapsed_ms=%.3f",
            trial, result.consumed, result.mismatches, result.elapsed_ms))
        if result.consumed ~= TIMING_N or result.mismatches ~= 0 or result.sum ~= result.expected_sum then
            print(string.format("  FAIL: padded timing trial %d produced incorrect output", trial))
            hard_failures = hard_failures + 1
        else
            table.insert(padded_times, result.elapsed_ms)
        end
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness/execution failure(s) in timing runs)", hard_failures))
    os.exit(1)
end

if #unpadded_times == 0 or #padded_times == 0 then
    print("RESULT: FAIL (no timing samples collected)")
    os.exit(1)
end

local avg_unpadded = average(unpadded_times)
local avg_padded = average(padded_times)
local improvement_pct = (avg_unpadded - avg_padded) / avg_unpadded * 100.0

print(string.format(
    "  avg elapsed_ms (capacity=%d): unpadded=%.3f padded=%.3f (padded is %.1f%% %s)",
    TIMING_CAPACITY, avg_unpadded, avg_padded, math.abs(improvement_pct),
    improvement_pct >= 0 and "faster" or "slower"))

if improvement_pct >= NOISE_THRESHOLD_PCT then
    print(string.format(
        "  timing: PASS (padded averaged %.1f%% faster, clearing the %.1f%% noise floor)",
        improvement_pct, NOISE_THRESHOLD_PCT))
else
    print(string.format(
        "  timing: WARN (padded was only %.1f%% faster/slower than unpadded, within the %.1f%% " ..
        "noise floor). False sharing's cost depends on the producer and consumer threads " ..
        "actually landing on separate physical cores with real cache-coherence traffic between " ..
        "them; a busy shared host, SMT siblings, or a scheduler that migrates the threads can " ..
        "all mute the effect without making the padded layout wrong. Correctness still holds " ..
        "(checked above) for every capacity and padding mode.",
        improvement_pct, NOISE_THRESHOLD_PCT))
end

print("RESULT: PASS")
os.exit(0)
