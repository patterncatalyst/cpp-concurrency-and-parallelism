#!/usr/bin/env lua5.4
-- concurrency/08-atomics-and-the-memory-model — verify.lua
--
-- Plain Lua 5.4, no external modules, run once inside the demo's container
-- against the binary that same image just built -- the convention
-- 20-mechanical-sympathy's verify.lua establishes.
--
-- What this example checks:
--   1. Correctness, --mode seqcst and --mode acqrel (HARD). Both orderings
--      are sufficient for a correct one-slot hand-off; every trial must
--      complete (consumed == N) with the exact closed-form sum
--      0+1+...+N-1. Any mismatch here is a FAIL -- these are the two
--      orderings the chapter says are both correct, so there is no
--      acceptable divergence.
--   2. The broken case actually misbehaves (HARD). --mode broken removes
--      all atomicity and ordering from the same hand-off; the chapter's
--      claim is that this is not merely "slower" but genuinely incorrect.
--      This assertion requires the run to NOT cleanly complete with the
--      right answer -- i.e. NOT (completed == true AND sum == expected).
--      In practice (see README) this manifests as a deterministic stall
--      (consumed=0, stalled=true), because -O2's loop-invariant code
--      motion hoists the consumer's plain read of `tail` out of its
--      busy-wait loop -- a compiler code-generation decision, not a
--      scheduling race, so it reproduces identically on every run of the
--      same compiled binary (no flakiness to average over).
--   3. seq_cst vs acquire/release timing margin (SOFT). seq_cst's global
--      total order costs a locked instruction on x86-64's store side;
--      acquire/release needs only a plain mov. The chapter's measured gap
--      is "commonly on the order of 10-20%" on real hardware, but this
--      check only WARNS below a noise floor rather than asserting any
--      fixed percentage -- core placement, SMT siblings, and host
--      contention can all mute (never reverse the existence of) the
--      effect without making either ordering wrong.

local BIN = os.getenv("RING_HANDOFF_BIN") or "/usr/local/bin/ring_handoff"
local N = tonumber(os.getenv("RING_HANDOFF_N") or "2000000")
local BROKEN_N = tonumber(os.getenv("RING_HANDOFF_BROKEN_N") or "50000")
local TRIALS = tonumber(os.getenv("RING_HANDOFF_TRIALS") or "3")
local NOISE_THRESHOLD_PCT = 5.0 -- below this, call the timing result noise

local function run_once(mode, n)
    local cmd = string.format("%s --mode %s -n %d", BIN, mode, n)
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

    local completed = output:match("completed=(%a+)")
    local consumed = tonumber(output:match("consumed=(%d+)"))
    local sum = tonumber(output:match("sum=(%d+)"))
    local expected_sum = tonumber(output:match("expected_sum=(%d+)"))
    local stalled = output:match("stalled=(%a+)")
    local elapsed = tonumber(output:match("elapsed_ms=([%d%.]+)"))
    if not (completed and consumed and sum and expected_sum and stalled and elapsed) then
        error("could not parse ring_handoff output:\n" .. output)
    end
    return {
        completed = (completed == "true"),
        consumed = consumed,
        sum = sum,
        expected_sum = expected_sum,
        stalled = (stalled == "true"),
        elapsed_ms = elapsed,
    }
end

local function average(values)
    local sum = 0
    for _, v in ipairs(values) do sum = sum + v end
    return sum / #values
end

print(string.format(
    "== verify.lua: 08-atomics-and-the-memory-model (ring hand-off) -- N=%d, trials=%d ==",
    N, TRIALS))

local hard_failures = 0

-- 1. Correctness: seqcst and acqrel, every trial, exact sum.
local timings = { seqcst = {}, acqrel = {} }
for _, mode in ipairs({ "seqcst", "acqrel" }) do
    for trial = 1, TRIALS do
        local ok, result = pcall(run_once, mode, N)
        if not ok then
            print(string.format("  FAIL: %s trial %d errored: %s", mode, trial, tostring(result)))
            hard_failures = hard_failures + 1
        else
            print(string.format(
                "  [%-6s trial %d] completed=%s consumed=%d sum=%d expected_sum=%d elapsed_ms=%.3f",
                mode, trial, tostring(result.completed), result.consumed, result.sum,
                result.expected_sum, result.elapsed_ms))
            if not result.completed or result.sum ~= result.expected_sum then
                print(string.format(
                    "  FAIL: %s trial %d did not complete correctly (completed=%s sum=%d expected=%d)",
                    mode, trial, tostring(result.completed), result.sum, result.expected_sum))
                hard_failures = hard_failures + 1
            else
                table.insert(timings[mode], result.elapsed_ms)
            end
        end
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness/execution failure(s) in seqcst/acqrel)", hard_failures))
    os.exit(1)
end

print("  correctness (seqcst, acqrel): PASS (both orderings produced the exact expected sum in every trial)")

-- 2. The broken case must actually misbehave -- this IS the hard assertion
-- for --mode broken: it must NOT cleanly complete with the right answer.
print(string.format("  running --mode broken (n=%d, bounded spin -- always terminates)...", BROKEN_N))
local broken_ok, broken = pcall(run_once, "broken", BROKEN_N)
if not broken_ok then
    print("  FAIL: broken run errored unexpectedly: " .. tostring(broken))
    os.exit(1)
end
print(string.format(
    "  [broken] completed=%s consumed=%d sum=%d expected_sum=%d stalled=%s elapsed_ms=%.3f",
    tostring(broken.completed), broken.consumed, broken.sum, broken.expected_sum,
    tostring(broken.stalled), broken.elapsed_ms))

local broken_misbehaved = not (broken.completed and broken.sum == broken.expected_sum)
if not broken_misbehaved then
    print("  FAIL: --mode broken completed cleanly with the correct sum -- expected it to diverge.")
    print("        This would mean the compiler did NOT hoist the plain busy-wait read out of")
    print("        the loop on this build (see README's 'Why the broken case is deterministic,")
    print("        not flaky' section) -- re-check the compiler/optimization level, since the")
    print("        whole point of this example is that the unsynchronized hand-off is unsafe.")
    os.exit(1)
end
print(string.format(
    "  negative case: PASS (--mode broken diverged from correct behavior, as expected --" ..
    " stalled=%s, consumed %d/%d)",
    tostring(broken.stalled), broken.consumed, BROKEN_N))

-- 3. Timing -- soft assertion, seq_cst vs acquire/release.
local avg_seqcst = average(timings.seqcst)
local avg_acqrel = average(timings.acqrel)
local improvement_pct = (avg_seqcst - avg_acqrel) / avg_seqcst * 100.0

print(string.format(
    "  avg elapsed_ms: seqcst=%.3f acqrel=%.3f (acq_rel is %.1f%% %s)",
    avg_seqcst, avg_acqrel, math.abs(improvement_pct),
    improvement_pct >= 0 and "faster" or "slower"))

if improvement_pct >= NOISE_THRESHOLD_PCT then
    print(string.format(
        "  timing: PASS (acquire/release averaged %.1f%% faster than seq_cst, clearing the %.1f%% noise floor)",
        improvement_pct, NOISE_THRESHOLD_PCT))
else
    print(string.format(
        "  timing: WARN (acquire/release was only %.1f%% faster/slower than seq_cst, within the " ..
        "%.1f%% noise floor). The chapter's measured gap (commonly 10-20%%) depends on x86-64's " ..
        "seq_cst store needing a locked instruction that acquire/release's plain mov avoids -- a " ..
        "busy shared host, SMT-sibling placement, or a scheduler that migrates the two pinned " ..
        "threads can all mute that signal without making either ordering incorrect. Correctness " ..
        "still holds for both (checked above).",
        improvement_pct, NOISE_THRESHOLD_PCT))
end

print("RESULT: PASS")
os.exit(0)
