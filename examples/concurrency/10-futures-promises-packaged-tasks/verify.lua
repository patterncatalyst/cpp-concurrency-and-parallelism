#!/usr/bin/env lua5.4
-- concurrency/10-futures-promises-packaged-tasks — verify.lua
--
-- Plain Lua 5.4, no required arguments, runs inside the container against
-- the two binaries that same image built. Both checks below are HARD: the
-- launch-policy distinction and the exception-propagation guarantee are
-- both things the standard mandates outright, not performance claims that
-- can be muted by a noisy host -- a failure here means the demo program is
-- wrong, not that the environment was unkind.
--
-- What this example checks:
--   1. launch_policy: every std::launch::async task's executing thread id
--      differs from the submitter's; every std::launch::deferred task's
--      executing thread id EQUALS the submitter's (deferred work runs
--      inside the calling thread's own get() call). The default-policy
--      round is reported but never asserted in a direction, because an
--      implementation choosing either is conforming.
--   2. worker_pool: a packaged_task that throws has its exception rethrown
--      at that SAME task's future::get() (caught_at=get), every other
--      task's result is unaffected and arithmetically correct (task i's
--      result is i*i), and the summary counts line up.

local LAUNCH_BIN = os.getenv("LAUNCH_POLICY_BIN") or "/usr/local/bin/launch_policy"
local POOL_BIN = os.getenv("WORKER_POOL_BIN") or "/usr/local/bin/worker_pool"
local N = tonumber(os.getenv("LAUNCH_POLICY_N") or "5")
local POOL_TASKS = tonumber(os.getenv("WORKER_POOL_TASKS") or "12")
local POOL_FAIL_AT = tonumber(os.getenv("WORKER_POOL_FAIL_AT") or "7")

local function run(cmd)
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
    "== verify.lua: 10-futures-promises-packaged-tasks -- n=%d, pool_tasks=%d, fail_at=%d ==",
    N, POOL_TASKS, POOL_FAIL_AT))

local hard_failures = 0
local function fail(msg)
    print("  FAIL: " .. msg)
    hard_failures = hard_failures + 1
end

-- 1. launch_policy: per-task thread-id distinction, by policy.
local ok, launch_out = pcall(run, string.format("%s -n %d", LAUNCH_BIN, N))
if not ok then
    fail("launch_policy errored: " .. tostring(launch_out))
else
    local async_total, async_distinct = 0, 0
    local deferred_total, deferred_same = 0, 0
    local default_total = 0

    for line in launch_out:gmatch("[^\n]+") do
        local policy, task, same = line:match(
            "^policy=(%a+) task=(%d+) submitter_tid=%S+ exec_tid=%S+ same_thread=(%a+)")
        if policy then
            print("  [launch_policy] " .. line)
            if policy == "async" then
                async_total = async_total + 1
                if same == "false" then async_distinct = async_distinct + 1 end
            elseif policy == "deferred" then
                deferred_total = deferred_total + 1
                if same == "true" then deferred_same = deferred_same + 1 end
            elseif policy == "default" then
                default_total = default_total + 1
            end
        end
    end

    if async_total ~= N then
        fail(string.format("expected %d std::launch::async task lines, saw %d", N, async_total))
    elseif async_distinct ~= async_total then
        fail(string.format(
            "std::launch::async: only %d/%d tasks ran on a thread distinct from the submitter",
            async_distinct, async_total))
    else
        print(string.format(
            "  std::launch::async: PASS (%d/%d tasks ran on a distinct thread)",
            async_distinct, async_total))
    end

    if deferred_total ~= N then
        fail(string.format("expected %d std::launch::deferred task lines, saw %d", N, deferred_total))
    elseif deferred_same ~= deferred_total then
        fail(string.format(
            "std::launch::deferred: only %d/%d tasks ran on the submitter's own thread",
            deferred_same, deferred_total))
    else
        print(string.format(
            "  std::launch::deferred: PASS (%d/%d tasks ran on the submitter's own thread)",
            deferred_same, deferred_total))
    end

    if default_total ~= N then
        fail(string.format("expected %d default-policy task lines, saw %d", N, default_total))
    else
        print(string.format(
            "  default policy: reported, not asserted (%d tasks observed; " ..
            "either async-like or deferred-like behavior is conforming)", default_total))
    end
end

-- 2. worker_pool: exception propagation + correctness of every other task.
local ok2, pool_out = pcall(run, string.format(
    "%s --tasks %d --fail-at %d", POOL_BIN, POOL_TASKS, POOL_FAIL_AT))
if not ok2 then
    fail("worker_pool errored: " .. tostring(pool_out))
else
    local ok_seen = 0
    local exception_seen = 0
    local wrong_results = 0

    for line in pool_out:gmatch("[^\n]+") do
        local task_ok, result = line:match("^task=(%d+) status=ok result=(%-?%d+)")
        if task_ok then
            print("  [worker_pool] " .. line)
            local i = tonumber(task_ok)
            local expected = i * i
            if tonumber(result) ~= expected then
                fail(string.format("task %d: expected result=%d, got %s", i, expected, result))
                wrong_results = wrong_results + 1
            end
            ok_seen = ok_seen + 1
        else
            local task_exc, caught_at = line:match(
                "^task=(%d+) status=exception caught_at=(%a+)")
            if task_exc then
                print("  [worker_pool] " .. line)
                if tonumber(task_exc) ~= POOL_FAIL_AT then
                    fail(string.format(
                        "exception reported on task %s, expected task %d (--fail-at)",
                        task_exc, POOL_FAIL_AT))
                end
                if caught_at ~= "get" then
                    fail(string.format(
                        "task %s exception reported caught_at=%s, expected caught_at=get",
                        task_exc, caught_at))
                end
                exception_seen = exception_seen + 1
            end
        end
    end

    local submitted, ok_count, exceptions, workers = pool_out:match(
        "RESULT: submitted=(%d+) ok=(%d+) exceptions=(%d+) workers=(%d+)")
    if not submitted then
        fail("could not find worker_pool's RESULT summary line")
    else
        submitted, ok_count, exceptions = tonumber(submitted), tonumber(ok_count), tonumber(exceptions)
        print(string.format(
            "  [worker_pool] RESULT: submitted=%d ok=%d exceptions=%d workers=%s",
            submitted, ok_count, exceptions, workers))
        if submitted ~= POOL_TASKS then
            fail(string.format("submitted=%d does not match requested --tasks %d", submitted, POOL_TASKS))
        end
        if exceptions ~= 1 then
            fail(string.format("expected exactly 1 exception, summary reports %d", exceptions))
        end
        if ok_count ~= POOL_TASKS - 1 then
            fail(string.format("expected ok=%d (tasks - 1), summary reports %d", POOL_TASKS - 1, ok_count))
        end
    end

    if ok_seen ~= POOL_TASKS - 1 then
        fail(string.format("expected %d status=ok lines, saw %d", POOL_TASKS - 1, ok_seen))
    end
    if exception_seen ~= 1 then
        fail(string.format("expected exactly 1 status=exception line, saw %d", exception_seen))
    end
    if wrong_results == 0 and ok_seen == POOL_TASKS - 1 and exception_seen == 1 then
        print("  worker_pool: PASS (every non-failing task's result is correct; " ..
              "the failing task's exception was observed at its own future::get())")
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
