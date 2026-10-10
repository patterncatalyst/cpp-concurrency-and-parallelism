#!/usr/bin/env lua5.4
-- concurrency/24-concurrent-rest — verify.lua
--
-- Follows this project's assertion-harness convention (see
-- 20-mechanical-sympathy/verify.lua): plain Lua 5.4, no external modules,
-- run once inside the demo's container. Unlike the batch-binary demos,
-- this one orchestrates a long-lived server process alongside two bounded
-- client runs, all inside this single verify.lua invocation:
--
--   1. Start rest_server in the background (output redirected to a log
--      file, never read through the Lua pipe -- see the io.popen note
--      below for why).
--   2. Poll for its readiness file (written only after listen() succeeds).
--   3. Run rest_client WARMUP: concurrency below --cap, so the number of
--      requests in flight against the server can never exceed --cap.
--      Every response must be 200 -- a single 503 here is a hard failure,
--      since it would mean the server is shedding *below* capacity.
--   4. Run rest_client OVERLOAD: concurrency well above --cap, so the
--      cap is reliably exceeded. Expect a mix of 200 and 503, zero
--      other_errors (no dropped/reset/hung request), and at least one
--      503 (proof the shed path actually triggered).
--   5. SIGTERM the server, with a SIGKILL watchdog as a backstop, then
--      assert it exited cleanly (exit code 0) -- the graceful-drain path
--      from Doc 24's "Running in a container" section.
--
-- Hard assertions (any failure -> RESULT: FAIL, non-zero exit):
--   * warmup phase: other_errors == 0, status_503 == 0, requests == WARMUP_REQUESTS
--   * overload phase: other_errors == 0, status_200 + status_503 == requests,
--     requests == OVERLOAD_REQUESTS, status_503 >= 1 (cap really was exceeded),
--     status_200 >= 1 (accepted work still got done, not just shedding)
--   * server process exits with code 0 after SIGTERM (clean drain)
--
-- Soft (informational only, never fails the run):
--   * reported min/median/max latency for 200 responses, in both phases

local SERVER_BIN = os.getenv("REST_SERVER_BIN") or "/usr/local/bin/rest_server"
local CLIENT_BIN = os.getenv("REST_CLIENT_BIN") or "/usr/local/bin/rest_client"

local PORT = tonumber(os.getenv("REST_PORT") or "18080")
local CAP = tonumber(os.getenv("REST_CAP") or "16")
local WORK_MS = tonumber(os.getenv("REST_WORK_MS") or "15")

local WARMUP_CONCURRENCY = tonumber(os.getenv("REST_WARMUP_CONCURRENCY") or "8")
local WARMUP_REQUESTS = tonumber(os.getenv("REST_WARMUP_REQUESTS") or "40")
local OVERLOAD_CONCURRENCY = tonumber(os.getenv("REST_OVERLOAD_CONCURRENCY") or "80")
local OVERLOAD_REQUESTS = tonumber(os.getenv("REST_OVERLOAD_REQUESTS") or "400")
local CLIENT_TIMEOUT_MS = tonumber(os.getenv("REST_CLIENT_TIMEOUT_MS") or "5000")

local PID_FILE = "/tmp/rest_server.pid"
local READY_FILE = "/tmp/rest_server.ready"
local SERVER_LOG = "/tmp/rest_server.log"
local READY_TIMEOUT_S = 10
local SHUTDOWN_WATCHDOG_S = 8

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local contents = f:read("*a")
    f:close()
    return contents
end

local function sleep(seconds)
    os.execute(string.format("sleep %s", tostring(seconds)))
end

local hard_failures = 0
local function fail(msg)
    print("  FAIL: " .. msg)
    hard_failures = hard_failures + 1
end

print(string.format(
    "== verify.lua: 24-concurrent-rest -- port=%d cap=%d work_ms=%d ==",
    PORT, CAP, WORK_MS))

-- 1. Start the server in the background. Its stdout/stderr are redirected
-- to a log file, not left attached to the pipe io.popen() gives us --
-- Lua never calls handle:read() on it, and an unread, undrained pipe can
-- fill its OS buffer and stall the child if we didn't redirect.
os.remove(PID_FILE)
os.remove(READY_FILE)
os.remove(SERVER_LOG)

local server_cmd = string.format(
    "%s --port %d --cap %d --work-ms %d --pidfile %s --readyfile %s > %s 2>&1",
    SERVER_BIN, PORT, CAP, WORK_MS, PID_FILE, READY_FILE, SERVER_LOG)
print("  launching: " .. server_cmd)
local server_handle, perr = io.popen(server_cmd)
if not server_handle then
    print("RESULT: FAIL (could not launch rest_server: " .. tostring(perr) .. ")")
    os.exit(1)
end

-- 2. Wait for the readiness file (written only after listen() succeeds).
local ready = false
for _ = 1, READY_TIMEOUT_S * 10 do
    if file_exists(READY_FILE) then ready = true; break end
    sleep(0.1)
end
if not ready then
    print("RESULT: FAIL (server did not become ready within " ..
        READY_TIMEOUT_S .. "s)")
    print("--- server log ---")
    print(read_file(SERVER_LOG) or "(no log)")
    os.exit(1)
end
print("  server ready (readiness file observed)")

-- Run one client phase; returns a table of parsed SUMMARY fields, or nil
-- (with a FAIL already recorded) on a parse error.
local function run_client_phase(label, concurrency, requests)
    local cmd = string.format(
        "%s --host 127.0.0.1 --port %d --concurrency %d --requests %d --timeout-ms %d",
        CLIENT_BIN, PORT, concurrency, requests, CLIENT_TIMEOUT_MS)
    print(string.format("  [%s] launching: %s", label, cmd))
    local handle, cerr = io.popen(cmd .. " 2>&1")
    if not handle then
        fail(string.format("%s: could not launch rest_client: %s", label, tostring(cerr)))
        return nil
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
    if not ok then
        fail(string.format("%s: rest_client exited abnormally (%s %s)\n--- output ---\n%s",
            label, tostring(why), tostring(code), output))
        return nil
    end

    local reqs = tonumber(output:match("requests=(%d+)"))
    local s200 = tonumber(output:match("status_200=(%d+)"))
    local s503 = tonumber(output:match("status_503=(%d+)"))
    local other = tonumber(output:match("other_errors=(%d+)"))
    local min_ms = tonumber(output:match("min_ms=([%d%.]+)"))
    local median_ms = tonumber(output:match("median_ms=([%d%.]+)"))
    local max_ms = tonumber(output:match("max_ms=([%d%.]+)"))
    if not (reqs and s200 and s503 and other) then
        fail(string.format("%s: could not parse rest_client output:\n%s", label, output))
        return nil
    end

    print(string.format(
        "  [%s] requests=%d status_200=%d status_503=%d other_errors=%d " ..
        "min_ms=%.3f median_ms=%.3f max_ms=%.3f",
        label, reqs, s200, s503, other, min_ms or 0, median_ms or 0, max_ms or 0))

    return {
        requests = reqs, status_200 = s200, status_503 = s503,
        other_errors = other, min_ms = min_ms, median_ms = median_ms, max_ms = max_ms,
    }
end

-- 3. WARMUP -- concurrency below the cap: no slot contention is possible,
-- so this must come back with zero 503s and zero other errors.
local warmup = run_client_phase("warmup", WARMUP_CONCURRENCY, WARMUP_REQUESTS)
if warmup then
    if warmup.requests ~= WARMUP_REQUESTS then
        fail(string.format("warmup: expected %d requests, client reported %d",
            WARMUP_REQUESTS, warmup.requests))
    end
    if warmup.other_errors ~= 0 then
        fail(string.format("warmup: %d other_errors (dropped/reset/hung request)",
            warmup.other_errors))
    end
    if warmup.status_503 ~= 0 then
        fail(string.format(
            "warmup: %d request(s) shed with 503 below the cap (concurrency=%d <= cap=%d)",
            warmup.status_503, WARMUP_CONCURRENCY, CAP))
    end
    if warmup.status_200 ~= WARMUP_REQUESTS then
        fail(string.format("warmup: expected %d status_200, got %d",
            WARMUP_REQUESTS, warmup.status_200))
    end
end

-- 4. OVERLOAD -- concurrency well above the cap: the cap must actually
-- trigger shedding, every request must still land as 200 or 503 (no
-- drops/resets/hangs), and the server must still answer the accepted ones.
local overload = run_client_phase("overload", OVERLOAD_CONCURRENCY, OVERLOAD_REQUESTS)
if overload then
    if overload.requests ~= OVERLOAD_REQUESTS then
        fail(string.format("overload: expected %d requests, client reported %d",
            OVERLOAD_REQUESTS, overload.requests))
    end
    if overload.other_errors ~= 0 then
        fail(string.format("overload: %d other_errors (dropped/reset/hung request)",
            overload.other_errors))
    end
    if overload.status_200 + overload.status_503 ~= overload.requests then
        fail(string.format(
            "overload: status_200 (%d) + status_503 (%d) != requests (%d)",
            overload.status_200, overload.status_503, overload.requests))
    end
    if overload.status_503 < 1 then
        fail(string.format(
            "overload: 0 requests shed (concurrency=%d >> cap=%d should have exceeded it)",
            OVERLOAD_CONCURRENCY, CAP))
    end
    if overload.status_200 < 1 then
        fail("overload: 0 requests accepted -- the server answered nothing but 503")
    end
end

-- 5. Shut the server down and assert a clean drain. A background watchdog
-- forces SIGKILL after SHUTDOWN_WATCHDOG_S seconds so a stuck drain turns
-- into a FAIL (close() will see the SIGKILL and report a non-zero/"signal"
-- result) rather than hanging this script forever.
local pid = (read_file(PID_FILE) or ""):match("%d+")
if not pid then
    fail("could not read server PID from " .. PID_FILE)
else
    print("  sending SIGTERM to rest_server (pid " .. pid .. ")")
    os.execute(string.format(
        "(sleep %d && kill -KILL %s) >/dev/null 2>&1 &", SHUTDOWN_WATCHDOG_S, pid))
    os.execute(string.format("kill -TERM %s", pid))
end

local ok, why, code = server_handle:close()
print(string.format("  server exit: ok=%s why=%s code=%s",
    tostring(ok), tostring(why), tostring(code)))
if not (ok and why == "exit" and code == 0) then
    fail(string.format(
        "server did not drain and exit cleanly (ok=%s why=%s code=%s) -- see %s",
        tostring(ok), tostring(why), tostring(code), SERVER_LOG))
    print("--- server log ---")
    print(read_file(SERVER_LOG) or "(no log)")
end

print()
if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
