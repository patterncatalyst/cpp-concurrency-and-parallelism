#!/usr/bin/env bash
# concurrency/15-thread-pool — single shared queue vs. work-stealing deques,
# plus a cgroup CPU-quota probe.
#
# Builds the image (one Conan dependency, fmt) and runs it. The container's
# default command runs verify.lua, this project's Lua 5.4 assertion
# harness: it drives pool_bench through both pool kinds at a low and a high
# worker count, asserts every submitted task completed exactly once
# (hard), reports the throughput shape the chapter predicts (soft -- needs
# real core contention to show up), and runs cgroup_probe to report the
# derived CPU-equivalent count against hardware_concurrency() (soft -- an
# unconstrained run correctly falls back to hardware_concurrency()). The
# container's own exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run pool_bench/cgroup_probe + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-15-thread-pool:latest

if [[ "${1:-}" == "--clean" ]]; then
    log_step "Removing image $IMG"
    docker rmi -f "$IMG" 2>/dev/null || true
    exit 0
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,20p' "$0"
    exit 0
fi

require docker

banner "15-thread-pool" "single shared queue vs. work-stealing deques"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "pool_bench runs the same CPU-bound task mix through a single-shared-" \
    "queue pool and a work-stealing-deque pool. Every worker in the single-" \
    "queue pool funnels through one mutex; each work-stealing worker owns" \
    "its own deque and only contends with a thief when it's down to one" \
    "item. cgroup_probe reads cpu.max and compares it against" \
    "hardware_concurrency() -- the number a pool sizes itself from."
pause "About to run pool_bench + cgroup_probe through verify.lua inside the container"

log_step "Running pool_bench / cgroup_probe + verify.lua inside the container"
set +e
docker run --rm "$IMG"
rc=$?
set -e

echo
if [[ $rc -eq 0 ]]; then
    log_ok "verify.lua PASSED (exit 0)"
else
    log_err "verify.lua FAILED (exit $rc)"
fi

echo
echo "Done. Re-run with --clean to remove the image."
exit "$rc"
