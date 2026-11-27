#!/bin/bash
# Erzeugt die Logo-SVGs und die PNGs für Home Assistant (Ordner brand/ der Integration).
set -euo pipefail
cd "$(dirname "$0")"
OUT="../custom_components/kickbase/brand"
mkdir -p "$OUT"
python3 generate_logo.py
swift render.swift icon.svg      "$OUT/icon.png"          256 256
swift render.swift icon.svg      "$OUT/icon@2x.png"       512 512
swift render.swift logo.svg      "$OUT/logo.png"          0   128
swift render.swift logo.svg      "$OUT/logo@2x.png"       0   256
swift render.swift dark_logo.svg "$OUT/dark_logo.png"     0   128
swift render.swift dark_logo.svg "$OUT/dark_logo@2x.png"  0   256
echo "✔︎ Fertig: $OUT"
