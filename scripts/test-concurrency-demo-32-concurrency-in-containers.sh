#!/usr/bin/env bash
# concurrency/32-concurrency-in-containers end-to-end verification (CI wrapper).
#
# Runs demo.sh non-interactively (the default, unconstrained path -- no
# --cpus/--cpuset-cpus) and asserts it exits 0. demo.sh builds the image
# and runs verify.lua (the project's Lua 5.4 assertion harness) inside
# the container; verify.lua is the actual assertion logic (the binary
# runs and parses cleanly, every reported number is sane, and the
# fallback/unlimited quota path is sized correctly) -- this wrapper only
# checks the outer exit code and surfaces full output for CI logs,
# mirroring the 20-mechanical-sympathy test-concurrency-demo-*.sh
# convention. The quota path (running with --cpus=N) is a soft, manual
# exercise documented in the example's README -- it is not exercised by
# this wrapper.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require docker

DEMO="$REPO_ROOT/examples/concurrency/32-concurrency-in-containers"
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
log_ok "concurrency/32-concurrency-in-containers verified — cgroup cpu.max vs. hardware_concurrency() demo"
