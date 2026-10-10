#!/usr/bin/env bash
# concurrency/01-execution-models end-to-end verification (CI wrapper).
#
# Runs demo.sh non-interactively and asserts it exits 0. demo.sh builds the
# image and runs verify.lua (the project's Lua 5.4 assertion harness) inside
# the container; verify.lua is the actual assertion logic (exact counted
# observables for the sequential/concurrent_pinned models, plus a
# conditionally-hard distinct_cpus>1 check for parallel/both) -- this
# wrapper only checks the outer exit code and surfaces full output for CI
# logs, mirroring the 20-mechanical-sympathy test-concurrency-demo-*.sh
# convention.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require docker

DEMO="$REPO_ROOT/examples/concurrency/01-execution-models"
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
log_ok "concurrency/01-execution-models verified — the four execution models, counted"
