#!/usr/bin/env bash
# concurrency/25-concurrent-grpc — raw async CompletionQueue gRPC server,
# bounded in-flight admission, under concurrent server-streaming load.
#
# Builds the image (the heaviest Conan graph in this project: gRPC +
# protobuf + abseil, built fully static) and runs it. The container's
# default command runs verify.lua, which starts async_server in the
# background, drives concurrent_client against it -- first with exactly
# cap concurrent calls (nothing should be rejected), then with cap plus a
# deliberate overflow (admitted calls must never exceed cap, the rest must
# get RESOURCE_EXHAUSTED, none may hang) -- then signals the server to
# drain and checks it exits 0. The container's own exit code (0 = pass) is
# this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run server+client inside the container + verify
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-25-concurrent-grpc:latest

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

banner "25-concurrent-grpc" "async gRPC server, bounded admission under concurrent load"

callout \
    "This is the heaviest Conan graph in the project -- gRPC + protobuf +" \
    "abseil, built fully static from source. The first build can take a" \
    "long time; a warm Conan layer in the image cache makes every rebuild" \
    "after that fast."
pause "About to build (first build may take several minutes or more)"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "verify.lua starts async_server in the background inside the" \
    "container, then drives concurrent_client at it from the SAME" \
    "container over 127.0.0.1:50051 -- first exactly at cap (nothing" \
    "rejected), then cap plus overflow (admitted calls == cap, the rest" \
    "RESOURCE_EXHAUSTED, none hung) -- before signaling a clean shutdown."
pause "About to run server+client through verify.lua inside the container"

log_step "Running async_server + concurrent_client + verify.lua inside the container"
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
