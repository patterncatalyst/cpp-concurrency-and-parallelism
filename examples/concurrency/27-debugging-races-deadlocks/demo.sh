#!/usr/bin/env bash
# concurrency/27-debugging-races-deadlocks — a real data race caught by
# ThreadSanitizer, and a real AB/BA deadlock caught live by gdb.
#
# Builds the image and runs it. The container's default command runs
# verify.lua: it runs racy_counter under ThreadSanitizer and asserts a
# "data race" report naming racy_counter.cpp (clean on the atomic-fixed
# build); it runs ab_ba_deadlock --mode deadlock under an in-container
# `timeout` and asserts the forced AB/BA deadlock is never resolved on its
# own; and it backgrounds a second instance of the same deadlock, attaches
# `gdb -p <pid> --batch -ex 'thread apply all bt'` to it, and asserts the
# live backtrace shows both worker threads blocked in run_transfer()'s
# second lock acquisition -- the lock cycle, read directly off gdb. The
# container's own exit code (0 = pass) is this script's exit code too.
#
# gdb attaching to an already-running process (gdb -p <pid>, as opposed to
# gdb starting a process itself) needs ptrace(2) permission, which Docker
# withdraws from a container by default. Two flags restore what this demo
# needs:
#   --cap-add=SYS_PTRACE        grants CAP_SYS_PTRACE in the container,
#                                without which the kernel refuses the
#                                attach outright regardless of any seccomp
#                                setting.
#   --security-opt seccomp=unconfined
#                                removes Docker's default seccomp filter.
#                                CAP_SYS_PTRACE alone is sometimes enough
#                                on a seccomp profile that already allows
#                                ptrace(2) conditioned on the capability,
#                                but that conditioning isn't guaranteed
#                                across Docker versions/profiles, and this
#                                demo exists specifically to debug a live
#                                process -- the narrower, more-correct fix
#                                (a custom seccomp profile allowlisting
#                                only ptrace) is the production-grade
#                                answer the chapter calls out, but this
#                                demo takes the broader, simpler flag so it
#                                works the same way across hosts.
# Neither flag grants anything beyond what this container's own verify.lua
# needs to debug a process it itself just started, in its own pid
# namespace -- it is not escaping the container or touching the host.
#
# Usage:
#   ./demo.sh            build + run (ThreadSanitizer + gdb checks) + verify
#   ./demo.sh --clean    remove the built image
#   DEMO_NO_PAUSE=1 ./demo.sh    skip the presenter pause (CI / scripted)

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
REPO_ROOT="$(cd "$DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/lib/_helpers.sh"

IMG=cpp-tut/concurrency-27-debugging-races-deadlocks:latest

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

banner "27-debugging-races-deadlocks" "a real data race (TSan) and a real AB/BA deadlock (gdb)"

if should_build "$IMG"; then
    log_step "Building $IMG"
    docker build -t "$IMG" -f Containerfile .
    log_ok "image built"
else
    log_ok "reusing existing image $IMG"
fi

callout \
    "Two std::jthreads, one shared int, zero synchronization -- a genuine" \
    "data race. ThreadSanitizer (built with -fsanitize=thread) must catch" \
    "it; the atomic-fixed build must be clean. Separately: two Account" \
    "mutexes acquired in opposite order, forced into an AB/BA deadlock" \
    "with a std::latch. gdb attaches live and reads the lock cycle" \
    "straight off both threads' blocked backtraces."
pause "About to run both checks through verify.lua inside the container"

log_step "Running racy_counter + ab_ba_deadlock + verify.lua inside the container"
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
