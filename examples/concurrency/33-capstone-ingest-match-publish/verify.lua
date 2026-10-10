#!/usr/bin/env lua5.4
-- concurrency/33-capstone-ingest-match-publish — verify.lua
--
-- Same assertion-harness contract every sibling example in this project
-- follows: plain Lua 5.4 (no external modules), run once inside the
-- demo's container against the binary that same image just built.
--
--   * No required arguments. Reads CAPSTONE_PIPELINE_BIN and the
--     --sustained/--burst/etc. knobs via env var overrides, with sane
--     defaults otherwise.
--   * Prints a readable, line-oriented summary to stdout as it goes.
--   * Exits 0 on pass. A pass MAY include a WARN line for a soft
--     assertion -- WARN does not fail the run, only a hard failure does.
--   * Exits non-zero (and prints a line starting "FAIL"/"RESULT: FAIL")
--     on any hard failure.
--
-- capstone_pipeline itself never judges pass/fail -- it only reports (one
-- EVENT line per accepted order, one final SUMMARY line of counters and
-- latency percentiles), exactly like every sibling binary in this
-- project. All of the judgment below is this file's job.
--
-- What this example checks (HARD unless marked SOFT):
--
--   1. The binary's output parses: a SUMMARY line with every expected
--      field, and one EVENT line per field it claims to have produced.
--   2. No accepted order was lost or duplicated through EITHER ring:
--      every EVENT line's match_seq is unique, and the full set is
--      exactly {0, 1, ..., events-1} with no gaps.
--   3. Bookkeeping conservation across ingest: total_submitted ==
--      accepted + busy + deadline_expired, and accepted == the number of
--      EVENT lines actually produced.
--   4. Outcome-count conservation inside the match stage itself:
--      accepted_new == filled_as_aggressor + rested,
--      accepted_cancel == cancel_ok + cancel_miss, and -- the real
--      correctness-of-matching invariant -- rested == filled_later +
--      cancel_ok + final_resting_scanned (every order that ever rested in
--      the book is later filled, later cancelled, or still resting at
--      the end -- scanned independently from the live pool, not just
--      counted).
--   5. Every EVENT line's match_tid is the SAME value (and matches
--      SUMMARY's match_tid) -- the single-writer invariant Doc 33's
--      observability section describes verifying directly rather than
--      assuming from the architecture.
--   6. Back-pressure actually engaged: busy > 0 (the overload burst
--      produced real BUSY responses) and the ingest ring's peak
--      occupancy never exceeded its fixed capacity (never grew
--      unbounded).
--   7. Each EVENT line's kind/outcome pairing is structurally sane
--      (CANCEL_OK/CANCEL_MISS only ever tag a CANCEL; FILLED/RESTED only
--      ever tag a NEW).
--
-- SOFT:
--   8. p50/p99/p99.9 latency figures are present and parse as numbers
--      (this is what the chapter promises: the figures are reported, not
--      asserted against a fixed threshold). Their relative ordering
--      (p50 <= p99 <= p99.9) is a sanity check, warned rather than
--      failed, since a very small sample can defy strict monotonicity at
--      the boundaries.

local BIN = os.getenv("CAPSTONE_PIPELINE_BIN") or "/usr/local/bin/capstone_pipeline"

local args = {}
local function add_opt(flag, env)
    local v = os.getenv(env)
    if v then table.insert(args, flag .. " " .. v) end
end
add_opt("--sustained", "CAPSTONE_SUSTAINED")
add_opt("--burst", "CAPSTONE_BURST")
add_opt("--ingest-threads", "CAPSTONE_INGEST_THREADS")
add_opt("--publish-threads", "CAPSTONE_PUBLISH_THREADS")
add_opt("--ingest-capacity", "CAPSTONE_INGEST_CAPACITY")
add_opt("--publish-capacity", "CAPSTONE_PUBLISH_CAPACITY")

local cmd = BIN .. " " .. table.concat(args, " ")

print(string.format("== verify.lua: 33-capstone-ingest-match-publish -- running: %s ==", cmd))

local handle, perr = io.popen(cmd .. " 2>&1")
if not handle then
    print("FAIL: could not launch " .. cmd .. ": " .. tostring(perr))
    os.exit(1)
end
local output = handle:read("*a")
local ok, why, code = handle:close()
if not ok then
    print(string.format("FAIL: capstone_pipeline exited abnormally (%s %s)", tostring(why), tostring(code)))
    print("--- output ---")
    print(output)
    os.exit(1)
end

local hard_failures = 0
local warnings = 0

local function fail(msg)
    print("  FAIL: " .. msg)
    hard_failures = hard_failures + 1
end
local function warn(msg)
    print("  WARN: " .. msg)
    warnings = warnings + 1
end

-- ── Parse the SUMMARY line ──────────────────────────────────────────────
local summary_line = nil
for line in output:gmatch("[^\n]+") do
    if line:match("^SUMMARY ") then summary_line = line end
end
if not summary_line then
    print("FAIL: no SUMMARY line found in output")
    print("--- output ---")
    print(output)
    os.exit(1)
end

local function field(line, name, pattern)
    local v = line:match(name .. "=(" .. pattern .. ")")
    if not v then
        fail(string.format("SUMMARY missing or unparseable field %q", name))
        return nil
    end
    return v
end

local S = {}
S.pinned             = summary_line:match("pinned=(%a+)")
S.match_tid          = field(summary_line, "match_tid", "%d+")
S.ingest_capacity    = field(summary_line, "ingest_capacity", "%d+")
S.publish_capacity   = field(summary_line, "publish_capacity", "%d+")
S.total_submitted    = field(summary_line, "total_submitted", "%d+")
S.busy               = field(summary_line, "busy", "%d+")
S.deadline_expired   = field(summary_line, "deadline_expired", "%d+")
S.accepted           = field(summary_line, "accepted", "%d+")
S.accepted_new       = field(summary_line, "accepted_new", "%d+")
S.accepted_cancel    = field(summary_line, "accepted_cancel", "%d+")
S.filled_as_aggressor = field(summary_line, "filled_as_aggressor", "%d+")
S.rested             = field(summary_line, "rested", "%d+")
S.filled_later       = field(summary_line, "filled_later", "%d+")
S.cancel_ok          = field(summary_line, "cancel_ok", "%d+")
S.cancel_miss        = field(summary_line, "cancel_miss", "%d+")
S.final_resting_scanned = field(summary_line, "final_resting_scanned", "%d+")
S.ingest_peak_occupancy = field(summary_line, "ingest_peak_occupancy", "%d+")
S.events             = field(summary_line, "events", "%d+")
S.p50                = field(summary_line, "p50_latency_ns", "%d+")
S.p99                = field(summary_line, "p99_latency_ns", "%d+")
S.p999               = field(summary_line, "p999_latency_ns", "%d+")

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d SUMMARY parse failure(s))", hard_failures))
    os.exit(1)
end

for k, v in pairs(S) do
    if k ~= "pinned" then S[k] = tonumber(v) end
end

print(string.format(
    "  SUMMARY: pinned=%s total_submitted=%d busy=%d deadline_expired=%d accepted=%d events=%d",
    S.pinned, S.total_submitted, S.busy, S.deadline_expired, S.accepted, S.events))
print(string.format(
    "  book: accepted_new=%d accepted_cancel=%d filled_as_aggressor=%d rested=%d " ..
    "filled_later=%d cancel_ok=%d cancel_miss=%d final_resting_scanned=%d",
    S.accepted_new, S.accepted_cancel, S.filled_as_aggressor, S.rested,
    S.filled_later, S.cancel_ok, S.cancel_miss, S.final_resting_scanned))
print(string.format(
    "  ring: ingest_capacity=%d ingest_peak_occupancy=%d publish_capacity=%d",
    S.ingest_capacity, S.ingest_peak_occupancy, S.publish_capacity))
print(string.format(
    "  latency: p50_ns=%d p99_ns=%d p999_ns=%d", S.p50, S.p99, S.p999))

-- ── Parse every EVENT line ──────────────────────────────────────────────
local events = {}
local seen_seq = {}
for line in output:gmatch("[^\n]+") do
    if line:match("^EVENT ") then
        local e = {}
        e.match_seq = tonumber(line:match("match_seq=(%d+)"))
        e.kind = line:match("kind=(%a+)")
        e.outcome = line:match("outcome=([%a_]+)")
        e.match_tid = tonumber(line:match("match_tid=(%d+)"))
        if not (e.match_seq and e.kind and e.outcome and e.match_tid) then
            fail("unparseable EVENT line: " .. line)
        else
            table.insert(events, e)
        end
    end
end

print(string.format("  parsed %d EVENT lines", #events))

-- 1. events parsed == SUMMARY.events == SUMMARY.accepted.
if #events ~= S.events then
    fail(string.format("parsed %d EVENT lines but SUMMARY claims events=%d", #events, S.events))
end
if S.events ~= S.accepted then
    fail(string.format("SUMMARY.events (%d) != SUMMARY.accepted (%d)", S.events, S.accepted))
end

-- 2. No lost/duplicated orders: match_seq is exactly {0, ..., events-1}.
for _, e in ipairs(events) do
    if seen_seq[e.match_seq] then
        fail(string.format("duplicate match_seq=%d in published output", e.match_seq))
    end
    seen_seq[e.match_seq] = true
end
local missing = 0
for i = 0, S.events - 1 do
    if not seen_seq[i] then missing = missing + 1 end
end
if missing > 0 then
    fail(string.format("%d match_seq value(s) in [0, %d) missing from published output", missing, S.events))
end

-- 3. Ingest-side bookkeeping conservation.
if S.total_submitted ~= S.accepted + S.busy + S.deadline_expired then
    fail(string.format(
        "total_submitted (%d) != accepted (%d) + busy (%d) + deadline_expired (%d)",
        S.total_submitted, S.accepted, S.busy, S.deadline_expired))
end
if S.accepted ~= S.accepted_new + S.accepted_cancel then
    fail(string.format(
        "accepted (%d) != accepted_new (%d) + accepted_cancel (%d)",
        S.accepted, S.accepted_new, S.accepted_cancel))
end

-- 4. Match-stage outcome conservation (the order-book correctness checks).
if S.accepted_new ~= S.filled_as_aggressor + S.rested then
    fail(string.format(
        "accepted_new (%d) != filled_as_aggressor (%d) + rested (%d)",
        S.accepted_new, S.filled_as_aggressor, S.rested))
end
if S.accepted_cancel ~= S.cancel_ok + S.cancel_miss then
    fail(string.format(
        "accepted_cancel (%d) != cancel_ok (%d) + cancel_miss (%d)",
        S.accepted_cancel, S.cancel_ok, S.cancel_miss))
end
if S.rested ~= S.filled_later + S.cancel_ok + S.final_resting_scanned then
    fail(string.format(
        "book conservation violated: rested (%d) != filled_later (%d) + cancel_ok (%d) " ..
        "+ final_resting_scanned (%d) -- an order went missing or was double-counted " ..
        "inside the order book itself",
        S.rested, S.filled_later, S.cancel_ok, S.final_resting_scanned))
end

-- 5. Single-writer invariant: every EVENT's match_tid, and SUMMARY's own
-- match_tid, must all be the same thread id.
local distinct_match_tids = {}
for _, e in ipairs(events) do
    distinct_match_tids[e.match_tid] = true
end
distinct_match_tids[S.match_tid] = true
local n_distinct = 0
for _ in pairs(distinct_match_tids) do n_distinct = n_distinct + 1 end
if n_distinct ~= 1 then
    fail(string.format(
        "match stage reported %d distinct thread id(s) across %d events + SUMMARY " ..
        "(expected exactly 1) -- the single-writer invariant the order book's " ..
        "correctness depends on does not hold",
        n_distinct, #events))
end

-- 6. Back-pressure actually engaged under the overload burst.
if S.busy <= 0 then
    fail("busy == 0 -- the overload burst never produced a single BUSY response; " ..
         "back-pressure did not engage")
end
if S.ingest_peak_occupancy <= 0 then
    fail("ingest_peak_occupancy == 0 -- the ingest ring was never observed to hold anything")
end
if S.ingest_peak_occupancy > S.ingest_capacity then
    fail(string.format(
        "ingest_peak_occupancy (%d) exceeded ingest_capacity (%d) -- the ring grew " ..
        "past its fixed bound, which should be structurally impossible",
        S.ingest_peak_occupancy, S.ingest_capacity))
end

-- 7. Structural kind/outcome sanity per event.
local bad_pairing = 0
for _, e in ipairs(events) do
    if e.kind == "NEW" and not (e.outcome == "FILLED" or e.outcome == "RESTED") then
        bad_pairing = bad_pairing + 1
    elseif e.kind == "CANCEL" and not (e.outcome == "CANCEL_OK" or e.outcome == "CANCEL_MISS") then
        bad_pairing = bad_pairing + 1
    end
end
if bad_pairing > 0 then
    fail(string.format("%d EVENT line(s) have a kind/outcome pairing that should be impossible", bad_pairing))
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d hard failure(s))", hard_failures))
    os.exit(1)
end

print("  correctness: PASS (no lost/duplicated orders, book conservation holds, " ..
      "single match thread confirmed, back-pressure engaged)")

-- 8. SOFT: percentile figures present (checked above) and sane ordering.
if not (S.p50 <= S.p99 and S.p99 <= S.p999) then
    warn(string.format(
        "latency percentiles not monotonically increasing (p50=%d p99=%d p999=%d) -- " ..
        "can happen on a very small accepted-order sample; not failed, since this " ..
        "chapter deliberately does not assert a fixed latency number",
        S.p50, S.p99, S.p999))
else
    print(string.format(
        "  latency: PASS (p50=%dns <= p99=%dns <= p999=%dns, reported not asserted)",
        S.p50, S.p99, S.p999))
end

print(string.format("RESULT: PASS%s", warnings > 0 and (" (" .. warnings .. " warning(s))") or ""))
os.exit(0)
