#!/usr/bin/env bash
# concurrency/33-capstone-ingest-match-publish — the book's capstone
# pipeline: ingest -> match -> publish, in one process.
#
# Builds the image (one Conan dependency, fmt, same as every sibling
# example) and runs it. The container's default command runs verify.lua,
# this project's Lua 5.4 assertion harness: it runs capstone_pipeline
# once, parses every EVENT line and the final SUMMARY line, and checks
# that no accepted order was lost or duplicated through either ring, that
# the order book's own conservation counters balance, that the match
# stage really is single-threaded, that the overload burst actually
# engaged back-pressure (BUSY responses, not unbounded growth), and that
# end-to-end p50/p99/p99.9 latency figures are present. The container's
# own exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run capstone_pipeline + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-33-capstone-ingest-match-publish:latest

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

banner "33-capstone-ingest-match-publish" "ingest -> match -> publish, end to end"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "Several ingest threads generate NEW/CANCEL orders and hand them off" \
    "over a bounded lock-free ring to ONE pinned matching thread running a" \
    "zero-per-order-allocation price-time-priority order book. Outcomes" \
    "cross a second ring to a small publish pool. A deliberate overload" \
    "burst should fill the ingest ring and produce BUSY responses --" \
    "back-pressure, not unbounded memory growth. Watch the SUMMARY line's" \
    "p50/p99/p99.9 latency figures at the end."
pause "About to run capstone_pipeline through verify.lua inside the container"

log_step "Running capstone_pipeline + verify.lua inside the container"
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
