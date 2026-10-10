#!/usr/bin/env lua5.4
-- concurrency/12-asio-strand — verify.lua
--
-- Same assertion-harness contract as every sibling example: plain Lua 5.4
-- (no external modules), run once inside the demo's container against the
-- binary that same image just built. Reads ASIO_STRAND_BIN / _N / _THREADS
-- / _SPIN / _TRIALS env vars for overrides, prints a readable summary as it
-- goes, exits 0 on pass (a pass MAY include a WARN for a soft/informational
-- check), and exits non-zero on any hard failure.
--
-- What this checks:
--
--   1. The race demo (HARD). --mode strand posts N copies of the same
--      unsynchronized-counter handler through a single shared strand,
--      drained by several threads all calling io_context::run(): Asio's
--      own guarantee is that handlers posted to the same strand never run
--      concurrently, so every trial must show overlaps == 0 and
--      counter == N exactly -- a strand failing this would mean Asio's
--      serialization guarantee itself was violated, not environment noise.
--      --mode nostrand posts the identical handler body with no strand at
--      all: every trial must show overlaps > 0 -- the race the strand
--      exists to close must actually manifest, not merely be possible in
--      principle. (The handler body deliberately widens its own race
--      window -- see src/asio_strand.cpp -- specifically so this isn't a
--      coin flip on a quiet or constrained CI host.)
--
--   2. The kernel-cost comparison (SOFT / informational). --mode
--      strand-cost and --mode mutex-cost run equivalent, always-correct
--      work (no artificial widening -- that instrumentation would equally
--      inflate both sides) through a strand and through a std::mutex,
--      and report getrusage(RUSAGE_THREAD).ru_nvcsw -- voluntary context
--      switches -- summed across worker threads, as a portable proxy for
--      how often a thread had to go through the kernel to get the
--      (equally correct) answer. The chapter's claim is that a strand
--      "never puts a thread to sleep" the way a contended mutex's
--      futex(FUTEX_WAIT) does; this harness reports the comparison and
--      treats a reversal as a WARN, not a FAIL -- it does not assert a
--      fixed ratio, and ru_nvcsw is a proxy, not a literal futex count.
--      Both modes' counter == N is still checked as a hard sanity check:
--      a mismatch here would mean either the strand or the mutex itself
--      is broken, which is a correctness bug, not noise.

local BIN = os.getenv("ASIO_STRAND_BIN") or "/usr/local/bin/asio_strand"
local N = tonumber(os.getenv("ASIO_STRAND_N") or "4000")
local THREADS = tonumber(os.getenv("ASIO_STRAND_THREADS") or "6")
local SPIN = tonumber(os.getenv("ASIO_STRAND_SPIN") or "300")
local TRIALS = tonumber(os.getenv("ASIO_STRAND_TRIALS") or "3")

local function run_once(mode)
    local cmd = string.format("%s --mode %s -n %d -t %d --spin %d",
        BIN, mode, N, THREADS, SPIN)
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

    local fields = {}
    for key, val in output:gmatch("(%a[%a_]*)=([%w%.]+)") do
        fields[key] = val
    end

    local counter = tonumber(fields.counter)
    local elapsed = tonumber(fields.elapsed_ms)
    if not (counter and elapsed) then
        error("could not parse asio_strand output:\n" .. output)
    end

    return {
        counter = counter,
        overlaps = tonumber(fields.overlaps),
        active_max = tonumber(fields.active_max),
        distinct_tids = tonumber(fields.distinct_tids),
        voluntary_ctxt_switches = tonumber(fields.voluntary_ctxt_switches),
        elapsed_ms = elapsed,
    }
end

local function average(values)
    local sum = 0
    for _, v in ipairs(values) do
        sum = sum + v
    end
    return sum / #values
end

print(string.format(
    "== verify.lua: 12-asio-strand -- N=%d, threads=%d, spin=%d, trials=%d ==",
    N, THREADS, SPIN, TRIALS))

local hard_failures = 0

-- 1. Race demo -- strand must never overlap and must always land on N;
-- no-strand must always show at least one overlap.
print("-- race demo: strand vs. no strand --")
for trial = 1, TRIALS do
    local ok, res = pcall(run_once, "strand")
    if not ok then
        print("  FAIL: strand trial " .. trial .. " errored: " .. tostring(res))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  [strand   trial %d] counter=%d overlaps=%d active_max=%d distinct_tids=%s elapsed_ms=%.3f",
            trial, res.counter, res.overlaps, res.active_max,
            tostring(res.distinct_tids), res.elapsed_ms))
        if res.overlaps ~= 0 then
            print(string.format(
                "  FAIL: strand trial %d saw %d overlap(s) -- the strand's " ..
                "serialization guarantee should make this impossible",
                trial, res.overlaps))
            hard_failures = hard_failures + 1
        end
        if res.counter ~= N then
            print(string.format(
                "  FAIL: strand trial %d counter=%d, expected exactly %d",
                trial, res.counter, N))
            hard_failures = hard_failures + 1
        end
    end
end

local nostrand_overlap_trials = 0
for trial = 1, TRIALS do
    local ok, res = pcall(run_once, "nostrand")
    if not ok then
        print("  FAIL: nostrand trial " .. trial .. " errored: " .. tostring(res))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  [nostrand trial %d] counter=%d overlaps=%d active_max=%d distinct_tids=%s elapsed_ms=%.3f",
            trial, res.counter, res.overlaps, res.active_max,
            tostring(res.distinct_tids), res.elapsed_ms))
        if res.overlaps > 0 then
            nostrand_overlap_trials = nostrand_overlap_trials + 1
        else
            print(string.format(
                "  FAIL: nostrand trial %d saw 0 overlaps -- the race this " ..
                "demo exists to show did not manifest",
                trial))
            hard_failures = hard_failures + 1
        end
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness/execution failure(s))", hard_failures))
    os.exit(1)
end

print(string.format(
    "  race demo: PASS (strand: 0 overlaps and counter==%d in every trial; " ..
    "no-strand: overlaps observed in %d/%d trials)",
    N, nostrand_overlap_trials, TRIALS))

-- 2. Kernel-cost comparison -- soft/informational. Correctness (counter==N
-- for both strand-cost and mutex-cost) is still a hard check: both
-- mechanisms are supposed to produce the exact count, always.
print("-- kernel-cost comparison: strand vs. mutex (equivalent work) --")
local strand_cost_switches = {}
local mutex_cost_switches = {}

for trial = 1, TRIALS do
    local ok, res = pcall(run_once, "strand-cost")
    if not ok then
        print("  FAIL: strand-cost trial " .. trial .. " errored: " .. tostring(res))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  [strand-cost trial %d] counter=%d voluntary_ctxt_switches=%d elapsed_ms=%.3f",
            trial, res.counter, res.voluntary_ctxt_switches, res.elapsed_ms))
        if res.counter ~= N then
            print(string.format(
                "  FAIL: strand-cost trial %d counter=%d, expected exactly %d",
                trial, res.counter, N))
            hard_failures = hard_failures + 1
        end
        table.insert(strand_cost_switches, res.voluntary_ctxt_switches)
    end
end

for trial = 1, TRIALS do
    local ok, res = pcall(run_once, "mutex-cost")
    if not ok then
        print("  FAIL: mutex-cost trial " .. trial .. " errored: " .. tostring(res))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  [mutex-cost  trial %d] counter=%d voluntary_ctxt_switches=%d elapsed_ms=%.3f",
            trial, res.counter, res.voluntary_ctxt_switches, res.elapsed_ms))
        if res.counter ~= N then
            print(string.format(
                "  FAIL: mutex-cost trial %d counter=%d, expected exactly %d",
                trial, res.counter, N))
            hard_failures = hard_failures + 1
        end
        table.insert(mutex_cost_switches, res.voluntary_ctxt_switches)
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness/execution failure(s))", hard_failures))
    os.exit(1)
end

print("  kernel-cost correctness: PASS (both mechanisms produced exact counts in every trial)")

if #strand_cost_switches == 0 or #mutex_cost_switches == 0 then
    print("RESULT: FAIL (no kernel-cost samples collected)")
    os.exit(1)
end

local avg_strand_switches = average(strand_cost_switches)
local avg_mutex_switches = average(mutex_cost_switches)

print(string.format(
    "  avg voluntary_ctxt_switches: strand=%.1f mutex=%.1f",
    avg_strand_switches, avg_mutex_switches))

if avg_strand_switches < avg_mutex_switches then
    print(string.format(
        "  kernel-cost: PASS (strand averaged %.1f vs. mutex's %.1f voluntary " ..
        "context switches for equivalent, equally correct work -- consistent " ..
        "with 'a mutex blocks a thread, a strand defers a handler')",
        avg_strand_switches, avg_mutex_switches))
else
    print(string.format(
        "  kernel-cost: WARN (strand averaged %.1f vs. mutex's %.1f voluntary " ..
        "context switches -- no reversal of the correctness result, but this " ..
        "run didn't show the strand's usual kernel-cost edge). " ..
        "voluntary_ctxt_switches is a portable proxy for kernel blocking " ..
        "activity, not a literal futex(2) count (strace needs a ptrace " ..
        "capability this container isn't given); this metric is informational " ..
        "only and is never a fixed ratio. Correctness above still holds.",
        avg_strand_switches, avg_mutex_switches))
end

print("RESULT: PASS")
os.exit(0)
