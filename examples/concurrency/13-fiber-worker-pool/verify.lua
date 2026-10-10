#!/usr/bin/env lua5.4
-- concurrency/13-fiber-worker-pool — verify.lua
--
-- Follows this project's assertion-harness contract (see
-- 20-mechanical-sympathy/verify.lua): plain Lua 5.4, no required
-- arguments, an env var override for the binary path, a readable summary
-- to stdout, exit 0 on pass (WARN allowed for a soft assertion), non-zero
-- on any hard failure.
--
-- What this example checks:
--   1. HARD — the fiber-mode pool run processes every item exactly once:
--      processed == items, AND the aggregate (sum of squares) matches a
--      value this script computes independently via the closed-form
--      formula sum_{i=1..N} i^2 = N(N+1)(2N+1)/6, not merely whatever the
--      C++ program itself claims the expected value is. A mismatch here
--      would mean the channel lost or duplicated a work item, or a worker
--      double-counted.
--   2. HARD — the same two checks for the thread-mode run, so the demo's
--      central claim ("this is the same worker-pool shape over two units
--      of concurrency") is verified for both, not just one.
--   3. HARD — the guard-page case: protected_fixedsize_stack must turn the
--      deliberate stack overflow into a signal-terminated child
--      (guard_page_signaled=true, guard_page_signal >= 1) and must do so
--      within the program's own 5-second alarm bound
--      (guard_page_timed_out=false). This is deterministic kernel/MMU
--      behavior, not a timing-noise-prone measurement, so it's a hard
--      assertion like the other two, not a soft one.
--   4. SOFT — RSS (peak resident set size) for the fiber run vs. the
--      thread run is reported as an informational signal only, never
--      asserted against a fixed ratio: how much RSS either mode actually
--      uses depends on the container's own memory accounting and the
--      allocator's behavior, which this chapter's point (a fiber stack
--      costs roughly two orders of magnitude less than a thread stack)
--      doesn't require this specific demo to reproduce exactly on every
--      host to still be true in general.

local BIN = os.getenv("FIBER_WORKER_POOL_BIN") or "/usr/local/bin/fiber_worker_pool"
local WORKERS = tonumber(os.getenv("FIBER_WORKER_POOL_WORKERS") or "8")
local ITEMS = tonumber(os.getenv("FIBER_WORKER_POOL_ITEMS") or "100000")

local function run(args)
    local cmd = BIN .. " " .. args
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

-- Closed-form sum of squares 1^2 + 2^2 + ... + n^2, computed independently
-- of the C++ program so this is a real check, not an echo of its own claim.
local function expected_sum_of_squares(n)
    return n * (n + 1) * (2 * n + 1) // 6
end

print(string.format(
    "== verify.lua: 13-fiber-worker-pool -- workers=%d, items=%d ==",
    WORKERS, ITEMS))

local hard_failures = 0
local rss = {}

local function check_pool_run(mode)
    local args = string.format("pool --mode %s --workers %d --items %d", mode, WORKERS, ITEMS)
    local ok, output = pcall(run, args)
    if not ok then
        print(string.format("  FAIL: %s run errored: %s", mode, tostring(output)))
        hard_failures = hard_failures + 1
        return
    end

    local processed = tonumber(output:match("processed=(%d+)"))
    local sum = tonumber(output:match("sum=(%d+)"))
    local elapsed = tonumber(output:match("elapsed_ms=([%d%.]+)"))
    local rss_kb = tonumber(output:match("rss_kb=(%d+)"))

    if not (processed and sum and elapsed) then
        print(string.format("  FAIL: could not parse %s run output:\n%s", mode, output))
        hard_failures = hard_failures + 1
        return
    end

    print(string.format(
        "  [%-6s] processed=%d sum=%d elapsed_ms=%.3f rss_kb=%s",
        mode, processed, sum, elapsed, tostring(rss_kb)))

    if processed ~= ITEMS then
        print(string.format(
            "  FAIL: %s processed=%d, expected exactly %d (items lost or double-counted)",
            mode, processed, ITEMS))
        hard_failures = hard_failures + 1
    end

    local expected_sum = expected_sum_of_squares(ITEMS)
    if sum ~= expected_sum then
        print(string.format(
            "  FAIL: %s sum=%d, expected %d (sum of squares 1..%d)",
            mode, sum, expected_sum, ITEMS))
        hard_failures = hard_failures + 1
    end

    rss[mode] = rss_kb
end

check_pool_run("fiber")
check_pool_run("thread")

if hard_failures == 0 then
    print("  correctness: PASS (both fiber and thread pools processed every item exactly once " ..
          "with the correct aggregate)")
end

-- Guard-page: deterministic, so this is a hard assertion.
local ok, gp_output = pcall(run, "guard-page")
if not ok then
    print("  FAIL: guard-page run errored: " .. tostring(gp_output))
    hard_failures = hard_failures + 1
else
    print("  [guard-page] " .. gp_output:gsub("%s+$", ""))
    local signaled = gp_output:match("guard_page_signaled=(%a+)")
    local signal = tonumber(gp_output:match("guard_page_signal=(%d+)"))
    local timed_out = gp_output:match("guard_page_timed_out=(%a+)")

    if not (signaled and signal and timed_out) then
        print("  FAIL: could not parse guard-page output:\n" .. gp_output)
        hard_failures = hard_failures + 1
    else
        if timed_out ~= "false" then
            print("  FAIL: guard-page case timed out instead of terminating on the guard page")
            hard_failures = hard_failures + 1
        end
        if signaled ~= "true" or signal < 1 then
            print(string.format(
                "  FAIL: guard-page case did not terminate via signal as expected " ..
                "(signaled=%s signal=%s) -- protected_fixedsize_stack should turn this " ..
                "overflow into an immediate SIGSEGV",
                tostring(signaled), tostring(signal)))
            hard_failures = hard_failures + 1
        else
            print(string.format(
                "  guard page: PASS (overflow terminated the child via signal %d within the timeout)",
                signal))
        end
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d hard failure(s))", hard_failures))
    os.exit(1)
end

-- SOFT — RSS comparison, informational only.
if rss.fiber and rss.thread and rss.fiber > 0 and rss.thread > 0 then
    print(string.format("  RSS (peak, KiB): fiber=%d thread=%d", rss.fiber, rss.thread))
    if rss.fiber < rss.thread then
        local ratio = rss.thread / rss.fiber
        print(string.format(
            "  RSS: PASS (fiber pool's peak RSS is %.1fx lower than the thread pool's)", ratio))
    else
        print(
            "  RSS: WARN (fiber pool's peak RSS was not lower than the thread pool's on this run " ..
            "-- at this worker/item count, allocator and container memory-accounting noise can " ..
            "dominate the fiber-vs-thread stack-size difference; correctness still holds, see above)")
    end
else
    print("  RSS: WARN (could not read /proc/self/status peak RSS for one or both modes -- " ..
          "informational only, not fatal)")
end

print("RESULT: PASS")
os.exit(0)
