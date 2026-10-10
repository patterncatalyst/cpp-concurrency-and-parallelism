#!/usr/bin/env bash
# concurrency/18-benchmarking-without-deception — the chapter's own
# benchmark harness, applied to an atomic fetch_add workload.
#
# Builds the image (one Conan dependency, fmt) and runs it. The container's
# default command runs verify.lua, this project's Lua 5.4 assertion
# harness: it drives bench through its default harness mode and asserts the
# coordinated-omission invariant (co_p99_ns >= p99_ns), co_n >= n, and
# checksum correctness, then drives bench --naive and asserts the output
# contains no percentile field at all. The container's own exit code
# (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run bench (harness + --naive) + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-18-benchmarking-without-deception:latest

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

banner "18-benchmarking-without-deception" "warmup, coordinated omission, and percentiles vs. the mean"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "bench times one atomic fetch_add per iteration after discarding" \
    "--warmup throwaway iterations, then reports min/median/p99/max plus" \
    "the coordinated-omission-corrected co_p99/co_n. --naive skips warmup" \
    "and times the whole loop as one sample -- no percentile field appears" \
    "in its output at all, because none was ever computed."
pause "About to run bench (harness + --naive) through verify.lua inside the container"

log_step "Running bench + verify.lua inside the container"
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
