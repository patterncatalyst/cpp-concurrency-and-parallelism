#!/usr/bin/env lua5.4
-- concurrency/06-lock-ordering — verify.lua
--
-- Plain Lua 5.4, no external modules, run inside the demo's container
-- against the binary that same image built (the project's verify.lua
-- convention -- see examples/concurrency/20-mechanical-sympathy/verify.lua
-- for the reference).
--
-- What this checks (both HARD -- this chapter's example has no inherent
-- timing noise the way chapter 5's futex-count comparison does; a
-- deadlock forced by a std::latch either reproduces every time or the
-- demo program itself is broken):
--
--   1. The --mode deadlock build genuinely deadlocks: run under an
--      in-container `timeout`, it must NOT exit on its own -- `timeout`
--      has to kill it. This is the only way to make a demo whose entire
--      point is "the program stops forever" itself terminate reliably.
--   2. The --mode fixed build (std::scoped_lock, same opposing order)
--      always completes, exits 0, and its total_ops matches the expected
--      closed-form count (2 * iterations: one worker per acquisition
--      order, each doing `iterations` acquisitions).
--
-- As a bonus (SOFT, informational only, never affects PASS/FAIL): while
-- the deadlock build is hung, this probes /proc/<pid>/task/*/wchan for
-- every thread, which chapter 6 and chapter 5 both point to as the
-- outside-the-process evidence that every thread involved is parked in
-- the kernel's futex wait queue. Reading it depends on procfs details
-- (kptr_restrict, PID namespace visibility) that aren't guaranteed across
-- every container runtime, so a failed or empty read here is reported,
-- not failed.

local BIN = os.getenv("LOCK_ORDERING_BIN") or "/usr/local/bin/lock_ordering"
local ITERATIONS = tonumber(os.getenv("LOCK_ORDERING_ITERATIONS") or "20000")
local DEADLOCK_TIMEOUT_SECS = tonumber(os.getenv("LOCK_ORDERING_DEADLOCK_TIMEOUT") or "3")
local FIXED_TIMEOUT_SECS = tonumber(os.getenv("LOCK_ORDERING_FIXED_TIMEOUT") or "30")

local function run(cmd)
    local handle, perr = io.popen(cmd .. " 2>&1")
    if not handle then
        error(string.format("failed to launch %q: %s", cmd, tostring(perr)))
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
    -- io.popen/pclose's returned code: on a normal exit, `code` is the exit
    -- status; on a signal, `why` is "signal" and `code` is the signal
    -- number. Either way we want a single integer "effective exit status"
    -- to compare against, with -1 standing in for "never resolved".
    local rc
    if ok then
        rc = 0
    elseif why == "exit" then
        rc = code
    elseif why == "signal" then
        rc = 128 + (code or 0)
    else
        rc = -1
    end
    return rc, output
end

print(string.format(
    "== verify.lua: 06-lock-ordering -- iterations=%d, deadlock_timeout=%ds ==",
    ITERATIONS, DEADLOCK_TIMEOUT_SECS))

local hard_failures = 0

-- 1. The deadlock build must NOT exit on its own -- timeout has to kill it.
local deadlock_cmd = string.format(
    "timeout --signal=KILL %ds %s --mode deadlock",
    DEADLOCK_TIMEOUT_SECS, BIN)
local deadlock_rc, deadlock_output = run(deadlock_cmd)
print(string.format("  [deadlock] timeout rc=%d", deadlock_rc))
print("  --- deadlock output ---")
for line in deadlock_output:gmatch("[^\n]+") do
    print("    " .. line)
end

if deadlock_rc == 0 then
    print("  FAIL: deadlock build exited 0 on its own -- it should have " ..
          "hung forever (the forced AB/BA deadlock did not reproduce)")
    hard_failures = hard_failures + 1
elseif deadlock_rc ~= 124 then
    print(string.format(
        "  WARN: timeout's exit code was %d, not the usual GNU coreutils " ..
        "124 for an enforced kill -- still nonzero, so the process did not " ..
        "exit on its own; treating this as the deadlock reproducing",
        deadlock_rc))
else
    print("  deadlock: PASS (timeout had to kill the process after " ..
          DEADLOCK_TIMEOUT_SECS .. "s -- it never exited on its own)")
end

-- Bonus / soft: probe /proc/<pid>/task/*/wchan while a fresh instance of
-- the deadlock build is hung, looking for every thread parked in the
-- kernel. Never affects PASS/FAIL -- see header comment.
do
    local probe_script =
        BIN .. ' --mode deadlock >/dev/null 2>&1 &\n' ..
        'pid=$!\n' ..
        'sleep 0.5\n' ..
        'for w in /proc/$pid/task/*/wchan; do\n' ..
        '    printf "WCHAN:%s\\n" "$(cat "$w" 2>/dev/null)"\n' ..
        'done\n' ..
        'kill -9 "$pid" 2>/dev/null\n' ..
        'wait "$pid" 2>/dev/null\n'
    local probe_ok, probe_err = pcall(function()
        local handle = io.popen("sh -c '" .. probe_script .. "' 2>&1")
        if not handle then
            error("could not launch wchan probe")
        end
        local output = handle:read("*a")
        handle:close()
        local wchans = {}
        for w in output:gmatch("WCHAN:([^\n]*)") do
            table.insert(wchans, w)
        end
        if #wchans == 0 then
            print("  [wchan probe] no readable /proc/<pid>/task/*/wchan entries " ..
                  "(procfs restrictions or an unsupported runtime) -- informational only")
        else
            local parked = 0
            for _, w in ipairs(wchans) do
                if w:match("futex") then
                    parked = parked + 1
                end
            end
            print(string.format(
                "  [wchan probe] %d/%d threads parked on a futex-related wchan: %s",
                parked, #wchans, table.concat(wchans, ", ")))
        end
    end)
    if not probe_ok then
        print("  [wchan probe] skipped: " .. tostring(probe_err))
    end
end

-- 2. The fixed build (std::scoped_lock) must always complete, exit 0, and
-- produce the expected closed-form total: one worker per acquisition
-- order, each doing `iterations` acquisitions.
local fixed_cmd = string.format(
    "timeout %ds %s --mode fixed -n %d",
    FIXED_TIMEOUT_SECS, BIN, ITERATIONS)
local fixed_rc, fixed_output = run(fixed_cmd)
print(string.format("  [fixed] rc=%d output: %s", fixed_rc, fixed_output:gsub("%s+$", "")))

local expected_total = ITERATIONS * 2
local total_ops = tonumber(fixed_output:match("total_ops=(%d+)"))

if fixed_rc ~= 0 then
    print(string.format(
        "  FAIL: fixed build did not exit 0 (rc=%d) -- std::scoped_lock " ..
        "should make this opposing-order acquisition deadlock-free", fixed_rc))
    hard_failures = hard_failures + 1
elseif not total_ops then
    print("  FAIL: could not parse total_ops from fixed build output:\n" .. fixed_output)
    hard_failures = hard_failures + 1
elseif total_ops ~= expected_total then
    print(string.format(
        "  FAIL: fixed build total_ops=%d, expected %d (2 * iterations)",
        total_ops, expected_total))
    hard_failures = hard_failures + 1
else
    print(string.format(
        "  fixed: PASS (exited 0, total_ops=%d matches 2 * %d iterations)",
        total_ops, ITERATIONS))
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
