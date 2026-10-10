#!/usr/bin/env bash
# concurrency/06-lock-ordering — AB/BA deadlock with std::lock_guard, fixed
# with std::scoped_lock.
#
# Builds the image and runs it. The container's default command runs
# verify.lua, this project's Lua 5.4 assertion harness: it runs the
# --mode deadlock build under an in-container `timeout` and asserts
# `timeout` had to kill it (the forced AB/BA deadlock never exits on its
# own), then runs the --mode fixed build (std::scoped_lock, same opposing
# acquisition order) and asserts it exits 0 with the expected total op
# count. The container's own exit code (0 = pass) is this script's exit
# code too.
#
# Usage:
#   ./demo.sh            build + run lock_ordering (both modes) + verify
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-06-lock-ordering:latest

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

banner "06-lock-ordering" "AB/BA deadlock with lock_guard, fixed with scoped_lock"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "Two mutexes, two threads, opposing acquisition order. --mode deadlock" \
    "forces the classic AB/BA deadlock with a std::latch so it reproduces" \
    "every run -- it never exits on its own, so verify.lua runs it under" \
    "an in-container timeout and asserts the kill. --mode fixed does the" \
    "same opposing order with std::scoped_lock, which does not care about" \
    "argument order, and always completes."
pause "About to run lock_ordering through verify.lua inside the container"

log_step "Running lock_ordering (both modes) + verify.lua inside the container"
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
