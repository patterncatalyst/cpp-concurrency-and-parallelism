#!/usr/bin/env bash
# concurrency/05-futex-cost — uncontended vs. contended mutex cost, and the
# futex syscall count behind both.
#
# Builds the image and runs it. The container's default command runs
# verify.lua, this project's Lua 5.4 assertion harness: it drives the
# futex_cost binary through baseline (no mutex), uncontended (one thread,
# one mutex), and contended (N threads, one shared mutex) modes, asserts
# the final count is exactly N in every mode (contention is a performance
# bug, never a correctness bug), and then -- if strace is available and
# able to attach -- reports futex(2) call counts for each mode, falling
# back to a behavioral timing comparison otherwise. The container's own
# exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run futex_cost (all three modes) + verify
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-05-futex-cost:latest

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

banner "05-futex-cost" "uncontended vs. contended mutex cost, and the futex(2) call count behind both"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "Three modes, same N increments: baseline (no mutex), uncontended" \
    "(one thread, one mutex), contended (N threads, one shared mutex)." \
    "Watch the futex(2) call count: uncontended matches baseline (the" \
    "compare-and-swap never loses), contended is orders of magnitude" \
    "higher (the compare-and-swap genuinely fails and crosses into the" \
    "kernel). Correctness -- the final count -- never changes either way."
pause "About to run futex_cost through verify.lua inside the container"

log_step "Running futex_cost (all three modes) + verify.lua inside the container"
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
