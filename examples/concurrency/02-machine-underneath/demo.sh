#!/usr/bin/env bash
# concurrency/02-machine-underneath — cache-hierarchy latency probe.
#
# Builds the image and runs it. The container's default command runs
# verify.lua, this project's Lua 5.4 assertion harness: it drives the
# cache_latency binary through five increasing working-set sizes
# (L1 -> L2 -> L2/L3 -> L3 -> DRAM), asserts the reported latency is
# monotonically non-decreasing across those sizes, and prints the
# absolute ns/access and the DRAM/L1 ratio as information only. The
# container's own exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run cache_latency + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-02-machine-underneath:latest

if [[ "${1:-}" == "--clean" ]]; then
    log_step "Removing image $IMG"
    docker rmi -f "$IMG" 2>/dev/null || true
    exit 0
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,15p' "$0"
    exit 0
fi

require docker

banner "02-machine-underneath" "cache-hierarchy latency probe"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "A random pointer chase over increasing working-set sizes: 8 KiB," \
    "128 KiB, 2 MiB, 32 MiB, 256 MiB -- stepping through L1, L2, L3, and" \
    "past all of them into DRAM. Watch ns_per_access climb at each" \
    "boundary. NUMA local-vs-remote access is Doc 16's demo, run in the" \
    "KVM lab, not here -- a container doesn't give you a real second node."
pause "About to run cache_latency through verify.lua inside the container"

log_step "Running cache_latency (5 working-set sizes) + verify.lua inside the container"
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
