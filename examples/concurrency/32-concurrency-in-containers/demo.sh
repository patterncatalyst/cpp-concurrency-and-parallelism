#!/usr/bin/env bash
# concurrency/32-concurrency-in-containers — cgroup-probe + pool-bench.
#
# Builds the image and runs it. The container's default command runs
# verify.lua, this project's Lua 5.4 assertion harness: it drives the
# cgroup_probe binary, hard-asserts the binary never crashes and reports a
# usable pool size, and hard-asserts the fallback/unlimited path (the
# only one a plain `docker run` can reach: cpu.max reads "max" with no
# --cpus/--cpuset-cpus). The container's own exit code (0 = pass) is this
# script's exit code too.
#
# Usage:
#   ./demo.sh                build + run cgroup_probe + verify (fallback path)
#   ./demo.sh --cpus=N       also pass `--cpus=N` to `docker run`, putting a
#                            real cgroup v2 quota on the container so
#                            verify.lua's quota-path check (soft) has
#                            something to report instead of skipping
#   ./demo.sh --clean        remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-32-concurrency-in-containers:latest

CPUS_LIMIT=""
for arg in "$@"; do
    case "$arg" in
        --clean)
            log_step "Removing image $IMG"
            docker rmi -f "$IMG" 2>/dev/null || true
            exit 0
            ;;
        -h|--help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        --cpus=*)
            CPUS_LIMIT="${arg#--cpus=}"
            ;;
    esac
done

require docker

banner "32-concurrency-in-containers" "cgroup cpu.max vs. hardware_concurrency()"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "cgroup_probe reads /sys/fs/cgroup/cpu.max (a cgroup v2 CPU quota)," \
    "compares it against std::thread::hardware_concurrency(), and sizes" \
    "a worker pool from the tighter of the quota and the cpuset-visible" \
    "core count. A plain docker run has no --cpus, so cpu.max reads" \
    "\"max\" -- watch pool_size fall back to the affinity count."

RUN_ARGS=(--rm)
if [[ -n "$CPUS_LIMIT" ]]; then
    RUN_ARGS+=(--cpus="$CPUS_LIMIT")
    callout \
        "--cpus=$CPUS_LIMIT requested: this run puts a real quota on the" \
        "container's cgroup. Watch quota= become a finite number and" \
        "pool_size track it instead of hardware_concurrency()."
fi

pause "About to run cgroup_probe through verify.lua inside the container"

log_step "Running cgroup_probe + verify.lua inside the container"
set +e
docker run "${RUN_ARGS[@]}" "$IMG"
rc=$?
set -e

echo
if [[ $rc -eq 0 ]]; then
    log_ok "verify.lua PASSED (exit 0)"
else
    log_err "verify.lua FAILED (exit $rc)"
fi

echo
echo "Done. Re-run with --cpus=N to see the quota path, or --clean to remove the image."
exit "$rc"
