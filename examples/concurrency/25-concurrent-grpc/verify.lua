#!/usr/bin/env lua5.4
-- concurrency/25-concurrent-grpc — verify.lua
--
-- Runs BOTH async_server and concurrent_client inside this one container
-- (no compose, no second container -- the two dial each other over
-- 127.0.0.1): starts the server in the background, drives the client
-- through two phases, then signals the server to drain and checks it
-- exited cleanly. Exits 0 on pass, non-zero on any hard failure, printing
-- a readable summary either way (same contract every verify.lua in this
-- project follows -- see 20-mechanical-sympathy/verify.lua).
--
-- What this checks:
--
--   1. (hard) Phase A, calls == cap: every call must succeed (OK) with
--      exactly repeat_count messages; RESOURCE_EXHAUSTED must not appear
--      while strictly at or under the cap.
--   2. (hard) Phase B, calls == cap + overflow: every attempted RPC must
--      terminate with OK or RESOURCE_EXHAUSTED -- no other status, no
--      missing output line (which would mean a hang or a dropped call).
--      The number of OK calls must never exceed cap (the cap is a hard
--      ceiling on concurrent admission); RESOURCE_EXHAUSTED must appear
--      at least once (otherwise the test never actually exercised the
--      cap); ok_count + resource_exhausted_count must equal the number of
--      calls attempted (accounting must be exact, not approximate); every
--      OK call must have exactly repeat_count messages and every
--      RESOURCE_EXHAUSTED call must have zero (no partially-streamed-then-
--      dropped calls).
--   3. (hard) The server must drain and exit 0 within a bounded time of
--      receiving SIGTERM -- proof the per-completion-queue Shutdown()+
--      drain loop actually terminates rather than abandoning tags.
--   4. (soft) Phase B's average OK-call latency shouldn't be dramatically
--      higher than Phase A's. Pacing is timer-driven (grpc::Alarm), not
--      contention-driven, so load shouldn't move it much -- but this is
--      reported as a WARN, not a failure, since a busy shared CI host can
--      still add scheduling noise to thread start-up and the final Finish
--      round trip.

local SERVER_BIN = os.getenv("ASYNC_SERVER_BIN") or "/usr/local/bin/async_server"
local CLIENT_BIN = os.getenv("CONCURRENT_CLIENT_BIN") or "/usr/local/bin/concurrent_client"
local ADDR = os.getenv("ECHO_ADDR") or "127.0.0.1:50051"

local CAP = tonumber(os.getenv("ECHO_CAP") or "4")
local OVERFLOW = tonumber(os.getenv("ECHO_OVERFLOW") or "8")
local REPEAT_COUNT = tonumber(os.getenv("ECHO_REPEAT_COUNT") or "10")
local PACING_MS = tonumber(os.getenv("ECHO_PACING_MS") or "50")
local CLIENT_DEADLINE_MS = tonumber(os.getenv("ECHO_CLIENT_DEADLINE_MS") or "5000")

local SERVER_PID_FILE = "/tmp/async_server.pid"
local SERVER_EXIT_FILE = "/tmp/async_server.exit"
local SERVER_LOG_FILE = "/tmp/async_server.log"

print(string.format(
    "== verify.lua: 25-concurrent-grpc -- cap=%d overflow=%d repeat_count=%d pacing_ms=%d ==",
    CAP, OVERFLOW, REPEAT_COUNT, PACING_MS))

local hard_failures = 0
local function fail(msg)
    print("  FAIL: " .. msg)
    hard_failures = hard_failures + 1
end

-- ── Start the server in the background, capturing its PID and (later)
--    its own exit code to files -- plain shell, no Lua process library
--    needed. ──
-- Background the server DIRECTLY (so the recorded PID is the server itself,
-- not a wrapping subshell that wouldn't forward SIGTERM), then a waiter in the
-- same backgrounded shell records the server's own exit code once it drains.
os.execute(string.format(
    "rm -f %s %s %s; sh -c '%s --listen %s --cap %d --pacing-ms %d >%s 2>&1 & " ..
    "p=$!; echo $p >%s; wait $p; echo $? >%s' &",
    SERVER_PID_FILE, SERVER_EXIT_FILE, SERVER_LOG_FILE,
    SERVER_BIN, ADDR, CAP, PACING_MS,
    SERVER_LOG_FILE, SERVER_PID_FILE, SERVER_EXIT_FILE))

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end

local server_pid
for _ = 1, 50 do
    server_pid = (read_file(SERVER_PID_FILE) or ""):match("%d+")
    if server_pid then break end
    os.execute("sleep 0.1")
end
if not server_pid then
    fail("could not read server PID from " .. SERVER_PID_FILE)
    print("RESULT: FAIL (1 correctness/execution failure(s))")
    os.exit(1)
end
print("  server pid=" .. server_pid)

-- ── Run concurrent_client once, parse its per-call lines. ──
local function run_client(calls)
    local cmd = string.format(
        "%s --addr %s --calls %d --repeat-count %d --deadline-ms %d 2>&1",
        CLIENT_BIN, ADDR, calls, REPEAT_COUNT, CLIENT_DEADLINE_MS)
    local handle, perr = io.popen(cmd)
    if not handle then
        error(string.format("failed to launch %q: %s", cmd, tostring(perr)))
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
    if not ok then
        error(string.format(
            "concurrent_client failed (%s %s):\n--- output ---\n%s",
            tostring(why), tostring(code), output))
    end
    return output
end

-- Parses "call=<idx> status=<WORD> code=<n> messages=<n> elapsed_ms=<f>"
-- lines into a table of records, plus aggregate counts.
local function parse_calls(output)
    local records = {}
    local ok_count, re_count, other_count = 0, 0, 0
    for idx, status, code, messages, elapsed in
        output:gmatch("call=(%d+) status=([%u_]+) code=(%d+) messages=(%d+) elapsed_ms=([%d%.]+)") do
        local rec = {
            idx = tonumber(idx),
            status = status,
            code = tonumber(code),
            messages = tonumber(messages),
            elapsed_ms = tonumber(elapsed),
        }
        table.insert(records, rec)
        if status == "OK" then
            ok_count = ok_count + 1
        elseif status == "RESOURCE_EXHAUSTED" then
            re_count = re_count + 1
        else
            other_count = other_count + 1
        end
    end
    return records, ok_count, re_count, other_count
end

-- ── Phase A: calls == cap. Nothing should be rejected. ──
print(string.format("  [phase A] launching %d concurrent calls (== cap)", CAP))
local okA, outputA = pcall(run_client, CAP)
local phaseA_ok_elapsed = {}
if not okA then
    fail("phase A client errored: " .. tostring(outputA))
else
    local records, ok_count, re_count, other_count = parse_calls(outputA)
    print(string.format(
        "  [phase A] parsed=%d ok=%d resource_exhausted=%d other=%d",
        #records, ok_count, re_count, other_count))

    if #records ~= CAP then
        fail(string.format(
            "phase A: expected %d call results, got %d (a call hung or produced no output line)",
            CAP, #records))
    end
    if other_count ~= 0 then
        fail(string.format("phase A: %d call(s) returned a status other than OK/RESOURCE_EXHAUSTED", other_count))
    end
    if re_count ~= 0 then
        fail(string.format(
            "phase A: %d call(s) got RESOURCE_EXHAUSTED at or under cap=%d -- cap is too aggressive",
            re_count, CAP))
    end
    if ok_count ~= CAP then
        fail(string.format("phase A: expected all %d calls OK, got %d", CAP, ok_count))
    end
    for _, rec in ipairs(records) do
        if rec.status == "OK" and rec.messages ~= REPEAT_COUNT then
            fail(string.format(
                "phase A: call=%d OK but messages=%d (expected %d) -- partial stream",
                rec.idx, rec.messages, REPEAT_COUNT))
        end
        if rec.status == "OK" then
            table.insert(phaseA_ok_elapsed, rec.elapsed_ms)
        end
    end
end

-- ── Phase B: calls == cap + overflow. Some must be rejected. ──
local phaseB_calls = CAP + OVERFLOW
print(string.format(
    "  [phase B] launching %d concurrent calls (cap=%d + overflow=%d)",
    phaseB_calls, CAP, OVERFLOW))
local okB, outputB = pcall(run_client, phaseB_calls)
local phaseB_ok_elapsed = {}
if not okB then
    fail("phase B client errored: " .. tostring(outputB))
else
    local records, ok_count, re_count, other_count = parse_calls(outputB)
    print(string.format(
        "  [phase B] parsed=%d ok=%d resource_exhausted=%d other=%d",
        #records, ok_count, re_count, other_count))

    if #records ~= phaseB_calls then
        fail(string.format(
            "phase B: expected %d call results, got %d (a call hung or produced no output line)",
            phaseB_calls, #records))
    end
    if other_count ~= 0 then
        fail(string.format("phase B: %d call(s) returned a status other than OK/RESOURCE_EXHAUSTED", other_count))
    end
    if ok_count > CAP then
        fail(string.format(
            "phase B: %d calls were admitted concurrently, exceeding cap=%d",
            ok_count, CAP))
    end
    if re_count == 0 then
        fail("phase B: no call got RESOURCE_EXHAUSTED -- the cap was never exercised")
    end
    if ok_count + re_count ~= #records then
        fail(string.format(
            "phase B: ok(%d) + resource_exhausted(%d) != total calls(%d) -- accounting mismatch",
            ok_count, re_count, #records))
    end
    for _, rec in ipairs(records) do
        if rec.status == "OK" and rec.messages ~= REPEAT_COUNT then
            fail(string.format(
                "phase B: call=%d OK but messages=%d (expected %d) -- partial stream",
                rec.idx, rec.messages, REPEAT_COUNT))
        elseif rec.status == "RESOURCE_EXHAUSTED" and rec.messages ~= 0 then
            fail(string.format(
                "phase B: call=%d RESOURCE_EXHAUSTED but messages=%d (expected 0) -- streamed before rejecting",
                rec.idx, rec.messages))
        end
        if rec.status == "OK" then
            table.insert(phaseB_ok_elapsed, rec.elapsed_ms)
        end
    end
end

-- ── Shut the server down and verify it drains + exits cleanly. ──
print("  sending SIGTERM to server pid=" .. server_pid)
os.execute("kill -TERM " .. server_pid .. " 2>/dev/null")

local drained, server_exit_code = false, nil
for _ = 1, 100 do  -- up to ~10s
    local content = read_file(SERVER_EXIT_FILE)
    if content and content:match("%d+") then
        server_exit_code = tonumber(content:match("%d+"))
        drained = true
        break
    end
    os.execute("sleep 0.1")
end

if not drained then
    fail("server did not exit within 10s of SIGTERM (did not drain cleanly)")
    os.execute("kill -KILL " .. server_pid .. " 2>/dev/null")
else
    print("  server exited with code=" .. tostring(server_exit_code))
    if server_exit_code ~= 0 then
        fail("server exited non-zero (" .. tostring(server_exit_code) .. ") after SIGTERM")
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness/execution failure(s))", hard_failures))
    local log = read_file(SERVER_LOG_FILE)
    if log then
        print("--- server log ---")
        print(log)
    end
    os.exit(1)
end

print("  correctness: PASS (bounded admission holds in both phases; server drained cleanly)")

-- ── Soft: Phase B latency shouldn't be dramatically worse than Phase A's. ──
local function average(values)
    if #values == 0 then return nil end
    local sum = 0
    for _, v in ipairs(values) do sum = sum + v end
    return sum / #values
end

local avgA = average(phaseA_ok_elapsed)
local avgB = average(phaseB_ok_elapsed)
if not avgA or not avgB then
    print("  timing: WARN (not enough OK samples in one phase to compare latency)")
else
    local ratio = avgB / avgA
    print(string.format(
        "  avg elapsed_ms (OK calls): phase A=%.1f phase B=%.1f (ratio %.2fx)",
        avgA, avgB, ratio))
    if ratio <= 2.0 then
        print("  timing: PASS (admitted-call latency stayed roughly flat under overload)")
    else
        print(string.format(
            "  timing: WARN (phase B admitted-call latency was %.2fx phase A's, " ..
            "above the 2x informational threshold). Pacing is timer-driven " ..
            "(grpc::Alarm), not contention-driven, so this is informational, " ..
            "not a correctness signal -- a busy shared host can still add " ..
            "scheduling noise to thread start-up and the final round trip.",
            ratio))
    end
end

print("RESULT: PASS")
os.exit(0)
