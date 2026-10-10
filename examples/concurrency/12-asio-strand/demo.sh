#!/usr/bin/env bash
# concurrency/12-asio-strand — strand-vs-mutex: serialization without a lock.
#
# Builds the image (Boost.Asio, pinned static, plus fmt) and runs it. The
# container's default command runs verify.lua, this project's Lua 5.4
# assertion harness: it drives asio_strand through several trials each of
# --mode strand, --mode nostrand, --mode strand-cost, and --mode mutex-cost,
# asserting the strand case never overlaps and always lands on the exact
# count, the no-strand case's race actually manifests, and reporting
# (informationally) which mechanism needed fewer voluntary context
# switches for equivalent, equally correct work. The container's own exit
# code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run asio_strand (all four modes) + verify
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-12-asio-strand:latest

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

banner "12-asio-strand" "strand vs. mutex: serialization without a lock"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "The same unsynchronized counter, incremented by several threads," \
    "posted two ways: through a strand (serialized, no lock, never" \
    "overlaps) and straight to a multithreaded io_context (overlaps," \
    "lost updates). Then the same comparison for kernel cost: a strand" \
    "vs. a std::mutex doing equivalent, equally correct work."
pause "About to run asio_strand through verify.lua inside the container"

log_step "Running asio_strand (all four modes) + verify.lua inside the container"
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
