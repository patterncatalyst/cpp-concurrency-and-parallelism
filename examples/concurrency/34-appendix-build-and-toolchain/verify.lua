#!/usr/bin/env lua5.4
-- concurrency/34-appendix-build-and-toolchain — verify.lua
--
-- Same harness contract as the rest of this project: plain Lua 5.4, no
-- required arguments, reads env vars for overrides, prints a readable
-- summary, exits 0 on pass (a WARN inside a pass is allowed for a
-- soft/environment-dependent assertion), non-zero on any hard failure.
-- Runs inside the container, against the binaries that same image built.
--
-- This example ships three binaries, built with decreasing guarantees:
--
--   shared_counter_gcc    always a real binary (gcc is always available
--                         in this book's build images) -- the ONE hard
--                         requirement.
--   shared_counter_clang  a real clang-built binary if this UBI10 image
--                         happened to have clang available, otherwise a
--                         placeholder that prints "UNAVAILABLE" and
--                         exits 3.
--   shared_counter_tsan   a real clang -fsanitize=thread build if clang
--                         AND the ThreadSanitizer runtime were both
--                         available and the link succeeded, otherwise
--                         the same kind of placeholder.
--
-- What this example checks:
--   1. The gcc build produces its expected output (hard). Both threads'
--      increments go through std::atomic<uint64_t>::fetch_add, so
--      final_count must equal expected EXACTLY, every run -- this is
--      the chapter's "a demo is not working until it produces the
--      specific observable effect claimed" discipline, applied to the
--      appendix's own reference program.
--   2. The gcc build's --inject-race path runs to completion without
--      crashing (hard) -- the race-injectable path must exist and must
--      be reachable; its count is NOT asserted equal to expected, since
--      lost updates are an accepted symptom of the race, not something
--      this path tries to avoid.
--   3. gcc-vs-clang output parity (soft, real when reachable): if the
--      clang leg is a real binary, its non-racy output must be
--      byte-identical to the gcc build's. If clang wasn't available in
--      this image, this reports a SOFT skip, documented in the README.
--   4. The injected race is flagged ONLY in the TSan build (soft when
--      TSan isn't available at all in this image; hard once it is):
--      if the TSan leg is a real, runnable binary, the safe path must
--      produce NO ThreadSanitizer warning and the --inject-race path
--      MUST produce one. If the leg is a placeholder, or TSan's own
--      runtime fails to initialize in this minimal container (a real,
--      documented possibility independent of whether the race exists),
--      this is a SOFT skip, not a failure.
--   5. The generated conan.lock pins the exact fmt version conanfile.txt
--      requested (hard, if the lockfile is present) -- the lockfile
--      workflow this appendix documents, checked directly rather than
--      taken on faith.

local GCC_BIN   = os.getenv("SHARED_COUNTER_GCC_BIN")   or "/usr/local/bin/shared_counter_gcc"
local CLANG_BIN = os.getenv("SHARED_COUNTER_CLANG_BIN") or "/usr/local/bin/shared_counter_clang"
local TSAN_BIN  = os.getenv("SHARED_COUNTER_TSAN_BIN")  or "/usr/local/bin/shared_counter_tsan"
local LOCK_FILE = os.getenv("CONAN_LOCK_FILE")          or "/demo/conan.lock"
local EXPECTED_FMT_REQUIRE = "fmt/10.2.1" -- must match conanfile.txt's [requires]

local function run(bin, args)
    local cmd = string.format("%s %s", bin, args or "")
    local handle, perr = io.popen(cmd .. " 2>&1")
    if not handle then
        error(string.format("failed to launch %q: %s", cmd, tostring(perr)))
    end
    local output = handle:read("*a")
    local ok, why, code = handle:close()
    -- Don't error() on a nonzero exit here -- the placeholder scripts
    -- exit 3 deliberately, and TSan can exit nonzero under
    -- halt_on_error; callers inspect output/ok/code themselves.
    return output, ok, why, code
end

local function is_unavailable(output)
    return output:match("UNAVAILABLE") ~= nil
end

print("== verify.lua: 34-appendix-build-and-toolchain (reference build slice) ==")

local hard_failures = 0

-- 1 & 2. The gcc leg -- hard requirement.
local gcc_safe_out, gcc_safe_ok = run(GCC_BIN)
if not gcc_safe_ok then
    print("  FAIL: shared_counter_gcc (safe) did not exit 0:\n" .. gcc_safe_out)
    hard_failures = hard_failures + 1
else
    local final_count = tonumber(gcc_safe_out:match("final_count=(%d+)"))
    local expected = tonumber(gcc_safe_out:match("expected=(%d+)"))
    if not (final_count and expected) then
        print("  FAIL: could not parse shared_counter_gcc (safe) output:\n" .. gcc_safe_out)
        hard_failures = hard_failures + 1
    elseif final_count ~= expected then
        print(string.format(
            "  FAIL: shared_counter_gcc (safe) final_count=%d != expected=%d",
            final_count, expected))
        hard_failures = hard_failures + 1
    else
        print(string.format(
            "  gcc build, safe path: PASS (final_count=%d == expected=%d, exact)",
            final_count, expected))
    end
end

local gcc_racy_out, gcc_racy_ok = run(GCC_BIN, "--inject-race")
if not gcc_racy_ok then
    print("  FAIL: shared_counter_gcc --inject-race did not exit 0:\n" .. gcc_racy_out)
    hard_failures = hard_failures + 1
elseif not gcc_racy_out:match("mode=racy") then
    print("  FAIL: shared_counter_gcc --inject-race did not report mode=racy:\n" .. gcc_racy_out)
    hard_failures = hard_failures + 1
else
    print("  gcc build, --inject-race path: PASS (reachable, ran to completion -- " ..
          "its count is not asserted equal to expected; lost updates are the " ..
          "expected symptom of an unguarded race, not a bug in this path)")
end

-- 3. gcc-vs-clang parity -- soft (real check when clang is available).
local clang_out, clang_ok = run(CLANG_BIN)
if not clang_ok or is_unavailable(clang_out) then
    print("  clang-release leg: SOFT SKIP (clang++ was not available when this " ..
          "image was built -- see README). This book's CI builds with gcc; " ..
          "the parity claim is demonstrated here only when the environment " ..
          "happens to provide clang too.")
else
    if gcc_safe_ok and clang_out == gcc_safe_out then
        print("  gcc-vs-clang parity: PASS (byte-identical output on the safe path)")
    else
        print(string.format(
            "  FAIL: gcc-vs-clang parity -- gcc output %q, clang output %q differ",
            gcc_safe_out, clang_out))
        hard_failures = hard_failures + 1
    end
end

-- 4. TSan leg -- soft skip if unavailable/failed to initialize, otherwise
-- a real (hard) check once it can actually run.
local tsan_safe_out, tsan_safe_ok = run(TSAN_BIN)
if not tsan_safe_ok and is_unavailable(tsan_safe_out) then
    print("  clang-tsan leg: SOFT SKIP (clang++ and/or the ThreadSanitizer " ..
          "runtime were not available when this image was built -- see README)")
elseif tsan_safe_out:match("FATAL: ThreadSanitizer") then
    print("  clang-tsan leg: SOFT SKIP (ThreadSanitizer failed to initialize " ..
          "in this container -- a known possibility under restricted " ..
          "namespaces/seccomp profiles, independent of whether the race " ..
          "itself exists; see README)")
else
    local safe_has_race_warning = tsan_safe_out:match("ThreadSanitizer: data race") ~= nil
    local tsan_racy_out = run(TSAN_BIN, "--inject-race")
    local racy_has_race_warning = tsan_racy_out:match("ThreadSanitizer: data race") ~= nil

    if safe_has_race_warning then
        print("  FAIL: clang-tsan build reported a data race on the SAFE path " ..
              "(no --inject-race) -- the atomic-counter path must be race-free:\n" ..
              tsan_safe_out)
        hard_failures = hard_failures + 1
    elseif not racy_has_race_warning then
        print("  FAIL: clang-tsan build did NOT flag a data race with " ..
              "--inject-race -- the injected race should always be caught:\n" ..
              tsan_racy_out)
        hard_failures = hard_failures + 1
    else
        print("  clang-tsan leg: PASS (no warning on the safe path, " ..
              "ThreadSanitizer: data race reported only with --inject-race)")
    end
end

-- 5. Lockfile pins the exact requested version -- hard, when present.
local lock_f = io.open(LOCK_FILE, "r")
if not lock_f then
    print(string.format(
        "  WARN: conan.lock not found at %s -- skipping lockfile check " ..
        "(not a hard failure: the build/run checks above already cover " ..
        "this example's required behavior)", LOCK_FILE))
else
    local lock_contents = lock_f:read("*a")
    lock_f:close()
    if lock_contents:find(EXPECTED_FMT_REQUIRE, 1, true) then
        print(string.format(
            "  conan.lock: PASS (pins %s, matching conanfile.txt's [requires])",
            EXPECTED_FMT_REQUIRE))
    else
        print(string.format(
            "  FAIL: conan.lock does not reference %s -- lockfile and " ..
            "conanfile.txt have drifted", EXPECTED_FMT_REQUIRE))
        hard_failures = hard_failures + 1
    end
end

if hard_failures > 0 then
    print(string.format("RESULT: FAIL (%d hard failure(s))", hard_failures))
    os.exit(1)
end

print("RESULT: PASS")
os.exit(0)
