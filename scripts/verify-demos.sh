#!/usr/bin/env bash
# verify-demos.sh — build + verify a set of concurrency demos sequentially.
#
# Demos share the Conan cache, Docker, and fixed ports, so they are run one at a
# time, never in parallel. Non-fail-fast: every demo runs, a FAIL does not stop
# the others, and a summary prints at the end. Exit 0 only if every demo passed.
#
#   scripts/verify-demos.sh                 # all demos under examples/concurrency/
#   scripts/verify-demos.sh 08-atomics-and-the-memory-model 09-lock-free-data-structures
#
# Each demo's demo.sh builds its image, runs the container (whose CMD runs
# verify.lua), and propagates the container's exit code. We just record it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMOS_DIR="$ROOT/examples/concurrency"
RESULTS="${RESULTS:-$ROOT/.verify-transcripts}"
mkdir -p "$RESULTS"

if [ "$#" -gt 0 ]; then
  names=("$@")
else
  names=()
  for d in "$DEMOS_DIR"/*/; do names+=("$(basename "$d")"); done
fi

pass=(); fail=(); skip=()
for name in "${names[@]}"; do
  dir="$DEMOS_DIR/$name"
  if [ ! -x "$dir/demo.sh" ]; then
    echo "SKIP $name (no demo.sh)"; skip+=("$name"); continue
  fi
  echo "============================================================"
  echo "BUILD+VERIFY  $name"
  echo "============================================================"
  log="$RESULTS/$name.log"
  ( cd "$dir" && DEMO_NO_PAUSE=1 ./demo.sh ) >"$log" 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "PASS $name"; pass+=("$name")
  else
    echo "FAIL $name (rc=$rc) — see $log"; fail+=("$name")
    tail -20 "$log" | sed 's/^/    | /'
  fi
done

echo
echo "================= SUMMARY ================="
echo "PASS (${#pass[@]}): ${pass[*]:-none}"
echo "FAIL (${#fail[@]}): ${fail[*]:-none}"
echo "SKIP (${#skip[@]}): ${skip[*]:-none}"
[ "${#fail[@]}" -eq 0 ]
