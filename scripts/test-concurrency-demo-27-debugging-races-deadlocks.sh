#!/usr/bin/env bash
# concurrency/27-debugging-races-deadlocks end-to-end verification (CI
# wrapper).
#
# Runs demo.sh non-interactively and asserts it exits 0. demo.sh builds the
# image and runs verify.lua (the project's Lua 5.4 assertion harness)
# inside the container, with --cap-add=SYS_PTRACE and --security-opt
# seccomp=unconfined (required for the gdb -p <pid> attach step -- see
# that directory's README) -- this wrapper only checks the outer exit code
# and surfaces full output for CI logs, mirroring the mechanical-sympathy
# tutorial's test-concurrency-demo-*.sh convention.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require docker

DEMO="$REPO_ROOT/examples/concurrency/27-debugging-races-deadlocks"
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
log_ok "concurrency/27-debugging-races-deadlocks verified — real data race (TSan) + real AB/BA deadlock (gdb)"
