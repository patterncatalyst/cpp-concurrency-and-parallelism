#!/usr/bin/env lua5.4
-- concurrency/11-coroutines-in-depth — verify.lua
--
-- Follows this project's assertion-harness contract (see
-- 20-mechanical-sympathy/verify.lua): plain Lua 5.4, no required
-- arguments, FALSE_SHARING-style env var override for the binary path,
-- readable summary to stdout, exit 0 on pass (WARN allowed for a soft
-- assertion), non-zero on any hard failure.
--
-- What this example checks:
--   1. HARD — Generator<T> (fibonacci(), hand-rolled co_yield sequence)
--      produces EXACTLY the first 10 Fibonacci terms, consumed via a
--      range-for + break. Any mismatch means the generator's promise_type
--      (yield_value, the iterator's done()/resume() handling) is broken.
--   2. HARD — Task<T> (compute(), two co_await'd add_one() sub-tasks
--      chained through symmetric transfer in FinalAwaiter) returns
--      EXACTLY the expected value (10+1=11, 11+1=12, 11+12=23). Any
--      mismatch means the symmetric-transfer handoff or the promise's
--      return_value/continuation plumbing is broken.
--   3. SOFT — the HALO (Heap Allocation eLision Optimization) frame-size
--      observation (tiny probe vs. a probe carrying a 4 KiB buffer across
--      a real suspension point) is reported but never asserted against a
--      fixed expectation: the standard only PERMITS eliding the frame
--      allocation when the compiler can prove it doesn't outlive the
--      caller ([dcl.fct.def.coroutine]: "may", not "shall") — whether a
--      given toolchain actually takes that opportunity, for either probe,
--      is exactly the thing this chapter says to measure rather than
--      assume. A surprising result here is informational, not a failure.

local BIN = os.getenv("COROUTINES_IN_DEPTH_BIN") or "/usr/local/bin/coroutines_in_depth"

local EXPECTED_FIB = {0, 1, 1, 2, 3, 5, 8, 13, 21, 34}
local EXPECTED_TASK_RESULT = 23

local function run()
    local handle, perr = io.popen(BIN .. " 2>&1")
    if not handle then
        error(string.format("failed to launch %q: %s", BIN, tostring(perr)))
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
    if not ok then
        error(string.format(
            "command failed (%s %s): %s\n--- output ---\n%s",
            tostring(why), tostring(code), BIN, output))
    end
    return output
end

print("== verify.lua: 11-coroutines-in-depth (generator, Task<T>, HALO) ==")

local hard_failures = 0

local ok, output = pcall(run)
if not ok then
    print("  FAIL: " .. tostring(output))
    print("RESULT: FAIL (1 execution failure)")
    os.exit(1)
end

print("--- program output ---")
for line in output:gmatch("[^\n]+") do
    print("  " .. line)
end
print("----------------------")

-- 1. HARD — generator sequence, exact match.
local seq_str = output:match("generator_sequence=([%d,]+)")
if not seq_str then
    print("  FAIL: could not find generator_sequence= in output")
    hard_failures = hard_failures + 1
else
    local got = {}
    for n in seq_str:gmatch("%d+") do
        table.insert(got, tonumber(n))
    end
    if #got ~= #EXPECTED_FIB then
        print(string.format(
            "  FAIL: generator produced %d terms, expected %d (%s)",
            #got, #EXPECTED_FIB, seq_str))
        hard_failures = hard_failures + 1
    else
        local mismatch = false
        for i, v in ipairs(EXPECTED_FIB) do
            if got[i] ~= v then
                mismatch = true
                print(string.format(
                    "  FAIL: generator term %d = %d, expected %d", i, got[i], v))
            end
        end
        if mismatch then
            hard_failures = hard_failures + 1
        else
            print(string.format(
                "  correctness: PASS (generator produced the exact first %d Fibonacci terms)",
                #EXPECTED_FIB))
        end
    end
end

-- 2. HARD — Task<T> result, exact match.
local task_result = tonumber(output:match("task_result=(%-?%d+)"))
if not task_result then
    print("  FAIL: could not find task_result= in output")
    hard_failures = hard_failures + 1
elseif task_result ~= EXPECTED_TASK_RESULT then
    print(string.format(
        "  FAIL: task_result=%d, expected %d", task_result, EXPECTED_TASK_RESULT))
    hard_failures = hard_failures + 1
else
    print(string.format(
        "  correctness: PASS (Task<T> chain returned the expected %d via symmetric transfer)",
        EXPECTED_TASK_RESULT))
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness failure(s))", hard_failures))
    os.exit(1)
end

-- 3. SOFT — HALO frame-size observation, informational only.
local tiny_allocs = tonumber(output:match("tiny_frame_allocs=(%d+)"))
local tiny_bytes = tonumber(output:match("tiny_frame_bytes=(%d+)"))
local fat_allocs = tonumber(output:match("fat_frame_allocs=(%d+)"))
local fat_bytes = tonumber(output:match("fat_frame_bytes=(%d+)"))
local fat_buffer_bytes = tonumber(output:match("fat_buffer_bytes=(%d+)"))

if not (tiny_allocs and tiny_bytes and fat_allocs and fat_bytes and fat_buffer_bytes) then
    print("  WARN: could not parse HALO frame-size observation lines (non-fatal — informational only)")
else
    print(string.format(
        "  HALO: tiny probe — %d allocation(s), %d byte(s) requested per allocation",
        tiny_allocs, tiny_bytes))
    print(string.format(
        "  HALO: fat probe (carries a %d-byte buffer across a real co_await) — " ..
        "%d allocation(s), %d byte(s) requested per allocation",
        fat_buffer_bytes, fat_allocs, fat_bytes))

    if tiny_allocs == 0 then
        print("  HALO note: tiny probe's frame allocation was fully elided on this toolchain/level.")
    end
    if fat_allocs == 0 then
        print("  HALO note: fat probe's frame allocation was fully elided on this toolchain/level " ..
              "(carrying state across a real suspension point did not prevent elision here).")
    elseif fat_bytes < fat_buffer_bytes then
        print(string.format(
            "  HALO note: fat probe's reported frame (%d bytes) is smaller than its buffer " ..
            "(%d bytes) — unexpected but non-fatal; HALO/allocator behavior is a toolchain " ..
            "property this chapter says to measure, not assume.",
            fat_bytes, fat_buffer_bytes))
    else
        print("  HALO: fat probe's frame was not elided and is at least as large as its buffer, " ..
              "as expected when a toolchain declines the elision opportunity here.")
    end
end

print("RESULT: PASS")
os.exit(0)
