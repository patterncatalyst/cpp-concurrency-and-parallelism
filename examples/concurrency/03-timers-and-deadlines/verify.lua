#!/usr/bin/env lua5.4
-- concurrency/03-timers-and-deadlines — verify.lua
--
-- Plain Lua 5.4, no external modules, run once inside the demo's container
-- against the binaries that same image just built -- this project's
-- assertion harness convention.
--
-- Checks, matching Doc 3's EXAMPLE SPEC:
--
--   (1) HARD: total elapsed time across the chain never exceeds the
--       configured budget by more than a scheduler-jitter margin, for the
--       happy path AND for a delay injected at each of the three hops (the
--       delay is itself deadline-aware in deadline_chain.cpp, so this
--       assertion is really checking that the clamp does its job).
--   (2) HARD: a hop called directly with an already-expired deadline
--       returns DeadlineExceeded with work_performed=0 -- it did not start
--       any work at all.
--   (3) SOFT / best-effort: a `strace -e trace=clock_gettime` capture of
--       clockprobe contains zero clock_gettime lines. strace is not
--       installed in this image (see Containerfile) -- if it isn't on
--       PATH, this check is skipped with a note, per the EXAMPLE SPEC's own
--       "skip it and note it; don't hard-fail" instruction, not treated as
--       a failure.

local DEADLINE_CHAIN = os.getenv("DEADLINE_CHAIN_BIN") or "/usr/local/bin/deadline_chain"
local CLOCKPROBE = os.getenv("CLOCKPROBE_BIN") or "/usr/local/bin/clockprobe"
local JITTER_MS = 150.0 -- generous scheduler/CFS-throttle margin, see Doc 3 "Running in a container"

local function run(cmd)
    local handle, perr = io.popen(cmd .. " 2>&1")
    if not handle then
        error(string.format("failed to launch %q: %s", cmd, tostring(perr)))
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
    return ok, output, why, code
end

local function run_chain(budget_ms, delay_hop, delay_ms)
    local cmd = string.format("%s --budget-ms %d --delay-hop %s --delay-ms %d",
        DEADLINE_CHAIN, budget_ms, delay_hop, delay_ms)
    local ok, output = run(cmd)
    if not ok then
        error(string.format("deadline_chain failed: %s\n--- output ---\n%s", cmd, output))
    end
    local result = output:match("result=(%a+)")
    local elapsed = tonumber(output:match("elapsed_ms=([%d%.]+)"))
    if not (result and elapsed) then
        error("could not parse deadline_chain chain-mode output:\n" .. output)
    end
    return result, elapsed, output
end

local function run_direct(hop)
    local cmd = string.format("%s --direct %s", DEADLINE_CHAIN, hop)
    local ok, output = run(cmd)
    if not ok then
        error(string.format("deadline_chain --direct failed: %s\n--- output ---\n%s", cmd, output))
    end
    local result = output:match("result=(%a+)")
    local work = tonumber(output:match("work_performed=(%d+)"))
    local elapsed = tonumber(output:match("elapsed_ms=([%d%.]+)"))
    if not (result and work and elapsed) then
        error("could not parse deadline_chain direct-mode output:\n" .. output)
    end
    return result, work, elapsed, output
end

print("== verify.lua: 03-timers-and-deadlines ==")

local hard_failures = 0

-- (1a) Happy path: no injected delay, budget comfortably large. Must finish
-- fast and succeed.
do
    local budget_ms = 200
    local ok, result, elapsed = pcall(run_chain, budget_ms, "none", 0)
    if not ok then
        print("  FAIL: happy-path chain errored: " .. tostring(result))
        hard_failures = hard_failures + 1
    else
        print(string.format("  [happy path] result=%s elapsed_ms=%.3f (budget=%dms)",
            result, elapsed, budget_ms))
        if result ~= "Ok" then
            print("  FAIL: happy-path chain did not return Ok")
            hard_failures = hard_failures + 1
        end
        if elapsed > budget_ms + JITTER_MS then
            print(string.format(
                "  FAIL: happy-path elapsed_ms=%.3f exceeded budget_ms=%d + jitter_ms=%.0f",
                elapsed, budget_ms, JITTER_MS))
            hard_failures = hard_failures + 1
        end
    end
end

-- (1b) A slow hop at each position, with an injected delay several times
-- the budget. The shared-deadline clamp must still bound total elapsed time
-- to the budget (plus jitter), and the chain must report DeadlineExceeded
-- -- proving no hop's artificial slowness let the caller's total budget
-- slip, regardless of WHICH hop was the slow one.
local budget_ms = 150
local big_delay_ms = budget_ms * 5
for _, hop in ipairs({"checkout", "query", "run"}) do
    local ok, result, elapsed = pcall(run_chain, budget_ms, hop, big_delay_ms)
    if not ok then
        print(string.format("  FAIL: slow-hop(%s) chain errored: %s", hop, tostring(result)))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  [slow hop=%-8s] result=%s elapsed_ms=%.3f (budget=%dms, injected delay=%dms)",
            hop, result, elapsed, budget_ms, big_delay_ms))
        if result ~= "DeadlineExceeded" then
            print(string.format(
                "  FAIL: slow-hop(%s) chain did not report DeadlineExceeded despite a " ..
                "%dms delay against a %dms budget", hop, big_delay_ms, budget_ms))
            hard_failures = hard_failures + 1
        end
        if elapsed > budget_ms + JITTER_MS then
            print(string.format(
                "  FAIL: slow-hop(%s) elapsed_ms=%.3f exceeded budget_ms=%d + jitter_ms=%.0f " ..
                "-- the caller's total budget was NOT respected",
                hop, elapsed, budget_ms, JITTER_MS))
            hard_failures = hard_failures + 1
        end
    end
end

-- (2) Direct-call: a hop entered with an already-expired deadline must
-- return DeadlineExceeded and must NOT have performed any work.
for _, hop in ipairs({"checkout", "query", "run"}) do
    local ok, result, work, elapsed = pcall(run_direct, hop)
    if not ok then
        print(string.format("  FAIL: direct(%s) errored: %s", hop, tostring(result)))
        hard_failures = hard_failures + 1
    else
        print(string.format("  [direct hop=%-8s] result=%s work_performed=%d elapsed_ms=%.3f",
            hop, result, work, elapsed))
        if result ~= "DeadlineExceeded" then
            print(string.format(
                "  FAIL: direct(%s) called with an already-expired deadline did not " ..
                "return DeadlineExceeded", hop))
            hard_failures = hard_failures + 1
        end
        if work ~= 0 then
            print(string.format(
                "  FAIL: direct(%s) performed work (work_performed=%d) despite being " ..
                "entered after its deadline had already passed", hop, work))
            hard_failures = hard_failures + 1
        end
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness failure(s))", hard_failures))
    os.exit(1)
end

print("  deadline propagation: PASS (happy path, 3 slow-hop cases, 3 direct-call cases)")

-- (3) Optional: strace-based proof that steady_clock::now() never becomes a
-- clock_gettime syscall. Soft -- skipped, not failed, if strace is missing.
local has_strace = run("command -v strace >/dev/null 2>&1")
if not has_strace then
    print("  clock_gettime/strace check: SKIPPED (strace not present in this image -- " ..
          "optional per the chapter's EXAMPLE SPEC)")
else
    local ok, output = run(string.format(
        "strace -f -e trace=clock_gettime %s 2>&1", CLOCKPROBE))
    if not ok then
        print("  clock_gettime/strace check: WARN (strace invocation failed, not treated " ..
              "as a correctness failure):\n" .. output)
    else
        local count = 0
        for _ in output:gmatch("clock_gettime%(") do
            count = count + 1
        end
        if count == 0 then
            print("  clock_gettime/strace check: PASS (0 clock_gettime syscalls traced -- " ..
                  "steady_clock::now() is a vDSO read)")
        else
            print(string.format(
                "  FAIL: strace captured %d clock_gettime syscall(s) -- expected 0 " ..
                "(steady_clock::now() should never trap into the kernel)", count))
            hard_failures = hard_failures + 1
        end
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
