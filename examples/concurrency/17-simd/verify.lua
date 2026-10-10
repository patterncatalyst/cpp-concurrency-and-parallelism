#!/usr/bin/env lua5.4
-- concurrency/17-simd — verify.lua
--
-- Plain Lua 5.4, no external modules, run once inside the demo's container
-- against the binary that same image just built (this project's assertion
-- harness convention — see 20-mechanical-sympathy/verify.lua for the
-- original statement of it).
--
-- simd_particles prints one simd_width= header line, then one layout= line
-- per update variant (aos_scalar, soa_scalar, soa_simd) with a time_ms and
-- a hash of the final particle positions. What this harness checks, across
-- several trials:
--
--   correctness (HARD) -- all three variants' position hashes must be
--     IDENTICAL, every trial. The update is a pure per-particle recurrence
--     with no cross-particle interaction, compiled without -march flags
--     that would enable hardware FMA, so scalar and
--     std::experimental::simd perform the exact same sequence of
--     multiply-then-add operations per particle -- bit-identical, not
--     merely close. Any mismatch here means the SIMD path (or the layout
--     conversion) actually changed the computation, which is a bug.
--   speed (SOFT) -- soa_simd's time_ms should be lower than soa_scalar's
--     (same layout, same arithmetic, only the explicit vectorization
--     differs). If it isn't -- noise, a simd_width of 1 (meaning this
--     build/CPU combination exposes no real vector lanes), or a busy
--     shared host -- verify.lua prints a WARN and still passes.
--     Correctness (checked above) is unaffected either way, and no
--     specific speedup ratio is ever asserted.
--
-- Exits 0 on pass (WARN allowed inside a pass). Exits non-zero, printing a
-- line starting "FAIL"/"RESULT: FAIL", on any hard failure: binary missing,
-- output unparseable, or a hash that doesn't match across variants or
-- trials.

local BIN = os.getenv("SIMD_PARTICLES_BIN") or "/usr/local/bin/simd_particles"
local TRIALS = tonumber(os.getenv("SIMD_PARTICLES_TRIALS") or "3")
local N = tonumber(os.getenv("SIMD_PARTICLES_N") or "2000000")
local STEPS = tonumber(os.getenv("SIMD_PARTICLES_STEPS") or "50")
local NOISE_THRESHOLD_PCT = 5.0 -- below this, call the timing result noise

local LAYOUTS = { "aos_scalar", "soa_scalar", "soa_simd" }

local function run_once()
    local cmd = string.format("%s -n %d -s %d", BIN, N, STEPS)
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

    local simd_width = tonumber(output:match("simd_width=(%d+)"))
    if not simd_width then
        error("could not parse simd_width from output:\n" .. output)
    end

    local layouts = {}
    for layout, time_ms, hash in
        output:gmatch("layout=([%a_]+)%s+time_ms=([%d%.]+) hash=(%x+)") do
        layouts[layout] = { time_ms = tonumber(time_ms), hash = hash }
    end

    for _, name in ipairs(LAYOUTS) do
        if not layouts[name] then
            error("could not parse layout=" .. name .. " line from output:\n" .. output)
        end
    end

    return simd_width, layouts
end

print(string.format(
    "== verify.lua: 17-simd -- n=%d steps=%d trials=%d ==", N, STEPS, TRIALS))

local hard_failures = 0
local min_simd_width = math.huge
local soa_scalar_times = {}
local soa_simd_times = {}
local reference_hash

for trial = 1, TRIALS do
    local ok, simd_width, layouts = pcall(run_once)
    if not ok then
        print("  FAIL: trial " .. trial .. " errored: " .. tostring(simd_width))
        hard_failures = hard_failures + 1
    else
        min_simd_width = math.min(min_simd_width, simd_width)
        print(string.format("  [trial %d] simd_width=%d", trial, simd_width))
        for _, name in ipairs(LAYOUTS) do
            local l = layouts[name]
            print(string.format(
                "    layout=%-10s time_ms=%9.3f hash=%s", name, l.time_ms, l.hash))
        end

        -- Hard: all three layouts must agree exactly with each other.
        local reference = layouts.aos_scalar
        for _, name in ipairs({ "soa_scalar", "soa_simd" }) do
            local l = layouts[name]
            if l.hash ~= reference.hash then
                print(string.format(
                    "  FAIL: trial %d %s hash=%s differs from aos_scalar hash=%s",
                    trial, name, l.hash, reference.hash))
                hard_failures = hard_failures + 1
            end
        end

        -- Hard: deterministic across trials too (fixed seed, fixed n/steps).
        if reference_hash == nil then
            reference_hash = reference.hash
        elseif reference.hash ~= reference_hash then
            print(string.format(
                "  FAIL: trial %d aos_scalar hash=%s differs from trial 1's %s " ..
                "(expected deterministic for a fixed seed/n/steps)",
                trial, reference.hash, reference_hash))
            hard_failures = hard_failures + 1
        end

        table.insert(soa_scalar_times, layouts.soa_scalar.time_ms)
        table.insert(soa_simd_times, layouts.soa_simd.time_ms)
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness failure(s))", hard_failures))
    os.exit(1)
end

print("  correctness: PASS (aos_scalar/soa_scalar/soa_simd agree exactly, every trial)")

local function average(values)
    local sum = 0
    for _, v in ipairs(values) do sum = sum + v end
    return sum / #values
end

if #soa_scalar_times == 0 or #soa_simd_times == 0 then
    print("RESULT: FAIL (no timing samples collected)")
    os.exit(1)
end

local avg_scalar = average(soa_scalar_times)
local avg_simd = average(soa_simd_times)
local improvement_pct = (avg_scalar - avg_simd) / avg_scalar * 100.0

print(string.format(
    "  avg time_ms: soa_scalar=%.3f soa_simd=%.3f (simd is %.1f%% %s)",
    avg_scalar, avg_simd, math.abs(improvement_pct),
    improvement_pct >= 0 and "faster" or "slower"))

if min_simd_width <= 1 then
    print(string.format(
        "  speed: WARN (simd_width=%d -- this build/CPU combination exposes no real " ..
        "vector lanes, so std::experimental::simd can't do better than a scalar loop " ..
        "here regardless of how correct the code is. Correctness still holds, checked " ..
        "above.)",
        min_simd_width))
elseif improvement_pct >= NOISE_THRESHOLD_PCT then
    print(string.format(
        "  speed: PASS (soa_simd averaged %.1f%% faster than soa_scalar, clearing " ..
        "the %.1f%% noise floor, simd_width=%d)",
        improvement_pct, NOISE_THRESHOLD_PCT, min_simd_width))
else
    print(string.format(
        "  speed: WARN (soa_simd was only %.1f%% faster/slower than soa_scalar, " ..
        "within the %.1f%% noise floor, at simd_width=%d). A busy shared host, a " ..
        "narrow vector width, or a workload too small to amortize per-call overhead " ..
        "can all mute this signal without making the SIMD path wrong. Correctness " ..
        "still holds (checked above) -- see README.",
        improvement_pct, NOISE_THRESHOLD_PCT, min_simd_width))
end

print("RESULT: PASS")
os.exit(0)
