#!/usr/bin/env lua5.4
-- concurrency/21-lock-free-messaging-and-the-disruptor — verify.lua
--
-- Same assertion-harness contract as the rest of the project (see
-- 20-mechanical-sympathy/verify.lua for the canonical statement of it):
-- plain Lua 5.4, no required arguments, env vars for overrides, a
-- readable summary, exit 0 on pass (a WARN may still pass), non-zero on
-- any hard failure.
--
-- What this example checks:
--   1. Every published event is consumed exactly once, in order, by both
--      stages (hard). journal_consumed and biz_consumed must each equal
--      published (which must itself equal n), and both mismatch counters
--      must be zero -- a mismatch means a stage read a slot's value out
--      of logical position, which is the one thing the single-writer
--      sequence-barrier design is supposed to make impossible.
--   2. The dependent (business-logic) stage never reads past the journal
--      stage's sequence (hard). disruptor_ring itself tracks this with a
--      live re-check against journal_seq at the moment of each read (see
--      the file header in disruptor_ring.cpp) and reports the violation
--      count directly -- this harness just asserts that count is zero.
--   3. Back-pressure engages: the producer actually has to wait at least
--      once because the ring filled relative to its slowest consumer
--      (hard). The business stage is deliberately slowed down (see the
--      binary's defaults) specifically so this is a deterministic
--      property of the run, not a race against scheduler timing.
--   4. Throughput (events_per_sec) is printed as a SOFT/informational
--      number -- it depends on the host's core count, placement, and
--      load, which this harness has no baseline to compare against.

local BIN = os.getenv("DISRUPTOR_BIN") or "/usr/local/bin/disruptor_ring"
local N = os.getenv("DISRUPTOR_N")
local CAPACITY = os.getenv("DISRUPTOR_CAPACITY")

local function run()
    local cmd = BIN
    if N then cmd = cmd .. " -n " .. N end
    if CAPACITY then cmd = cmd .. " --capacity " .. CAPACITY end
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

print("== verify.lua: 21-lock-free-messaging-and-the-disruptor ==")

local ok, output = pcall(run)
if not ok then
    print("FAIL: disruptor_ring errored: " .. tostring(output))
    print("RESULT: FAIL")
    os.exit(1)
end

-- %f[%a] (a frontier pattern) anchors the match to a word boundary before
-- `name`, so a short key like "n" matches only the standalone "n=..."
-- field and not the "n" inside "pinned=" or any other longer key.
local function field(name, pattern)
    local v = output:match("%f[%a]" .. name .. "=" .. pattern)
    return v
end

local n                   = tonumber(field("n", "(%d+)"))
local capacity            = tonumber(field("capacity", "(%d+)"))
local published           = tonumber(field("published", "(%d+)"))
local journal_consumed    = tonumber(field("journal_consumed", "(%d+)"))
local journal_mismatches  = tonumber(field("journal_mismatches", "(%d+)"))
local biz_consumed        = tonumber(field("biz_consumed", "(%d+)"))
local biz_mismatches      = tonumber(field("biz_mismatches", "(%d+)"))
local gating_violations   = tonumber(field("gating_violations", "(%d+)"))
local backpressure_events = tonumber(field("producer_backpressure_events", "(%d+)"))
local max_batch_journal   = tonumber(field("max_batch_journal", "(%d+)"))
local max_batch_biz       = tonumber(field("max_batch_biz", "(%d+)"))
local elapsed_ms          = tonumber(field("elapsed_ms", "([%d%.]+)"))
local events_per_sec      = tonumber(field("events_per_sec", "([%d%.]+)"))

local required = {
    n, capacity, published, journal_consumed, journal_mismatches,
    biz_consumed, biz_mismatches, gating_violations, backpressure_events,
    elapsed_ms, events_per_sec,
}
for _, v in ipairs(required) do
    if v == nil then
        print("RESULT: FAIL (could not parse disruptor_ring output)")
        print("--- raw output ---")
        print(output)
        os.exit(1)
    end
end

print(string.format(
    "  n=%d capacity=%d published=%d journal=%d/%d (mismatches=%d, max_batch=%d) " ..
    "biz=%d/%d (mismatches=%d, max_batch=%d)",
    n, capacity, published, journal_consumed, n, journal_mismatches, max_batch_journal,
    biz_consumed, n, biz_mismatches, max_batch_biz))
print(string.format(
    "  gating_violations=%d producer_backpressure_events=%d elapsed_ms=%.3f events_per_sec=%.0f",
    gating_violations, backpressure_events, elapsed_ms, events_per_sec))

local hard_failures = 0

-- 1. Every published event consumed exactly once, in order, by both
-- stages.
if published ~= n then
    print(string.format("  FAIL: published=%d, expected n=%d", published, n))
    hard_failures = hard_failures + 1
end
if journal_consumed ~= n then
    print(string.format("  FAIL: journal_consumed=%d, expected n=%d", journal_consumed, n))
    hard_failures = hard_failures + 1
end
if journal_mismatches ~= 0 then
    print(string.format("  FAIL: journal_mismatches=%d, expected 0", journal_mismatches))
    hard_failures = hard_failures + 1
end
if biz_consumed ~= n then
    print(string.format("  FAIL: biz_consumed=%d, expected n=%d", biz_consumed, n))
    hard_failures = hard_failures + 1
end
if biz_mismatches ~= 0 then
    print(string.format("  FAIL: biz_mismatches=%d, expected 0", biz_mismatches))
    hard_failures = hard_failures + 1
end

if hard_failures == 0 then
    print("  correctness: PASS (every published event consumed exactly once, in order, by both stages)")
end

-- 2. The dependent stage never reads past the journal stage's sequence.
if gating_violations ~= 0 then
    print(string.format(
        "  FAIL: gating_violations=%d -- the business stage read a slot " ..
        "the journal stage had not yet advanced past", gating_violations))
    hard_failures = hard_failures + 1
else
    print("  sequence barrier: PASS (business stage never read past the journal stage's sequence)")
end

-- 3. Back-pressure actually engaged.
if backpressure_events < 1 then
    print(string.format(
        "  FAIL: producer_backpressure_events=%d -- the producer never had " ..
        "to wait for the slowest consumer, so this run didn't exercise " ..
        "back-pressure at all", backpressure_events))
    hard_failures = hard_failures + 1
else
    print(string.format(
        "  back-pressure: PASS (producer waited %d time(s) rather than overwrite unread slots)",
        backpressure_events))
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d failure(s))", hard_failures))
    os.exit(1)
end

-- 4. SOFT/informational: throughput depends on the host, not asserted.
print(string.format(
    "  info: %d events in %.3f ms (%.0f events/sec) on this host -- " ..
    "not compared to any baseline; see README for why",
    n, elapsed_ms, events_per_sec))

print("RESULT: PASS")
os.exit(0)
