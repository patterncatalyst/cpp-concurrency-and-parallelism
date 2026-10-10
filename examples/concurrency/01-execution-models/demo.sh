#!/usr/bin/env bash
# concurrency/01-execution-models — the four execution models, counted.
#
# Builds the image (one Conan dependency, oneTBB, needed for
# std::execution::par to LINK under libstdc++) and runs it. The container's
# default command runs verify.lua, this project's Lua 5.4 assertion harness:
# it drives execution_models through several trials, asserts the
# sequential and concurrent_pinned models' counted observables exactly
# (environment-independent), and asserts the parallel/both models touched
# more than one CPU in at least one trial whenever the container's own
# cpuset actually offers more than one. The container's own exit code
# (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run execution_models + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-01-execution-models:latest

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

banner "01-execution-models" "concurrency vs parallelism, measured in counts not clocks"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "Same process() workload, four execution models: sequential (no" \
    "threads), concurrent_pinned (many jthreads, one CPU), parallel" \
    "(std::execution::par), and both (oversubscribed, unpinned)." \
    "Watch distinct_cpus and max_inflight change across models with no" \
    "wall-clock timing involved -- counts, not durations."
pause "About to run execution_models through verify.lua inside the container"

log_step "Running execution_models (all four models) + verify.lua inside the container"
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
