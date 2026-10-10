#!/usr/bin/env bash
# concurrency/34-appendix-build-and-toolchain — reference build-harness slice.
#
# Builds the image (gcc build required; clang-release and clang-tsan legs
# best-effort, depending on whether this UBI10 image happens to carry
# clang and a working ThreadSanitizer runtime) and runs it. The
# container's default command runs verify.lua, this project's Lua 5.4
# assertion harness: it hard-asserts the gcc build produces its expected
# output and that the --inject-race path is reachable, and reports the
# gcc-vs-clang parity and TSan race-detection checks as real passes when
# the legs are available, or a clearly-labeled SOFT skip when they
# aren't. The container's own exit code (0 = pass) is this script's exit
# code too.
#
# Usage:
#   ./demo.sh            build + run all available legs + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-34-appendix-build-and-toolchain:latest

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

banner "34-appendix-build-and-toolchain" "the build harness, against its own reference program"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "One tiny program (shared_counter), built three ways: gcc (always)," \
    "clang (best-effort), clang -fsanitize=thread (best-effort). The gcc" \
    "build must produce an exact count; the --inject-race flag reaches a" \
    "deliberately unsynchronized path a TSan build should flag and a" \
    "plain build should not. The full 5-preset matrix (CMakePresets.json" \
    "in this directory) is this appendix's complete reference -- this" \
    "container exercises a real, achievable slice of it."
pause "About to run shared_counter (all available legs) through verify.lua"

log_step "Running shared_counter + verify.lua inside the container"
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
