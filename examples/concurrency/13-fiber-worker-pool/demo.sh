#!/usr/bin/env bash
# concurrency/13-fiber-worker-pool — fiber vs. thread worker pool, plus the
# guard-page stack-overflow demonstration.
#
# Builds the image (Boost.Fiber + Boost.Context, statically linked, plus
# fmt for output formatting) and runs it. The container's default command
# runs verify.lua, this project's Lua 5.4 assertion harness: it drives the
# SAME worker-pool loop as N boost::fibers::fiber workers and as N
# std::thread workers over a shared boost::fibers::buffered_channel,
# asserts every item is processed exactly once with the correct aggregate
# in both modes, asserts the guard-page overflow case terminates
# deterministically via signal within its own timeout, and reports (never
# asserts against a fixed ratio) the fiber pool's lower peak RSS. The
# container's own exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run fiber_worker_pool (both modes) + verify
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-13-fiber-worker-pool:latest

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

banner "13-fiber-worker-pool" "fibers vs. threads over a buffered channel, and the guard page"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "One worker loop, run two ways: N boost::fibers::fiber workers under" \
    "round_robin (all on one OS thread) vs. N std::thread workers, both" \
    "pulling from the same boost::fibers::buffered_channel. Watch for" \
    "exact item counts/aggregates in both modes, then the guard-page" \
    "case deliberately overflowing a protected_fixedsize_stack fiber" \
    "stack -- a clean, immediate SIGSEGV instead of silent corruption."
pause "About to run fiber_worker_pool through verify.lua inside the container"

log_step "Running fiber_worker_pool (fiber + thread + guard-page) + verify.lua inside the container"
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
