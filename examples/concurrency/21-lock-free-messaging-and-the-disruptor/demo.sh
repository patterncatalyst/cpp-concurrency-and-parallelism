#!/usr/bin/env bash
# concurrency/21-lock-free-messaging-and-the-disruptor — single-producer
# ring with a journal + business-logic consumer pipeline.
#
# Builds the image and runs it. The container's default command runs
# verify.lua, this project's Lua 5.4 assertion harness: it drives the
# disruptor_ring binary once, asserts every published event is consumed
# exactly once, in order, by both stages, that the dependent stage never
# reads past the journal stage's sequence, and that the producer's
# back-pressure path actually engaged, then reports throughput as
# information only. The container's own exit code (0 = pass) is this
# script's exit code too.
#
# Usage:
#   ./demo.sh            build + run disruptor_ring + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-21-lock-free-messaging-and-the-disruptor:latest

if [[ "${1:-}" == "--clean" ]]; then
    log_step "Removing image $IMG"
    docker rmi -f "$IMG" 2>/dev/null || true
    exit 0
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,16p' "$0"
    exit 0
fi

require docker

banner "21-lock-free-messaging-and-the-disruptor" "single-producer ring, journal + business-logic pipeline"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "One producer, two consumers over one fixed-capacity ring: a journal" \
    "stage trails the producer's published sequence, a business-logic" \
    "stage trails the journal's sequence instead (the diamond-dependency" \
    "sequence barrier). The business stage is deliberately slowed down" \
    "so the ring fills and the producer has to wait -- watch" \
    "producer_backpressure_events come back greater than zero."
pause "About to run disruptor_ring through verify.lua inside the container"

log_step "Running disruptor_ring + verify.lua inside the container"
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
