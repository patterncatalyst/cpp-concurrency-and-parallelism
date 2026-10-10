#!/usr/bin/env bash
# concurrency/10-futures-promises-packaged-tasks — launch policies and a
# packaged_task worker pool.
#
# Builds the image (one Conan dependency, fmt) and runs it. The container's
# default command runs verify.lua, this project's Lua 5.4 assertion
# harness: it drives launch_policy through async/deferred/default rounds
# and asserts the thread-id distinction the chapter's launch-policy section
# describes, then drives worker_pool through N tasks with one deliberate
# failure and asserts the failing task's exception surfaces at its own
# future::get() while every other task's result stays correct. The
# container's own exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run launch_policy/worker_pool + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-10-futures-promises-packaged-tasks:latest

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

banner "10-futures-promises-packaged-tasks" "launch policies vs. a packaged_task worker pool"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "launch_policy submits the same tasks under std::launch::async," \
    "std::launch::deferred, and the default policy: async tasks run on a" \
    "new thread, deferred tasks run on the submitter's OWN thread inside" \
    "get(). worker_pool wraps callables in std::packaged_task and shows one" \
    "task's exception surfacing only at that task's own future::get()."
pause "About to run launch_policy + worker_pool through verify.lua inside the container"

log_step "Running launch_policy / worker_pool + verify.lua inside the container"
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
