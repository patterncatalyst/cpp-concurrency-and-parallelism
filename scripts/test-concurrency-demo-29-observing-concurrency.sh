#!/usr/bin/env bash
# concurrency/29-observing-concurrency end-to-end verification (CI wrapper).
#
# Runs demo.sh non-interactively and asserts it exits 0. demo.sh brings up
# a docker compose stack (the instrumented service + grafana/otel-lgtm),
# waits for the service's batch workload to finish, then runs verify.lua
# (this project's Lua 5.4 assertion harness) against Tempo and the
# Prometheus-compatible API in front of Mimir for REAL ingested telemetry
# -- span parent/child nesting across the pool's thread hop is hard;
# trace-count-vs-expected and the queue-depth metric's observed max value
# are soft -- this wrapper only checks the outer exit code and surfaces
# full output for CI logs, mirroring the 20-mechanical-sympathy convention.
#
# Unlike every earlier demo's CI wrapper, this one needs the Docker Compose
# v2 plugin (`docker compose`), not just the Docker CLI, and a materially
# longer timeout: standing up grafana/otel-lgtm, compiling opentelemetry-cpp
# on a cold Conan cache, and waiting out Tempo/Mimir ingestion lag are all
# slower than any single-container demo in this series.

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

require docker

if ! docker compose version >/dev/null 2>&1; then
    log_err "docker compose (the v2 CLI plugin) is required -- the legacy docker-compose binary is not supported"
    exit 1
fi

DEMO="$REPO_ROOT/examples/concurrency/29-observing-concurrency"
cd "$DEMO"

export DEMO_NO_PAUSE=1

log_step "Running demo.sh non-interactively (this one builds a multi-container stack -- expect it to take longer than a single-container demo)"
if ./demo.sh; then
    log_ok "demo.sh exited 0 (verify.lua passed)"
else
    rc=$?
    log_err "demo.sh exited $rc"
    exit "$rc"
fi

log_step "RESULT"
log_ok "concurrency/29-observing-concurrency verified -- instrumented thread pool, traces + queue-depth metric, LGTM stack"
