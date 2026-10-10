#!/usr/bin/env bash
# concurrency/29-observing-concurrency — instrumented thread pool + LGTM stack.
#
# Unlike every earlier demo in this series (one Containerfile, one `docker
# run`), this one is a multi-container docker compose stack: the
# instrumented service, the grafana/otel-lgtm all-in-one observability
# backend, and a profile-gated verifier that queries Tempo and the
# Prometheus-compatible API in front of Mimir for REAL ingested telemetry.
#
# Sequence:
#   1. docker compose up -d --build   (lgtm, then service once lgtm is healthy)
#   2. wait for the service container to exit (it is a batch run, not a
#      server -- it drives its own workload and exits on its own)
#   3. docker compose run --rm verifier   (profile-gated; not started by
#      step 1) -- polls Tempo/Mimir with retries, since the stack takes
#      real time to ingest what the service already sent
#   4. docker compose down -v --remove-orphans, ALWAYS, even on failure
#      (trap on EXIT) -- this stack must come up and tear down cleanly and
#      bounded every single run, including a failing one
#
# This script's own exit code is the verifier's exit code (or the
# service's, if the service itself failed before there was anything to
# verify).
#
# Usage:
#   ./demo.sh            build + bring up the stack + run the workload + verify
#   ./demo.sh --clean    tear down and remove the images this demo built
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

if [[ "${1:-}" == "--clean" ]]; then
    log_step "Tearing down the stack and removing locally built images"
    docker compose down -v --remove-orphans --rmi local 2>/dev/null || true
    exit 0
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,24p' "$0"
    exit 0
fi

require docker

# Always tear the stack down on the way out, pass or fail -- a compose
# stack left running is the multi-container equivalent of a leaked
# container, and CI will run this script many times.
cleanup() {
    local rc=$?
    log_step "Tearing down the stack (docker compose down -v)"
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    return $rc
}
trap cleanup EXIT

banner "29-observing-concurrency" "instrumented thread pool -> OTel Collector -> LGTM stack"

callout \
    "24 concurrent 'requests', each a root span fanning out to 3 pool" \
    "tasks on a 2-worker pool -- 72 tasks landing on 2 workers backs the" \
    "queue up before it drains. Each task's span is created on a WORKER" \
    "thread with no call-stack relation to the request that submitted it;" \
    "the only thing connecting them is an explicitly captured Context" \
    "crossing that thread hop. verify.lua proves the nesting survived by" \
    "querying Tempo directly, not by trusting the service's own logs."

log_step "Building images (service + verifier) and starting the LGTM stack"
docker compose up -d --build lgtm service
log_ok "lgtm is healthy; service is running"

pause "About to wait for the service's batch run to finish"

log_step "Waiting for the service to finish its workload and exit"
service_cid="$(docker compose ps -q service)"
docker wait "$service_cid" >/dev/null
service_rc="$(docker inspect "$service_cid" --format '{{.State.ExitCode}}')"
echo
docker compose logs --no-color service
echo

rc=0
if [[ "$service_rc" != "0" ]]; then
    log_err "service exited $service_rc -- the workload itself failed, skipping verification"
    rc=1
else
    log_ok "service completed its workload (exit 0)"

    pause "About to query Tempo + Mimir for the real, ingested telemetry"

    log_step "Running verify.lua against Tempo and the Prometheus-compatible API"
    set +e
    docker compose run --rm --build verifier
    rc=$?
    set -e

    echo
    if [[ $rc -eq 0 ]]; then
        log_ok "verify.lua PASSED (exit 0)"
    else
        log_err "verify.lua FAILED (exit $rc)"
    fi
fi

echo
echo "Done. Re-run with --clean to tear down and remove the built images."
exit "$rc"
