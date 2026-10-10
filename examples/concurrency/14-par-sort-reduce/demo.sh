#!/usr/bin/env bash
# concurrency/14-par-sort-reduce — seq vs par vs par_unseq, same sort + reduce.
#
# Builds the image (one Conan dependency, oneTBB, needed for
# std::execution::par/par_unseq to LINK under libstdc++, plus fmt for
# output) and runs it. The container's default command runs verify.lua,
# this project's Lua 5.4 assertion harness: it drives par_sort_reduce
# through several trials, asserts the sort hash and reduce sum are
# IDENTICAL across seq/par/par_unseq (correctness is policy-independent),
# and reports -- as a soft signal, not a requirement -- whether the par
# policy actually touched more than one CPU. The container's own exit code
# (0 = pass) is this script's exit code too.
#
# This example runs in plain Docker with an explicit --cpus limit (never a
# KVM lab, never a host-level CPU/NUMA/governor change): the assertions here
# only need the SIGN of "did par use more than one CPU," not a reproducible
# speedup number, so a container's own cpuset is sufficient and the demo
# never has to touch anything about the host it runs on.
#
# Usage:
#   ./demo.sh            build + run par_sort_reduce + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)
#   DEMO_CPUS=2 ./demo.sh        change the container's CPU allotment (default 4)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-14-par-sort-reduce:latest
CPUS="${DEMO_CPUS:-4}"

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

banner "14-par-sort-reduce" "seq vs par vs par_unseq -- same sort, same reduce"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "Same input, sorted and transform_reduced three times -- once per" \
    "execution policy (seq, par, par_unseq). sort_hash and reduce_sum must" \
    "match across all three: the policy changes HOW the work is scheduled," \
    "never WHAT the answer is. Watch distinct_cpus rise for par when the" \
    "container (--cpus=$CPUS here) actually has room to spread it out."
pause "About to run par_sort_reduce through verify.lua inside the container (--cpus=$CPUS)"

log_step "Running par_sort_reduce (all three policies) + verify.lua inside the container"
set +e
docker run --rm --cpus="$CPUS" "$IMG"
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
