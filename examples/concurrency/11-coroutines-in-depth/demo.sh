#!/usr/bin/env bash
# concurrency/11-coroutines-in-depth — generator, Task<T>, and HALO.
#
# Builds the image (one Conan dependency, fmt, for output formatting only
# -- the coroutine machinery is pure C++20 standard library) and runs it.
# The container's default command runs verify.lua, this project's Lua 5.4
# assertion harness: it checks the hand-rolled Generator<T> produces the
# exact first 10 Fibonacci terms, the Task<T> chain (driven through
# symmetric transfer) returns the exact expected value, and reports the
# HALO frame-size observation as an informational, never-asserted note.
# The container's own exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run coroutines_in_depth + verify
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-11-coroutines-in-depth:latest

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

banner "11-coroutines-in-depth" "generator, Task<T>, and HALO"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "A hand-rolled Generator<T> lazily yields Fibonacci terms via" \
    "co_yield; a Task<T> chains two co_await'd sub-tasks through" \
    "symmetric transfer (a tail call, not a recursive .resume()); and an" \
    "instrumented promise_type::operator new reports whether this" \
    "toolchain elided the coroutine frame allocation (HALO) for a tiny" \
    "probe vs. one carrying a 4 KiB buffer across a real suspension."
pause "About to run coroutines_in_depth through verify.lua inside the container"

log_step "Running coroutines_in_depth + verify.lua inside the container"
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
