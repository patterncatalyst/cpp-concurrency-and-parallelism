#!/usr/bin/env bash
# concurrency/04-jthread-shutdown — SIGTERM -> request_stop() -> clean exit.
#
# Builds the image (no Conan dependency -- pure standard library) and runs
# it. The container's default command runs verify.lua, this project's Lua
# 5.4 assertion harness: it launches jthread_shutdown as its own child
# process, sends it a real SIGTERM after a one-second startup delay, and
# asserts the process exits 0 -- with every worker's "stop observed" line
# and the final "shutdown complete" line present in its log -- well inside a
# generous grace period, with no forced SIGKILL required. The container's
# own exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run jthread_shutdown + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-04-jthread-shutdown:latest

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

banner "04-jthread-shutdown" "SIGTERM -> request_stop() -> clean join, inside the grace period"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "N jthread workers poll a stop_token. verify.lua sends jthread_shutdown" \
    "a REAL SIGTERM -- the signal Kubernetes and docker stop both send --" \
    "and checks it requests a stop on every worker, joins them all, and" \
    "exits 0 well inside the grace period, with no forced SIGKILL needed."
pause "About to run jthread_shutdown through verify.lua inside the container"

log_step "Running jthread_shutdown (SIGTERM shutdown test) via verify.lua inside the container"
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
