#!/usr/bin/env bash
# concurrency/25-concurrent-grpc end-to-end verification (CI wrapper).
#
# Runs demo.sh non-interactively and asserts it exits 0. demo.sh builds the
# image (gRPC + protobuf + abseil, this project's heaviest Conan graph --
# expect a genuinely long build on a cold Conan cache) and runs verify.lua
# (the project's Lua 5.4 assertion harness) inside the container:
# verify.lua starts async_server in the background, drives
# concurrent_client against it through an under-cap and an over-cap phase,
# then signals a graceful shutdown and checks the server drained cleanly.
# verify.lua is the actual assertion logic -- this wrapper only checks the
# outer exit code and surfaces full output for CI logs, mirroring the
# statelessness tutorial's test-stateless-demo-*.sh convention.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require docker

DEMO="$REPO_ROOT/examples/concurrency/25-concurrent-grpc"
cd "$DEMO"

export DEMO_NO_PAUSE=1

log_step "Running demo.sh non-interactively"
if ./demo.sh; then
    log_ok "demo.sh exited 0 (verify.lua passed)"
else
    rc=$?
    log_err "demo.sh exited $rc"
    exit "$rc"
fi

log_step "RESULT"
log_ok "concurrency/25-concurrent-grpc verified — async gRPC server, bounded admission under concurrent load"
