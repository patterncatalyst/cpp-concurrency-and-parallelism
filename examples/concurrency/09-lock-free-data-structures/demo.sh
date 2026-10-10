#!/usr/bin/env bash
# concurrency/09-lock-free-data-structures — SPSC ring buffer, padded vs.
# unpadded cursors.
#
# Builds the image and runs it. The container's default command runs
# verify.lua, this project's Lua 5.4 assertion harness: it sweeps spsc_ring
# across several capacities (including 1, maximum contention) and both
# --pad settings, asserting every pushed item is consumed exactly once in
# order (no loss, duplication, or reordering), then compares padded vs.
# unpadded average throughput at a fixed capacity over several trials. The
# container's own exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run spsc_ring (sweep + timing) + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-09-lock-free-data-structures:latest

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

banner "09-lock-free-data-structures" "SPSC ring buffer: correctness sweep + false-sharing on the cursors"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "One producer, one consumer, a bounded ring buffer -- one writer per" \
    "counter, no lock, no CAS. verify.lua sweeps --capacity 1/2/64/1024 x" \
    "--pad on/off and checks every item lands exactly once, in order." \
    "Then it compares throughput: unpadded head/tail share a cache line," \
    "padded cursors each get their own."
pause "About to run spsc_ring through verify.lua inside the container"

log_step "Running spsc_ring (correctness sweep + timing) + verify.lua inside the container"
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
