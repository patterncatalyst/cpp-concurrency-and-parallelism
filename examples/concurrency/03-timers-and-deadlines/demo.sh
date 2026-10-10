#!/usr/bin/env bash
# concurrency/03-timers-and-deadlines — deadline propagation across a call chain.
#
# Builds the image (no Conan dependency -- pure standard library) and runs
# it. The container's default command runs verify.lua, this project's Lua
# 5.4 assertion harness: it drives deadline_chain through a happy path, a
# slow-hop case at each of the three hops, and three direct already-expired
# calls, then (best-effort) traces clockprobe with strace to confirm
# steady_clock::now() never becomes a clock_gettime syscall. The container's
# own exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run deadline_chain/clockprobe + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-03-timers-and-deadlines:latest

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

banner "03-timers-and-deadlines" "one shared deadline, propagated through a call chain"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "One steady_clock deadline computed once at handle_request(), carried" \
    "unchanged through checkout_and_execute -> execute_query ->" \
    "run_with_deadline. Inject a slow hop anywhere in the chain and the" \
    "caller's total budget still holds -- the slow hop's own sleep is" \
    "clamped to the shared deadline, and every hop checks before it works."
pause "About to run deadline_chain + clockprobe through verify.lua inside the container"

log_step "Running deadline_chain / clockprobe + verify.lua inside the container"
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
