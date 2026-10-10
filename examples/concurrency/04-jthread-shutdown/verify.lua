#!/usr/bin/env lua5.4
-- concurrency/04-jthread-shutdown — verify.lua
--
-- Plain Lua 5.4, no external modules, run once inside the demo's container
-- against the binary that same image just built -- this project's assertion
-- harness convention.
--
-- Doc 4's EXAMPLE SPEC calls for a Lua harness asserting "the container's
-- exit code is 0 and the shutdown log line appears within the grace
-- period, not after a forced kill." This harness delivers exactly that
-- signal by driving jthread_shutdown as a CHILD process of this script
-- rather than as the container's own PID 1:
--
--   * jthread_shutdown is launched in the background with its stdout
--     redirected to a log file.
--   * After a short startup delay, this script sends it a REAL SIGTERM
--     (`kill -TERM`) -- the same signal Kubernetes and `docker stop` send.
--   * A coarse, second-granularity grace-period loop polls for the process
--     to exit on its own. If it is still alive once the grace period
--     elapses, the harness force-kills it with SIGKILL and records that as
--     a hard failure -- exactly the "not after a forced kill" case the
--     chapter warns against.
--   * The child's own exit status and its captured log output are then
--     checked.
--
-- Because this script's own exit code becomes the CONTAINER's exit code
-- (CMD is `lua verify.lua`), a PASS here really does mean "the container
-- exited 0" -- the spec's literal assertion -- while also proving the
-- thing that assertion stands in for: a real SIGTERM drove a clean,
-- request_stop()-then-join() shutdown of every worker before any grace
-- period expired.

local BIN = os.getenv("JTHREAD_SHUTDOWN_BIN") or "/usr/local/bin/jthread_shutdown"
local N_WORKERS = tonumber(os.getenv("JTHREAD_SHUTDOWN_N") or "4")
local GRACE_SECONDS = tonumber(os.getenv("JTHREAD_SHUTDOWN_GRACE_SECONDS") or "8")
local TRIALS = tonumber(os.getenv("JTHREAD_SHUTDOWN_TRIALS") or "2")
local LOGFILE = "/tmp/jthread_shutdown_verify.log"

-- Runs one full trial: start jthread_shutdown, let it spin its workers up
-- for a second, send a real SIGTERM, wait (bounded by GRACE_SECONDS) for it
-- to exit on its own, force-kill it if it doesn't. Returns a table with
-- exit_code, forced_kill (bool), elapsed_s (coarse, seconds), and the
-- captured stdout log.
local function run_trial()
    -- LOGFILE/BIN are fixed, trusted paths (not external input), so plain
    -- double-quoting below is sufficient POSIX sh quoting.
    local script = string.format([[
set -u
rm -f "%s"
"%s" %d > "%s" 2>&1 &
pid=$!
sleep 1
kill -TERM "$pid" 2>/dev/null
elapsed=0
while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge %d ]; then
        kill -KILL "$pid" 2>/dev/null
        echo "FORCED_KILL=1"
        break
    fi
done
wait "$pid" 2>/dev/null
rc=$?
echo "EXIT_CODE=$rc"
echo "ELAPSED_AFTER_SIGTERM=$elapsed"
]], LOGFILE, BIN, N_WORKERS, LOGFILE, GRACE_SECONDS)

    local handle, perr = io.popen(script)
    if not handle then
        error(string.format("failed to launch verification shell script: %s", tostring(perr)))
    end
    local output = handle:read("*a")
    handle:close()

    local exit_code = tonumber(output:match("EXIT_CODE=(%-?%d+)"))
    local elapsed_s = tonumber(output:match("ELAPSED_AFTER_SIGTERM=(%d+)"))
    local forced_kill = output:match("FORCED_KILL=1") ~= nil

    if exit_code == nil or elapsed_s == nil then
        error("could not parse shell harness output:\n" .. output)
    end

    local log = ""
    local f = io.open(LOGFILE, "r")
    if f then
        log = f:read("*a")
        f:close()
    end

    return {
        exit_code = exit_code,
        forced_kill = forced_kill,
        elapsed_s = elapsed_s,
        log = log,
        shell_output = output,
    }
end

print(string.format(
    "== verify.lua: 04-jthread-shutdown -- n_workers=%d, grace_seconds=%d, trials=%d ==",
    N_WORKERS, GRACE_SECONDS, TRIALS))

local hard_failures = 0

for trial = 1, TRIALS do
    local ok, result = pcall(run_trial)
    if not ok then
        print(string.format("  FAIL: trial %d errored: %s", trial, tostring(result)))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  [trial %d] exit_code=%d forced_kill=%s elapsed_after_sigterm=%ds",
            trial, result.exit_code, tostring(result.forced_kill), result.elapsed_s))

        if result.forced_kill then
            print(string.format(
                "  FAIL: trial %d required a forced SIGKILL -- jthread_shutdown did not " ..
                "exit within the %ds grace period after SIGTERM", trial, GRACE_SECONDS))
            hard_failures = hard_failures + 1
        end

        if result.exit_code ~= 0 then
            print(string.format(
                "  FAIL: trial %d exit code=%d (want 0 -- a clean shutdown after SIGTERM)",
                trial, result.exit_code))
            hard_failures = hard_failures + 1
        end

        if result.elapsed_s >= GRACE_SECONDS then
            print(string.format(
                "  FAIL: trial %d took %ds to exit after SIGTERM, at or past the %ds grace " ..
                "period", trial, result.elapsed_s, GRACE_SECONDS))
            hard_failures = hard_failures + 1
        end

        if not result.log:find("main: shutdown complete, all workers joined", 1, true) then
            print(string.format(
                "  FAIL: trial %d log is missing the \"shutdown complete\" line -- " ..
                "request_stop()/join() may not have completed:\n%s",
                trial, result.log))
            hard_failures = hard_failures + 1
        end

        local worker_stop_lines = 0
        for _ in result.log:gmatch("worker %d+: stop observed, exiting") do
            worker_stop_lines = worker_stop_lines + 1
        end
        if worker_stop_lines ~= N_WORKERS then
            print(string.format(
                "  FAIL: trial %d saw %d/%d workers log \"stop observed\" -- not every " ..
                "worker's stop_token loop noticed the request",
                trial, worker_stop_lines, N_WORKERS))
            hard_failures = hard_failures + 1
        end

        if not result.log:find("main: SIGTERM received", 1, true) then
            print(string.format(
                "  FAIL: trial %d log is missing the \"SIGTERM received\" line -- the " ..
                "signal may not have been delivered or observed:\n%s",
                trial, result.log))
            hard_failures = hard_failures + 1
        end
    end
end

os.remove(LOGFILE)

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d correctness failure(s))", hard_failures))
    os.exit(1)
end

print(string.format(
    "  shutdown: PASS on all %d trial(s) -- exit 0, no forced kill, shutdown log present, " ..
    "every worker observed the stop request, all within the %ds grace period",
    TRIALS, GRACE_SECONDS))
print("RESULT: PASS")
os.exit(0)
