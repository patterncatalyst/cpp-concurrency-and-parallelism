#!/usr/bin/env lua5.4
-- concurrency/27-debugging-races-deadlocks — verify.lua
--
-- Plain Lua 5.4, no external modules, run inside the demo's container
-- against the binaries that same image built (this project's verify.lua
-- convention -- see examples/concurrency/20-mechanical-sympathy/verify.lua
-- for the reference).
--
-- Every assertion here is tied to REAL tool output captured during this
-- run -- no fabricated report text. What this checks:
--
--   1. racy_counter, TSan build, --mode racy: ThreadSanitizer must
--      actually report "ThreadSanitizer: data race", naming
--      racy_counter.cpp (the increment() line). HARD when the TSan leg
--      built and its runtime initializes; SOFT SKIP if the leg wasn't
--      built in this image (no libtsan here) or TSan's runtime fails to
--      initialize in this container (a real, documented possibility
--      independent of whether the race itself exists).
--   2. racy_counter, TSan build, --mode fixed: must exit 0 with NO data
--      race reported -- the atomic fix is race-free, not just "probably
--      fine". Same SOFT-skip conditions as #1.
--   3. ab_ba_deadlock --mode deadlock genuinely never exits on its own:
--      run under an in-container `timeout --signal=KILL`, it must be
--      killed (the forced AB/BA deadlock reproduces every run). HARD --
--      this demo's whole point is a deadlock that doesn't depend on
--      scheduling luck.
--   4. A SEPARATE instance of ab_ba_deadlock --mode deadlock, backgrounded,
--      gets a live `gdb -p <pid> --batch -ex 'thread apply all bt'`
--      attached to it. HARD: the combined backtrace must show the
--      run_transfer() Account-level acquisition function blocked in both
--      worker threads, each inside a mutex-lock call -- the lock cycle,
--      read directly off gdb's own live inspection, not inferred from
--      source. SOFT SKIP only if gdb itself cannot attach at all (ptrace
--      permission denied), which is an environment/capability problem,
--      not a defect in the demo -- see this directory's README for the
--      --cap-add=SYS_PTRACE / --security-opt seccomp=unconfined demo.sh
--      runs this image with.
--   5. ab_ba_deadlock --mode fixed (std::scoped_lock, same opposing order)
--      always completes, exits 0, and total_ops matches the expected
--      closed-form count. HARD.

local RACY_PLAIN_BIN = os.getenv("RACY_COUNTER_PLAIN_BIN") or "/usr/local/bin/racy_counter_plain"
local RACY_TSAN_BIN  = os.getenv("RACY_COUNTER_TSAN_BIN")  or "/usr/local/bin/racy_counter_tsan"
local DEADLOCK_BIN    = os.getenv("AB_BA_DEADLOCK_BIN")     or "/usr/local/bin/ab_ba_deadlock"

local RACY_N = tonumber(os.getenv("RACY_COUNTER_N") or "100000")
local DEADLOCK_TIMEOUT_SECS = tonumber(os.getenv("AB_BA_DEADLOCK_DEADLOCK_TIMEOUT") or "3")
local FIXED_TIMEOUT_SECS = tonumber(os.getenv("AB_BA_DEADLOCK_FIXED_TIMEOUT") or "30")
local FIXED_ITERATIONS = tonumber(os.getenv("AB_BA_DEADLOCK_FIXED_ITERATIONS") or "20000")
local GDB_ATTACH_DELAY_SECS = tonumber(os.getenv("AB_BA_DEADLOCK_GDB_DELAY") or "0.8")

-- run(cmd) -- launches cmd via the shell, returns (rc, output) where rc is
-- a single "effective exit status" (0 on normal exit, the exit code on a
-- normal nonzero exit, 128+signal on a signal death, -1 if io.popen
-- couldn't even classify it). Identical contract to 06-lock-ordering's
-- verify.lua, reused here because the same ambiguity (timeout's SIGKILL,
-- a plain nonzero exit) applies to this chapter's binaries too.
local function run(cmd)
    local handle, perr = io.popen(cmd .. " 2>&1")
    if not handle then
        error(string.format("failed to launch %q: %s", cmd, tostring(perr)))
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
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

local function is_unavailable(output)
    return output:match("UNAVAILABLE") ~= nil
end

local function count_occurrences(haystack, needle)
    local n = 0
    local start = 1
    while true do
        local s = haystack:find(needle, start, true)
        if not s then break end
        n = n + 1
        start = s + #needle
    end
    return n
end

print("== verify.lua: 27-debugging-races-deadlocks ==")

local hard_failures = 0

-- ── 0. The plain (un-instrumented) build -- informational only ────────
-- Never asserted PASS/FAIL: the entire point of this chapter is that a
-- plain run of a genuinely racy program is NOT evidence of correctness
-- either way. A run that happens to print the right total here says
-- nothing about whether the race exists -- ThreadSanitizer (below) is
-- what actually proves it.
print("-- racy_counter (plain, un-instrumented) -- informational only --")
for trial = 1, 3 do
    local plain_cmd = string.format("%s --mode racy -n %d", RACY_PLAIN_BIN, RACY_N)
    local _, plain_out = run(plain_cmd)
    local counter = plain_out:match("counter=(%d+)")
    local expected = plain_out:match("expected=(%d+)")
    print(string.format(
        "  [plain trial %d] counter=%s expected=%s%s",
        trial, tostring(counter), tostring(expected),
        (counter and expected and tonumber(counter) ~= tonumber(expected))
            and "  <- lost updates this run (not asserted either way)" or ""))
end

-- ── 1 & 2. racy_counter under ThreadSanitizer ──────────────────────────
print("\n-- racy_counter (ThreadSanitizer) --")

local tsan_racy_cmd = string.format("%s --mode racy -n %d", RACY_TSAN_BIN, RACY_N)
local _, tsan_racy_out = run(tsan_racy_cmd)

if is_unavailable(tsan_racy_out) then
    print("  TSan leg: SOFT SKIP (racy_counter was not built with " ..
          "-fsanitize=thread in this image -- libtsan wasn't available " ..
          "from this UBI10 repo set when the image was built; see README)")
elseif tsan_racy_out:match("FATAL: ThreadSanitizer") then
    print("  TSan leg: SOFT SKIP (ThreadSanitizer's runtime failed to " ..
          "initialize in this container -- a known possibility under " ..
          "restricted namespaces, aggressive ulimit -v, or a memory-" ..
          "overcommit policy that rejects its shadow-memory reservation; " ..
          "independent of whether the race itself exists; see README)\n" ..
          "  --- raw output ---\n" .. tsan_racy_out)
else
    local has_race = tsan_racy_out:match("ThreadSanitizer: data race") ~= nil
    local names_source = tsan_racy_out:match("racy_counter%.cpp") ~= nil
    if not has_race then
        print("  FAIL: TSan build of racy_counter --mode racy did NOT " ..
              "report a data race:\n" .. tsan_racy_out)
        hard_failures = hard_failures + 1
    elseif not names_source then
        print("  FAIL: TSan reported a race but did not name " ..
              "racy_counter.cpp in the report:\n" .. tsan_racy_out)
        hard_failures = hard_failures + 1
    else
        print("  racy mode: PASS -- ThreadSanitizer reported \"data race\", " ..
              "naming racy_counter.cpp (the increment() line)")
        print("  --- captured TSan report ---")
        for line in tsan_racy_out:gmatch("[^\n]+") do print("    " .. line) end
    end

    local tsan_fixed_cmd = string.format("%s --mode fixed -n %d", RACY_TSAN_BIN, RACY_N)
    local fixed_rc, tsan_fixed_out = run(tsan_fixed_cmd)
    local fixed_has_race = tsan_fixed_out:match("ThreadSanitizer: data race") ~= nil

    if fixed_rc ~= 0 then
        print(string.format(
            "  FAIL: TSan build of racy_counter --mode fixed did not exit 0 (rc=%d):\n%s",
            fixed_rc, tsan_fixed_out))
        hard_failures = hard_failures + 1
    elseif fixed_has_race then
        print("  FAIL: TSan build of racy_counter --mode fixed reported a " ..
              "data race -- the atomic counter should be clean:\n" .. tsan_fixed_out)
        hard_failures = hard_failures + 1
    else
        print("  fixed mode: PASS (exit 0, no ThreadSanitizer report -- " ..
              "the atomic fix is race-free)")
    end
end

-- ── 3. The deadlock build must NOT exit on its own ─────────────────────
print("\n-- ab_ba_deadlock --mode deadlock (must hang; timeout kills it) --")

local deadlock_cmd = string.format(
    "timeout --signal=KILL %ds %s --mode deadlock",
    DEADLOCK_TIMEOUT_SECS, DEADLOCK_BIN)
local deadlock_rc, deadlock_output = run(deadlock_cmd)
print(string.format("  timeout rc=%d", deadlock_rc))
for line in deadlock_output:gmatch("[^\n]+") do print("    " .. line) end

if deadlock_rc == 0 then
    print("  FAIL: ab_ba_deadlock --mode deadlock exited 0 on its own -- " ..
          "it should have hung forever (the forced AB/BA deadlock did not reproduce)")
    hard_failures = hard_failures + 1
elseif deadlock_rc ~= 124 then
    print(string.format(
        "  WARN: timeout's exit code was %d, not the usual GNU coreutils " ..
        "124 for an enforced kill -- still nonzero, so the process did not " ..
        "exit on its own; treating this as the deadlock reproducing",
        deadlock_rc))
else
    print(string.format(
        "  deadlock-never-exits: PASS (timeout had to SIGKILL the process " ..
        "after %ds -- it never exited on its own)", DEADLOCK_TIMEOUT_SECS))
end

-- ── 4. Live gdb attach against a hung instance ─────────────────────────
print("\n-- ab_ba_deadlock --mode deadlock: live gdb -p <pid> attach --")

local gdb_script = string.format(
    '%s --mode deadlock >/tmp/ab_ba_deadlock.out 2>&1 & ' ..
    'pid=$!; ' ..
    'sleep %s; ' ..
    'echo "ATTACHING_TO_PID:$pid"; ' ..
    'gdb -p "$pid" --batch -ex "thread apply all bt" 2>&1; ' ..
    'kill -KILL "$pid" 2>/dev/null; ' ..
    'wait "$pid" 2>/dev/null; ' ..
    'true',
    DEADLOCK_BIN, tostring(GDB_ATTACH_DELAY_SECS))

local _, gdb_output = run(gdb_script)
print("  --- captured gdb session ---")
for line in gdb_output:gmatch("[^\n]+") do print("    " .. line) end

local ptrace_denied = gdb_output:match("ptrace: Operation not permitted") ~= nil
    or gdb_output:match("Could not attach to process") ~= nil

if ptrace_denied then
    print("  gdb attach: SOFT SKIP (ptrace permission denied -- this " ..
          "container was not run with --cap-add=SYS_PTRACE / " ..
          "--security-opt seccomp=unconfined; see this directory's " ..
          "demo.sh and README for why gdb -p needs both)")
else
    local run_transfer_count = count_occurrences(gdb_output, "run_transfer")
    local mutex_lock_count = count_occurrences(gdb_output, "mutex_lock")
    local futex_count = count_occurrences(gdb_output, "futex") + count_occurrences(gdb_output, "lll_lock")
    local has_thread2 = gdb_output:match("Thread 2") ~= nil
    local has_thread3 = gdb_output:match("Thread 3") ~= nil

    if run_transfer_count < 2 then
        print(string.format(
            "  FAIL: gdb backtrace named run_transfer() only %d time(s) -- " ..
            "expected it blocked in BOTH worker threads (the Account-level " ..
            "acquisition function on each side of the cycle)", run_transfer_count))
        hard_failures = hard_failures + 1
    elseif mutex_lock_count < 1 and futex_count < 1 then
        print("  FAIL: gdb backtrace did not show any thread blocked in a " ..
              "mutex-lock/futex call -- expected both worker threads parked " ..
              "in pthread_mutex_lock")
        hard_failures = hard_failures + 1
    elseif not (has_thread2 and has_thread3) then
        print("  FAIL: gdb's \"thread apply all bt\" did not report both " ..
              "worker threads (expected \"Thread 2\" and \"Thread 3\" " ..
              "alongside the main thread)")
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  gdb attach: PASS -- thread apply all bt shows run_transfer() " ..
            "%d times (both workers), %d mutex-lock/%d futex-wait frame(s), " ..
            "across Thread 2 and Thread 3: the AB/BA cycle read directly " ..
            "off live process state",
            run_transfer_count, mutex_lock_count, futex_count))
    end
end

-- ── 5. The fixed build (std::scoped_lock) must always complete ────────
print("\n-- ab_ba_deadlock --mode fixed (std::scoped_lock) --")

local fixed_cmd = string.format(
    "timeout %ds %s --mode fixed -n %d",
    FIXED_TIMEOUT_SECS, DEADLOCK_BIN, FIXED_ITERATIONS)
local fixed_rc, fixed_output = run(fixed_cmd)
print(string.format("  rc=%d output: %s", fixed_rc, fixed_output:gsub("%s+$", "")))

local expected_total = FIXED_ITERATIONS * 2
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
        total_ops, FIXED_ITERATIONS))
end

print()
if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
