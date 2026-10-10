#!/usr/bin/env bash
# concurrency/17-simd — scalar vs std::experimental::simd, AoS vs SoA.
#
# Builds the image (one Conan dependency, fmt, same weight class as
# 20-mechanical-sympathy) and runs it. The container's default command runs
# verify.lua, this project's Lua 5.4 assertion harness: it drives
# simd_particles through several trials, asserts the three update variants
# (array-of-structs scalar, struct-of-arrays scalar, struct-of-arrays
# std::experimental::simd) produce BIT-IDENTICAL final positions, and
# reports -- as a soft signal, not a requirement -- whether the explicit
# SIMD path actually ran faster than its scalar counterpart. The container's
# own exit code (0 = pass) is this script's exit code too.
#
# Usage:
#   ./demo.sh            build + run simd_particles + verify.lua
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-17-simd:latest

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

banner "17-simd" "scalar vs std::experimental::simd -- AoS vs SoA"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "Same pos += vel*dt recurrence, three ways: array-of-structs scalar," \
    "struct-of-arrays scalar, struct-of-arrays std::experimental::simd." \
    "All three must land on bit-identical final positions -- the hash" \
    "lines must match. Watch soa_simd's time_ms relative to soa_scalar's" \
    "with no change to the arithmetic, only the layout and the explicit" \
    "vector type."
pause "About to run simd_particles through verify.lua inside the container"

log_step "Running simd_particles (all three variants) + verify.lua inside the container"
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
