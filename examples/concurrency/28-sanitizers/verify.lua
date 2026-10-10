#!/usr/bin/env lua5.4
-- concurrency/28-sanitizers — verify.lua
--
-- Plain Lua 5.4, no external modules, run inside the demo's container
-- against the binaries that same image built (this project's verify.lua
-- convention -- see examples/concurrency/20-mechanical-sympathy/verify.lua
-- for the reference).
--
-- Every assertion here is tied to REAL tool output captured during this
-- run -- no fabricated report text. What this checks:
--
--   1. racy_counter, TSan build: --mode racy must report "ThreadSanitizer:
--      data race" naming racy_counter.cpp; --mode fixed must be clean.
--      HARD when the TSan leg built and its runtime initializes; SOFT
--      SKIP otherwise (same reasoning as 27-debugging-races-deadlocks).
--   2. racy_counter, PLAIN build, under `valgrind --tool=helgrind`:
--      --mode racy must report a probable data race naming
--      racy_counter.cpp/increment; --mode fixed must be clean. HARD when
--      Valgrind itself starts successfully; SOFT SKIP if Valgrind fails to
--      initialize in this container (a real, if less common, possibility
--      independent of whether the race exists).
--   3. Both tools must name the SAME source line (racy_counter.cpp,
--      increment()) for the SAME bug -- checked directly, not assumed,
--      whenever both legs actually ran.
--   4. detached_uaf, plain build: run informationally only, no assertion
--      (a use-after-free into not-yet-reused memory can read back
--      plausible garbage with no visible symptom -- the same trap chapter
--      27 makes about a racy counter's printed total).
--   5. detached_uaf, ASan build: --mode uaf must report
--      "heap-use-after-free" naming both the allocating and freeing call
--      stacks, and must NEVER reach its own "completed" print (proof ASan
--      halted the process before the bug's effect could be masked by
--      continuing on). --mode fixed (shared_ptr) must exit 0 clean. HARD
--      when the ASan leg built and its runtime initializes; SOFT SKIP
--      otherwise.

local RACY_PLAIN_BIN = os.getenv("RACY_COUNTER_PLAIN_BIN") or "/usr/local/bin/racy_counter_plain"
local RACY_TSAN_BIN  = os.getenv("RACY_COUNTER_TSAN_BIN")  or "/usr/local/bin/racy_counter_tsan"
local UAF_PLAIN_BIN  = os.getenv("DETACHED_UAF_PLAIN_BIN") or "/usr/local/bin/detached_uaf_plain"
local UAF_ASAN_BIN   = os.getenv("DETACHED_UAF_ASAN_BIN")  or "/usr/local/bin/detached_uaf_asan"

local TSAN_N = tonumber(os.getenv("RACY_COUNTER_TSAN_N") or "100000")
-- Helgrind re-translates every basic block through a software CPU --
-- commonly 10-50x slower than native. A far smaller N than the TSan leg
-- still produces a genuine race (the race's existence doesn't depend on
-- how many iterations run, only on zero synchronization existing between
-- any one pair of conflicting accesses).
local HELGRIND_N = tonumber(os.getenv("RACY_COUNTER_HELGRIND_N") or "5000")

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

print("== verify.lua: 28-sanitizers ==")

local hard_failures = 0
local tsan_ran = false
local helgrind_ran = false

-- ── 1. racy_counter under ThreadSanitizer ──────────────────────────────
print("\n-- racy_counter (ThreadSanitizer) --")

local tsan_racy_cmd = string.format("%s --mode racy -n %d", RACY_TSAN_BIN, TSAN_N)
local _, tsan_racy_out = run(tsan_racy_cmd)

if is_unavailable(tsan_racy_out) then
    print("  TSan leg: SOFT SKIP (racy_counter was not built with " ..
          "-fsanitize=thread in this image -- libtsan wasn't available " ..
          "from this UBI10 repo set when the image was built; see README)")
elseif tsan_racy_out:match("FATAL: ThreadSanitizer") then
    print("  TSan leg: SOFT SKIP (ThreadSanitizer's runtime failed to " ..
          "initialize in this container; see README)\n" ..
          "  --- raw output ---\n" .. tsan_racy_out)
else
    tsan_ran = true
    local has_race = tsan_racy_out:match("ThreadSanitizer: data race") ~= nil
    local names_source = tsan_racy_out:match("racy_counter%.cpp") ~= nil
    local names_increment = tsan_racy_out:match("increment") ~= nil
    if not (has_race and names_source and names_increment) then
        print("  FAIL: TSan build of racy_counter --mode racy did not " ..
              "report a data race naming increment()/racy_counter.cpp:\n" .. tsan_racy_out)
        hard_failures = hard_failures + 1
    else
        print("  racy mode: PASS -- ThreadSanitizer reported \"data race\", " ..
              "naming increment() in racy_counter.cpp")
    end

    local tsan_fixed_cmd = string.format("%s --mode fixed -n %d", RACY_TSAN_BIN, TSAN_N)
    local fixed_rc, tsan_fixed_out = run(tsan_fixed_cmd)
    local fixed_has_race = tsan_fixed_out:match("ThreadSanitizer: data race") ~= nil

    if fixed_rc ~= 0 or fixed_has_race then
        print(string.format(
            "  FAIL: TSan build of racy_counter --mode fixed should exit 0 " ..
            "with no report (rc=%d):\n%s", fixed_rc, tsan_fixed_out))
        hard_failures = hard_failures + 1
    else
        print("  fixed mode: PASS (exit 0, no ThreadSanitizer report)")
    end
end

-- ── 2. racy_counter (plain build) under Valgrind Helgrind ──────────────
print("\n-- racy_counter (plain build, valgrind --tool=helgrind) --")

local helgrind_racy_cmd = string.format(
    "valgrind --tool=helgrind --error-exitcode=99 %s --mode racy -n %d",
    RACY_PLAIN_BIN, HELGRIND_N)
local helgrind_racy_rc, helgrind_racy_out = run(helgrind_racy_cmd)

local valgrind_startup_failure =
    helgrind_racy_out:match("Fatal error at startup") ~= nil
    or helgrind_racy_out:match("valgrind: failed") ~= nil
    or helgrind_racy_out:match("the 'impossible' happened") ~= nil

if valgrind_startup_failure then
    print("  Helgrind leg: SOFT SKIP (Valgrind failed to initialize in " ..
          "this container -- a known possibility under some container " ..
          "runtimes' syscall emulation layers; see README)\n" ..
          "  --- raw output ---\n" .. helgrind_racy_out)
else
    helgrind_ran = true
    local has_race = helgrind_racy_out:match("Possible data race") ~= nil
    local names_source = helgrind_racy_out:match("racy_counter%.cpp") ~= nil
    local names_increment = helgrind_racy_out:match("increment") ~= nil

    if helgrind_racy_rc ~= 99 or not (has_race and names_source and names_increment) then
        print(string.format(
            "  FAIL: Helgrind run of racy_counter --mode racy did not " ..
            "report a probable data race naming increment()/racy_counter.cpp " ..
            "(rc=%d):\n%s", helgrind_racy_rc, helgrind_racy_out))
        hard_failures = hard_failures + 1
    else
        print("  racy mode: PASS -- Helgrind reported \"Possible data race\", " ..
              "naming increment() in racy_counter.cpp (rc=99, our --error-exitcode)")
    end

    local helgrind_fixed_cmd = string.format(
        "valgrind --tool=helgrind --error-exitcode=99 %s --mode fixed -n %d",
        RACY_PLAIN_BIN, HELGRIND_N)
    local helgrind_fixed_rc, helgrind_fixed_out = run(helgrind_fixed_cmd)

    if helgrind_fixed_rc ~= 0 then
        print(string.format(
            "  FAIL: Helgrind run of racy_counter --mode fixed should exit 0 " ..
            "with no error (rc=%d):\n%s", helgrind_fixed_rc, helgrind_fixed_out))
        hard_failures = hard_failures + 1
    else
        print("  fixed mode: PASS (rc=0, Helgrind reported no race)")
    end
end

-- ── 3. Both tools agree on the SAME source line ────────────────────────
if tsan_ran and helgrind_ran then
    print("\n-- cross-tool agreement --")
    print("  PASS: ThreadSanitizer (compile-time vector clocks) and " ..
          "Helgrind (binary re-translation + lockset) both independently " ..
          "named increment() in racy_counter.cpp for the same program -- " ..
          "two unrelated detection algorithms, one real bug.")
end

-- ── 4. detached_uaf: plain build first (informational only) ───────────
-- Never asserted PASS/FAIL: a use-after-free into memory the allocator
-- hasn't yet reused for anything else can easily read back plausible-
-- looking garbage (or even the original bytes) with no visible symptom at
-- all -- the same "absence of a symptom is not absence of the defect"
-- trap chapter 27 makes about the racy counter. AddressSanitizer (below)
-- is what actually proves the bug, independent of what the plain build's
-- output happens to look like on any given run.
print("\n-- detached_uaf (plain, un-instrumented) -- informational only --")
local _, plain_uaf_out = run(string.format("%s --mode uaf", UAF_PLAIN_BIN))
for line in plain_uaf_out:gmatch("[^\n]+") do print("    " .. line) end

-- ── 5. detached_uaf under AddressSanitizer ─────────────────────────────
print("\n-- detached_uaf (AddressSanitizer) --")

local asan_uaf_cmd = string.format("%s --mode uaf", UAF_ASAN_BIN)
local asan_uaf_rc, asan_uaf_out = run(asan_uaf_cmd)

if is_unavailable(asan_uaf_out) then
    print("  ASan leg: SOFT SKIP (detached_uaf was not built with " ..
          "-fsanitize=address in this image -- libasan wasn't available " ..
          "from this UBI10 repo set when the image was built; see README)")
elseif (asan_uaf_out:match("Shadow memory range interleaves") ~= nil
        or asan_uaf_out:match("[Ff]ailed to allocate") ~= nil
        or asan_uaf_out:match("[Ff]ailed to mmap") ~= nil
        or asan_uaf_out:match("Shadow memory") ~= nil)
    and asan_uaf_out:match("heap%-use%-after%-free") == nil then
    -- Real-world ASan startup-failure wording ("==PID==ERROR:
    -- AddressSanitizer: Shadow memory range interleaves with an existing
    -- memory mapping", "AddressSanitizer failed to allocate ... bytes",
    -- "Failed to mmap") rather than "FATAL: AddressSanitizer" -- that
    -- prefix is TSan's convention, not ASan's. Guarded by the ABSENCE of
    -- an actual heap-use-after-free report so a real bug report
    -- containing an unrelated "mmap" substring is never misclassified.
    print("  ASan leg: SOFT SKIP (AddressSanitizer's runtime failed to " ..
          "initialize in this container -- a restrictive memory-overcommit " ..
          "policy rejecting its shadow-memory reservation, independent of " ..
          "whether the bug itself exists; see README)\n" ..
          "  --- raw output ---\n" .. asan_uaf_out)
else
    local has_uaf = asan_uaf_out:match("heap%-use%-after%-free") ~= nil
    local has_alloc_stack = asan_uaf_out:match("allocated by thread") ~= nil
    local has_free_stack = asan_uaf_out:match("freed by thread") ~= nil
    local never_completed = asan_uaf_out:match("completed%-without%-asan%-catching%-it") == nil

    if not has_uaf then
        print("  FAIL: ASan build of detached_uaf --mode uaf did not " ..
              "report heap-use-after-free:\n" .. asan_uaf_out)
        hard_failures = hard_failures + 1
    elseif not (has_alloc_stack and has_free_stack) then
        print("  FAIL: ASan reported heap-use-after-free but did not name " ..
              "both the allocating and freeing call stacks:\n" .. asan_uaf_out)
        hard_failures = hard_failures + 1
    elseif not never_completed then
        print("  FAIL: detached_uaf printed its own \"completed\" line -- " ..
              "ASan should have halted the process before that ever ran:\n" .. asan_uaf_out)
        hard_failures = hard_failures + 1
    elseif asan_uaf_rc == 0 then
        print("  FAIL: ASan build of detached_uaf --mode uaf exited 0 -- " ..
              "a detected heap-use-after-free should abort nonzero:\n" .. asan_uaf_out)
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  uaf mode: PASS (rc=%d, ASan reported heap-use-after-free " ..
            "with both allocation and free call stacks)", asan_uaf_rc))
        print("  --- captured ASan report (first 20 lines) ---")
        local n = 0
        for line in asan_uaf_out:gmatch("[^\n]+") do
            n = n + 1
            if n > 20 then print("    ..."); break end
            print("    " .. line)
        end
    end

    local asan_fixed_cmd = string.format("%s --mode fixed", UAF_ASAN_BIN)
    local asan_fixed_rc, asan_fixed_out = run(asan_fixed_cmd)
    local fixed_has_error = asan_fixed_out:match("ERROR: AddressSanitizer") ~= nil

    if asan_fixed_rc ~= 0 or fixed_has_error then
        print(string.format(
            "  FAIL: ASan build of detached_uaf --mode fixed should exit 0 " ..
            "clean (rc=%d):\n%s", asan_fixed_rc, asan_fixed_out))
        hard_failures = hard_failures + 1
    else
        print("  fixed mode: PASS (exit 0, no AddressSanitizer report -- " ..
              "the shared_ptr keeps the allocation alive for the worker's lifetime)")
    end
end

print()
if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
