#!/usr/bin/env bash
# convert-diagrams.sh — rasterize diagrams/*.svg to /tmp/diagrams-png/*.jpg for
# the decks. The deck engine (tools/build-pptx.py) embeds the JPGs, not the SVGs,
# because python-pptx cannot place SVG directly.
#
# SVG → PDF (LibreOffice draw export) → JPG (poppler pdftoppm @160dpi). Cached:
# an SVG is reconverted only when its JPG is missing or older than the source.
#
# Usage:
#   ./tools/convert-diagrams.sh           # incremental
#   ./tools/convert-diagrams.sh --force   # re-convert all
#
# Prerequisites: soffice (LibreOffice), pdftoppm (poppler-utils).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/diagrams"
OUT="/tmp/diagrams-png"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

for tool in soffice pdftoppm; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "  ERROR: '$tool' not found on PATH" >&2
        echo "  Install: dnf install libreoffice-draw poppler-utils (Fedora)" >&2
        exit 1
    }
done

mkdir -p "$OUT"
converted=0; skipped=0
shopt -s nullglob
for svg in "$SRC"/*.svg; do
    name="$(basename "$svg" .svg)"
    jpg="$OUT/$name.jpg"
    if [[ $FORCE -eq 0 && -f "$jpg" && "$jpg" -nt "$svg" ]]; then
        skipped=$((skipped + 1)); continue
    fi
    cp "$svg" "$OUT/"
    soffice --headless --convert-to pdf:"draw_pdf_Export" \
            --outdir "$OUT/" "$OUT/$name.svg" >/dev/null 2>&1
    pdftoppm -jpeg -r 160 -singlefile "$OUT/$name.pdf" "$OUT/$name" >/dev/null 2>&1
    rm -f "$OUT/$name.svg" "$OUT/$name.pdf"
    converted=$((converted + 1))
done
echo "    diagrams: $converted converted, $skipped reused from cache -> $OUT"
