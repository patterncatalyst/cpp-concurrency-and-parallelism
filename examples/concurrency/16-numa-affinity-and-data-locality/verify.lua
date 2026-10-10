-- concurrency/16-numa-affinity-and-data-locality verifier (plain Lua 5.4).
--
-- Runs INSIDE the lab guest after the benchmark has run. Asserts the REAL,
-- reproducible NUMA MECHANISMS (placement, first-touch, cpuset fallback) as
-- HARD requirements; reports the local-vs-remote TIMING as SOFT, because on a
-- single-physical-node host QEMU emulates the topology but not the latency, so
-- the ratio is ~1.0 here and only becomes the chapter's 1.3-1.6x gap on real
-- multi-socket hardware.
--
-- Usage: lua verify.lua <full-run.out> <cpuset-run.out>
--   full-run.out   stdout of `numa_locality`           (NODES/PLACE/FIRSTTOUCH/TIMING)
--   cpuset-run.out stdout of `numa_locality --onnode 1` under cpuset.mems=0 (ONNODE)
--
-- Prints "RESULT: PASS" and exits 0 only if every HARD check holds.

local function read_file(path)
    local f = assert(io.open(path, "r"), "cannot open " .. tostring(path))
    local s = f:read("*a")
    f:close()
    return s
end

local function fail(msg)
    print("  [FAIL] " .. msg)
    print("RESULT: FAIL")
    os.exit(1)
end

local full_path   = arg[1] or error("usage: lua verify.lua <full.out> <cpuset.out>")
local cpuset_path = arg[2] or error("usage: lua verify.lua <full.out> <cpuset.out>")

local full   = read_file(full_path)
local cpuset = read_file(cpuset_path)

print("== verify.lua: 16-numa-affinity-and-data-locality ==")
print()
print("-- HARD: node topology --")

-- The benchmark must have seen at least two NUMA nodes (the emulated guest
-- topology). Without that, nothing below is meaningful.
local nodes = tonumber(full:match("NODES n=(%d+)"))
if not nodes then fail("no NODES line in full run output") end
if nodes < 2 then fail("expected >= 2 NUMA nodes, saw " .. nodes) end
print(string.format("  nodes visible: %d (PASS)", nodes))

print()
print("-- HARD: numa_alloc_onnode places pages on the requested node --")
local place_count = 0
for req, act in full:gmatch("PLACE requested=(%d+) actual=(%-?%d+)") do
    place_count = place_count + 1
    if req ~= act then
        fail(string.format("numa_alloc_onnode(%s) placed pages on node %s", req, act))
    end
    print(string.format("  node %s requested -> node %s actual (PASS)", req, act))
end
if place_count < 2 then fail("expected 2 PLACE lines, saw " .. place_count) end

print()
print("-- HARD: first-touch binds pages to the touching thread's node --")
local ft_count = 0
for tnode, pnode in full:gmatch("FIRSTTOUCH thread_node=(%d+) page_node=(%-?%d+)") do
    ft_count = ft_count + 1
    if tnode ~= pnode then
        fail(string.format("thread on node %s first-touched pages onto node %s", tnode, pnode))
    end
    print(string.format("  thread node %s -> pages on node %s (PASS)", tnode, pnode))
end
if ft_count < 2 then fail("expected 2 FIRSTTOUCH lines, saw " .. ft_count) end

print()
print("-- HARD: a cpuset.mems mismatch makes numa_alloc_onnode silently fall back --")
local req, allowed, act = cpuset:match("ONNODE requested=(%d+) allowed_mems=([%d,]+) actual=(%-?%d+)")
if not req then fail("no ONNODE line in cpuset run output") end
-- The run was confined (cpuset.mems=0) and asked for node 1. The allocation
-- must NOT have landed on the requested node, and must have landed on a node
-- the cpuset actually allows -- the silent fallback the chapter warns about.
local function csv_has(csv, v)
    for item in csv:gmatch("[^,]+") do if item == v then return true end end
    return false
end
if act == req then
    fail(string.format("expected fallback off node %s, but it was honored (actual=%s)", req, act))
end
if not csv_has(allowed, act) then
    fail(string.format("fell back to node %s, which is not in allowed_mems=%s", act, allowed))
end
print(string.format("  requested node %s, allowed_mems={%s} -> silently landed on node %s (PASS)",
    req, allowed, act))

print()
print("-- SOFT: local vs remote read latency (emulated topology: ratio ~1.0 expected) --")
local lns, rns, ratio = full:match("TIMING local_ns=([%d%.]+) remote_ns=([%d%.]+) ratio=([%d%.]+)")
if lns then
    print(string.format("  local=%.3f ns/line  remote=%.3f ns/line  ratio=%.3f",
        tonumber(lns), tonumber(rns), tonumber(ratio)))
    if tonumber(ratio) < 1.1 then
        print("  note: ratio ~1.0 confirms QEMU emulates the 2-node TOPOLOGY but not the")
        print("        remote-memory LATENCY on this single-physical-node host. The gap is")
        print("        real on multi-socket hardware; the mechanisms above are what this")
        print("        demo verifies. (SOFT -- not asserted.)")
    else
        print(string.format("  observed a %.0f%% remote penalty (SOFT -- reported, not asserted).",
            (tonumber(ratio) - 1.0) * 100))
    end
else
    print("  (no TIMING line -- allocation may have failed; SOFT, not fatal)")
end

print()
print("RESULT: PASS")
os.exit(0)
