#!/usr/bin/env bash
# concurrency/24-concurrent-rest — back-pressure and overload shedding.
#
# Builds the image (one Conan dependency, a trimmed Boost, for Boost.Asio
# + Boost.Beast) and runs it. The container's default command runs
# verify.lua, this project's Lua 5.4 assertion harness: it starts the
# Beast-based rest_server in the background, drives it with the
# Beast-based rest_client first below its in-flight cap (expect all 200s)
# then well above it (expect a mix of 200s and 503s, zero dropped/reset/
# hung requests), then SIGTERMs the server and asserts a clean drain. The
# container's own exit code (0 = pass) is this script's exit code too.
#
# No host port mapping: the server binds 127.0.0.1:18080 and the client
# that loads it runs in the same container, both started and torn down by
# verify.lua -- there is nothing outside the container to reach the port.
#
# Usage:
#   ./demo.sh            build + run server/client/verify inside the container
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-24-concurrent-rest:latest

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

banner "24-concurrent-rest" "back-pressure and overload shedding"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "A Boost.Beast async HTTP server on 127.0.0.1:18080 with a small" \
    "in-flight-request cap enforced by an atomic counter. Below the cap" \
    "every request gets 200 OK; a request that arrives once the cap is" \
    "already full gets a 503 + Retry-After straight from the capacity" \
    "gate -- no handler work, no queueing. A concurrent Beast-based" \
    "client drives the server first below the cap, then well above it."
pause "About to run rest_server + rest_client through verify.lua inside the container"

log_step "Running rest_server + rest_client + verify.lua inside the container"
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
