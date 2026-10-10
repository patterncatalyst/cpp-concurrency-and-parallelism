#!/usr/bin/env bash
# concurrency/08-atomics-and-the-memory-model — one-slot hand-off under
# seq_cst, acquire/release, and a deliberately-broken plain-variable case.
#
# Builds the image and runs it. The container's default command runs
# verify.lua, this project's Lua 5.4 assertion harness: it drives the
# ring_handoff binary through several trials each of --mode seqcst and
# --mode acqrel (asserting both always produce the exact expected sum), a
# single --mode broken run (asserting it does NOT cleanly complete with the
# right answer -- the negative case has to actually misbehave), and reports
# whether acquire/release's average elapsed time came in measurably lower
# than seq_cst's. The container's own exit code (0 = pass) is this script's
# exit code too.
#
# Usage:
#   ./demo.sh            build + run ring_handoff in all three modes + verify
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-08-atomics-and-the-memory-model:latest

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

banner "08-atomics-and-the-memory-model" "one-slot hand-off: seq_cst vs acquire/release vs broken"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "One producer, one consumer, one shared slot. --mode seqcst and" \
    "--mode acqrel both use std::atomic and both must be exactly correct." \
    "--mode broken uses plain, non-atomic head/tail counters -- watch it" \
    "stall instead of completing, because -O2 hoists the consumer's" \
    "unsynchronized busy-wait read out of its own loop."
pause "About to run ring_handoff through verify.lua inside the container"

log_step "Running ring_handoff (all three modes) + verify.lua inside the container"
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
