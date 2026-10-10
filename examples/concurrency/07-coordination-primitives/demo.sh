#!/usr/bin/env bash
# concurrency/07-coordination-primitives — a barrier-phased worker pool.
#
# Builds the image and runs it. The container's default command runs
# verify.lua, this project's Lua 5.4 assertion harness: it drives
# barrier_workers through its default worker/phase configuration, asserts
# the completion function ran exactly once per phase (never zero, never
# more than once), and asserts the final merged total matches the
# closed-form expected sum. The container's own exit code (0 = pass) is
# this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run barrier_workers + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-07-coordination-primitives:latest

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

banner "07-coordination-primitives" "a barrier-phased worker pool"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "A fixed worker pool runs through several phases, synchronized by one" \
    "std::barrier. Each worker writes a partial sum into its own slot;" \
    "the barrier's completion function runs exactly once per phase," \
    "after all workers arrive and before any is released, merging the" \
    "slots into a running total."
pause "About to run barrier_workers through verify.lua inside the container"

log_step "Running barrier_workers + verify.lua inside the container"
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
