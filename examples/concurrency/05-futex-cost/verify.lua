#!/usr/bin/env lua5.4
-- concurrency/05-futex-cost — verify.lua
--
-- Plain Lua 5.4, no external modules, run inside the demo's container
-- against the binary that same image built (the project's verify.lua
-- convention -- see examples/concurrency/20-mechanical-sympathy/verify.lua
-- for the reference).
--
-- What this checks:
--   1. Correctness (HARD). The final count must equal N exactly in all
--      three modes -- baseline, uncontended, contended. Contention changes
--      performance, never arithmetic; any mismatch here is a real bug in
--      the demo program and fails the run outright.
--   2. The futex story (SOFT). Chapter 5's claim is that an uncontended
--      mutex's futex(2) call count matches a program with no mutex at all,
--      while a contended mutex's count is orders of magnitude higher. This
--      is checked by running each mode under `strace -f -e trace=futex`
--      from OUTSIDE the binary and counting "futex(" occurrences in the
--      trace. It is inherently scheduling-dependent (and strace itself may
--      be unavailable, or unable to attach under a locked-down container
--      runtime -- see the chapter's "Running in a container" discussion),
--      so every assertion here is WARN-not-FAIL. If strace isn't usable at
--      all, this falls back to a behavioral/timing comparison instead of
--      skipping the check silently.

local BIN = os.getenv("FUTEX_COST_BIN") or "/usr/local/bin/futex_cost"
local N = tonumber(os.getenv("FUTEX_COST_N") or "200000")
local THREADS = tonumber(os.getenv("FUTEX_COST_THREADS") or "8")
local MULTIPLIER = tonumber(os.getenv("FUTEX_COST_MULTIPLIER") or "100")

-- Run one mode with no tracing; returns count, elapsed_ms. Raises a Lua
-- error (caught by the caller with pcall) on any launch/parse failure.
local function run_plain(mode)
    local cmd = string.format("%s --mode %s -n %d -t %d", BIN, mode, N, THREADS)
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
    local count = tonumber(output:match("count=(%d+)"))
    local elapsed = tonumber(output:match("elapsed_ms=([%d%.]+)"))
    if not (count and elapsed) then
        error("could not parse futex_cost output:\n" .. output)
    end
    return count, elapsed
end

-- Run one mode under `strace -f -e trace=futex`. Returns count, elapsed_ms,
-- futex_calls on success; returns nil (no error) if strace could not
-- produce parseable output, so the caller can fall back cleanly rather
-- than treating a restricted ptrace environment as a hard failure.
local function run_traced(mode)
    local cmd = string.format(
        "strace -f -e trace=futex %s --mode %s -n %d -t %d",
        BIN, mode, N, THREADS)
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then
        return nil
    end
    local output = handle:read("*a")
    handle:close() -- strace's own exit status isn't meaningful here; we
                    -- judge success by whether the program's own line made
                    -- it through.
    local count = tonumber(output:match("count=(%d+)"))
    local elapsed = tonumber(output:match("elapsed_ms=([%d%.]+)"))
    if not (count and elapsed) then
        return nil
    end
    local futex_calls = 0
    for _ in output:gmatch("futex%(") do
        futex_calls = futex_calls + 1
    end
    return count, elapsed, futex_calls
end

local function strace_available()
    local handle = io.popen("command -v strace 2>/dev/null")
    if not handle then
        return false
    end
    local path = handle:read("*a")
    handle:close()
    return path ~= nil and path:match("%S") ~= nil
end

-- Behavioral/timing fallback used whenever strace is missing or unable to
-- attach. Compares per-operation cost: elapsed_ms/N for the single-thread
-- uncontended run against (elapsed_ms * threads)/N for the contended run
-- -- a CPU-time-weighted approximation of per-increment cost, since
-- contended wall-clock time alone is confounded by the parallelism across
-- `threads` cores and isn't a clean stand-in for lock-contention overhead.
-- Always soft (WARN, never FAIL): a quiet/idle host can genuinely show no
-- measurable contention cost without the fix or the mechanism being wrong.
local function report_behavioral_fallback(elapsed_ms)
    print(string.format(
        "  [behavioral fallback] elapsed_ms: baseline=%.3f uncontended=%.3f contended=%.3f",
        elapsed_ms.baseline, elapsed_ms.uncontended, elapsed_ms.contended))
    local per_op_uncontended = elapsed_ms.uncontended / N
    local per_op_contended_cpu = (elapsed_ms.contended * THREADS) / N
    if per_op_contended_cpu > per_op_uncontended then
        print(string.format(
            "  per-op cost: contended (CPU-time-weighted) %.6f ms/op > " ..
            "uncontended %.6f ms/op: PASS (contention has real per-operation cost)",
            per_op_contended_cpu, per_op_uncontended))
    else
        print(string.format(
            "  per-op cost: contended (CPU-time-weighted) %.6f ms/op vs " ..
            "uncontended %.6f ms/op: WARN (no measurable contention cost " ..
            "on this host/run -- not a correctness problem)",
            per_op_contended_cpu, per_op_uncontended))
    end
end

print(string.format(
    "== verify.lua: 05-futex-cost -- N=%d, threads=%d ==", N, THREADS))

local hard_failures = 0
local modes = { "baseline", "uncontended", "contended" }
local counts = {}
local elapsed = {}

-- 1. Correctness -- hard, every mode, exact count.
for _, mode in ipairs(modes) do
    local ok, count_or_err, elapsed_ms = pcall(run_plain, mode)
    if not ok then
        print(string.format("  FAIL: mode=%s errored: %s", mode, tostring(count_or_err)))
        hard_failures = hard_failures + 1
    else
        local count = count_or_err
        print(string.format("  [%s] count=%d elapsed_ms=%.3f (expected count=%d)",
            mode, count, elapsed_ms, N))
        if count ~= N then
            print(string.format(
                "  FAIL: mode=%s count wrong (expected %d, got %d)", mode, N, count))
            hard_failures = hard_failures + 1
        end
        counts[mode] = count
        elapsed[mode] = elapsed_ms
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness/execution failure(s))", hard_failures))
    os.exit(1)
end

print("  correctness: PASS (baseline, uncontended, and contended all produced exact counts)")

-- 2. The futex story -- soft, strace if usable, behavioral fallback if not.
if strace_available() then
    print("  strace found -- attempting futex(2) call counts (soft assertions)")

    local futex_counts = {}
    local strace_ok = true
    for _, mode in ipairs(modes) do
        local count, elapsed_ms, futex_calls = run_traced(mode)
        if not count then
            strace_ok = false
            break
        end
        if count ~= N then
            -- Tracing itself must not change correctness; if it does,
            -- something about the environment (ptrace overhead, a
            -- sandboxed syscall filter) is interfering badly enough that
            -- the counts aren't trustworthy either. Fall back rather than
            -- report a misleading number.
            strace_ok = false
            break
        end
        futex_counts[mode] = futex_calls
        print(string.format("  [strace %s] futex_calls=%d count=%d elapsed_ms=%.3f",
            mode, futex_calls, count, elapsed_ms))
    end

    if strace_ok then
        local fb = futex_counts.baseline
        local fu = futex_counts.uncontended
        local fc = futex_counts.contended

        if fu == fb then
            print(string.format(
                "  futex(uncontended)=%d == futex(baseline)=%d: PASS " ..
                "(an uncontended lock never reaches the kernel)", fu, fb))
        else
            print(string.format(
                "  futex(uncontended)=%d vs futex(baseline)=%d: WARN " ..
                "(expected an exact match; small process-startup/thread-join " ..
                "variance can shift this by a handful of calls without the " ..
                "mechanism being any different -- see chapter 5)", fu, fb))
        end

        local threshold = fu * MULTIPLIER
        if fc > threshold then
            print(string.format(
                "  futex(contended)=%d > futex(uncontended)=%d * %d = %d: PASS " ..
                "(contention is what crosses into the kernel)", fc, fu, MULTIPLIER, threshold))
        else
            print(string.format(
                "  futex(contended)=%d vs threshold %d (uncontended=%d * %d): WARN " ..
                "(the orders-of-magnitude gap is scheduling-dependent -- a busy " ..
                "shared host, a container CPU quota, or very fast critical " ..
                "sections can all mute how often the compare-and-swap actually " ..
                "loses, without changing the mechanism). Correctness still holds.",
                fc, threshold, fu, MULTIPLIER))
        end
    else
        print("  strace ran but produced no usable trace (ptrace likely " ..
              "restricted by the container runtime) -- falling back to the " ..
              "behavioral/timing comparison instead of hard-failing on a " ..
              "tool availability problem")
    end

    if not strace_ok then
        report_behavioral_fallback(elapsed)
    end
else
    print("  strace not found in this image -- falling back to the " ..
          "behavioral/timing comparison instead of hard-failing on a " ..
          "missing tool (see Containerfile: strace install is best-effort)")
    report_behavioral_fallback(elapsed)
end

print("RESULT: PASS")
os.exit(0)
