#!/usr/bin/env bash
# concurrency/28-sanitizers — the same data race caught two independent
# ways (ThreadSanitizer vs. Valgrind Helgrind), plus a real heap-use-
# after-free caught by AddressSanitizer.
#
# Builds the image and runs it. The container's default command runs
# verify.lua: it runs racy_counter under ThreadSanitizer AND under
# `valgrind --tool=helgrind` and asserts both independently report the
# race at the same increment()/racy_counter.cpp location (clean under both
# on the atomic-fixed build); it runs detached_uaf under AddressSanitizer
# and asserts a reported heap-use-after-free naming both the allocating
# and freeing call stacks (clean on the shared_ptr-fixed build). The
# container's own exit code (0 = pass) is this script's exit code too.
#
# This demo does not use gdb and does not attach to a running process, so
# strictly it needs neither of the flags below. They're included anyway
# for two reasons documented in 27-debugging-races-deadlocks/README.md:
# this project runs every chapter 27/28 demo image the same way rather
# than special-casing capabilities per tool, and some sandboxed container
# runtimes' syscall-emulation layers (not this host's default) can trip up
# a software CPU like Valgrind's in ways a relaxed seccomp profile avoids.
#   --cap-add=SYS_PTRACE                grants CAP_SYS_PTRACE (unused here,
#                                        kept for parity with 27's image).
#   --security-opt seccomp=unconfined   removes Docker's default seccomp
#                                        filter, the belt-and-suspenders
#                                        measure for a sandboxed runtime's
#                                        syscall-emulation layer tripping
#                                        up Valgrind's own software CPU.
#
# Usage:
#   ./demo.sh            build + run (TSan + Helgrind + ASan checks) + verify
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-28-sanitizers:latest

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

banner "28-sanitizers" "one race, two independent detectors; a real use-after-free, caught by ASan"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "The same racy counter from chapter 27, checked two independent ways:" \
    "ThreadSanitizer's compile-time vector clocks, and Valgrind Helgrind's" \
    "binary re-translation + lockset analysis -- both must name the exact" \
    "same increment() source line. Separately: a detached thread reads" \
    "through a pointer the main thread already freed -- a genuine," \
    "concurrency-born heap-use-after-free, caught by AddressSanitizer." \
    "A shared_ptr fix is clean under every tool."
pause "About to run all three checks through verify.lua inside the container"

log_step "Running racy_counter + detached_uaf + verify.lua inside the container"
set +e
docker run --rm \
    --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    "$IMG"
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
