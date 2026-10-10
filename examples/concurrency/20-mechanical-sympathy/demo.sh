#!/usr/bin/env bash
# concurrency/20-mechanical-sympathy — false sharing vs. cache-line padding.
#
# Builds the image (one Conan dependency, fmt, to establish the pattern)
# and runs it. The container's default command runs verify.lua, this
# project's Lua 5.4 assertion harness: it drives the false_sharing binary
# through several trials each of --pad off and --pad on, asserts the final
# counts are exactly N in every trial regardless of padding (false sharing
# is a performance bug, never a correctness bug), and reports whether the
# padded run's average elapsed time came in measurably lower -- the signal
# that false sharing is real. The container's own exit code (0 = pass) is
# this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run false_sharing in both modes + verify
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-20-mechanical-sympathy:latest

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

banner "20-mechanical-sympathy" "false sharing vs. cache-line padding"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "Two threads, each incrementing its own atomic<uint64_t> counter," \
    "pinned to separate CPUs. --pad off: both counters share a cache" \
    "line. --pad on: each gets its own hardware_destructive_interference" \
    "line. Watch elapsed_ms drop with no change to the arithmetic."
pause "About to run false_sharing through verify.lua inside the container"

log_step "Running false_sharing (both modes) + verify.lua inside the container"
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
