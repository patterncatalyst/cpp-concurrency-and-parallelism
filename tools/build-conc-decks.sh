#!/usr/bin/env bash
# build-conc-decks.sh — build the cpp-concurrency-and-parallelism decks.
#
# Three decks share one engine (tools/build-pptx.py); each has its own entry
# script + sections module:
#   100  general mental model     build-conc-100-pptx.py / sections_conc_100.py
#   101  modern C++ toolkit       build-conc-101-pptx.py / sections_conc_101.py
#   201  low-latency deep dive    build-conc-201-pptx.py / sections_conc_201.py
#
# Usage:
#   ./tools/build-conc-decks.sh            # build all three
#   ./tools/build-conc-decks.sh 101        # build one
#   ./tools/build-conc-decks.sh all --force-diagrams
#
# Prerequisites: python3 + python-pptx + Pillow; soffice + pdftoppm (diagrams).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WHICH="${1:-all}"
FORCE_DIAGRAMS=""
[[ "${2:-}" == "--force-diagrams" ]] && FORCE_DIAGRAMS="--force"

for mod in pptx PIL; do
    python3 -c "import $mod" 2>/dev/null || {
        echo "  ERROR: python module '$mod' not installed" >&2
        echo "  Install: pip install python-pptx Pillow" >&2
        exit 1
    }
done

echo "==> Phase 1: SVG -> JPG conversion"
./tools/convert-diagrams.sh $FORCE_DIAGRAMS

build_one() {
    local id="$1"
    echo "==> Building deck $id"
    python3 "$ROOT/tools/build-conc-$id-pptx.py"
}

case "$WHICH" in
    100|101|201) build_one "$WHICH" ;;
    all) build_one 100; build_one 101; build_one 201 ;;
    *) echo "usage: $0 [100|101|201|all] [--force-diagrams]" >&2; exit 2 ;;
esac

echo
echo "==> Done. Decks in presentation/:"
ls -1 "$ROOT"/presentation/*.pptx 2>/dev/null | sed 's/^/    /' || true
echo
echo "Visual QA (per deck):"
echo "  soffice --headless --convert-to pdf --outdir /tmp presentation/<deck>.pptx"
echo "  pdftoppm -jpeg -r 100 /tmp/<deck>.pdf /tmp/qa-<deck>"
