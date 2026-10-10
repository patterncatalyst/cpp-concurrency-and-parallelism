#!/usr/bin/env lua5.4
-- concurrency/18-benchmarking-without-deception — verify.lua
--
-- This chapter's own harness, run against a deliberately trivial workload
-- (one atomic fetch_add per iteration), so every number in its own output
-- can be checked against a REAL invariant rather than trusted on faith.
-- Every check below is HARD: co_p99 >= p99 and co_n >= n are true by
-- construction of the backfill algorithm, checksum correctness is
-- deterministic arithmetic over a single-threaded fetch_add sequence, and
-- --naive's missing percentile fields are a direct property of which code
-- path ran. There is no SOFT half in this example -- the methodology
-- under test makes a correctness claim about its own bookkeeping, not a
-- performance claim a noisy host could mute. (Never a fixed nanosecond
-- number anywhere below, per this project's benchmarking convention.)

local BIN = os.getenv("BENCH_BIN") or "/usr/local/bin/bench"
local ITERS = tonumber(os.getenv("BENCH_ITERS") or "50000")
local WARMUP = tonumber(os.getenv("BENCH_WARMUP") or "5000")

local function run(args)
    local cmd = string.format("%s %s", BIN, args)
    local handle, perr = io.popen(cmd .. " 2>&1")
    if not handle then
        error(string.format("failed to launch %q: %s", cmd, tostring(perr)))
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
    if not ok then
        error(string.format("command failed (%s %s): %s\n--- output ---\n%s",
            tostring(why), tostring(code), cmd, output))
    end
    return output
end

print(string.format(
    "== verify.lua: 18-benchmarking-without-deception -- iters=%d warmup=%d ==",
    ITERS, WARMUP))

local hard_failures = 0
local function fail(msg)
    print("  FAIL: " .. msg)
    hard_failures = hard_failures + 1
end

-- 1. Default harness mode: percentile ordering, coordinated-omission
-- invariant, and checksum correctness.
local ok, harness_out = pcall(run, string.format("--iters %d --warmup %d", ITERS, WARMUP))
if not ok then
    fail("harness mode errored: " .. tostring(harness_out))
else
    print("  [harness] " .. harness_out:gsub("%s+$", ""))

    local n = tonumber(harness_out:match("mode=harness n=(%d+)"))
    local min_ns = tonumber(harness_out:match("min_ns=(%-?%d+)"))
    local median_ns = tonumber(harness_out:match("median_ns=(%-?%d+)"))
    local p99_ns = tonumber(harness_out:match("p99_ns=(%-?%d+)"))
    local max_ns = tonumber(harness_out:match("max_ns=(%-?%d+)"))
    local co_p99_ns = tonumber(harness_out:match("co_p99_ns=(%-?%d+)"))
    local co_n = tonumber(harness_out:match("co_n=(%d+)"))
    local checksum = harness_out:match("checksum=(%d+)")
    local expected_checksum = harness_out:match("expected_checksum=(%d+)")
    local checksum_ok = harness_out:match("checksum_ok=(%a+)")

    if not (n and min_ns and median_ns and p99_ns and max_ns and co_p99_ns and co_n
            and checksum and expected_checksum and checksum_ok) then
        fail("could not parse harness output fields")
    else
        if n ~= ITERS then
            fail(string.format("n=%d does not match requested --iters %d", n, ITERS))
        end

        if min_ns <= median_ns and median_ns <= p99_ns and p99_ns <= max_ns then
            print(string.format(
                "  percentile ordering: PASS (min=%d <= median=%d <= p99=%d <= max=%d)",
                min_ns, median_ns, p99_ns, max_ns))
        else
            fail(string.format(
                "percentiles out of order: min=%d median=%d p99=%d max=%d",
                min_ns, median_ns, p99_ns, max_ns))
        end

        if co_p99_ns >= p99_ns then
            print(string.format(
                "  coordinated-omission invariant: PASS (co_p99_ns=%d >= p99_ns=%d)",
                co_p99_ns, p99_ns))
        else
            fail(string.format(
                "coordinated-omission invariant violated: co_p99_ns=%d < p99_ns=%d",
                co_p99_ns, p99_ns))
        end

        if co_n >= n then
            print(string.format("  co_n: PASS (co_n=%d >= n=%d)", co_n, n))
        else
            fail(string.format(
                "co_n=%d is less than n=%d (backfill should never shrink the sample set)",
                co_n, n))
        end

        if checksum == expected_checksum and checksum_ok == "true" then
            print(string.format(
                "  checksum: PASS (%s matches the closed-form expected sum)", checksum))
        else
            fail(string.format(
                "checksum mismatch: got checksum=%s expected_checksum=%s checksum_ok=%s",
                checksum, expected_checksum, checksum_ok))
        end
    end
end

-- 2. --naive mode: no warmup, a single unwarmed sample, no percentile
-- field of any kind in the output -- the methodology gap made visible.
local ok2, naive_out = pcall(run, string.format("--naive --iters %d", ITERS))
if not ok2 then
    fail("--naive mode errored: " .. tostring(naive_out))
else
    print("  [naive]   " .. naive_out:gsub("%s+$", ""))

    local mode = naive_out:match("mode=(%a+)")
    if mode ~= "naive" then
        fail("expected mode=naive in --naive output, got: " .. tostring(mode))
    end

    if naive_out:find("p99_ns=") or naive_out:find("median_ns=") or naive_out:find("co_p99_ns=")
            or naive_out:find("min_ns=") or naive_out:find("max_ns=") then
        fail("--naive output contains a percentile field it should never compute: " .. naive_out)
    else
        print("  --naive omits percentiles: PASS (no min/median/p99/max/co_p99 fields present)")
    end

    local naive_checksum = naive_out:match("checksum=(%d+)")
    local naive_expected = naive_out:match("expected_checksum=(%d+)")
    local naive_checksum_ok = naive_out:match("checksum_ok=(%a+)")
    if naive_checksum and naive_expected and naive_checksum_ok then
        if naive_checksum == naive_expected and naive_checksum_ok == "true" then
            print(string.format(
                "  --naive checksum: PASS (%s matches the closed-form expected sum)",
                naive_checksum))
        else
            fail(string.format(
                "--naive checksum mismatch: checksum=%s expected_checksum=%s checksum_ok=%s",
                naive_checksum, naive_expected, naive_checksum_ok))
        end
    else
        fail("could not parse --naive checksum fields")
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
