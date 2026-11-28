#!/bin/bash
# Erzeugt branding/AppIcon.icns (Icon der Mac-App) aus icon.svg. Nur nach Logo-Änderungen nötig.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
swift make_appicon.swift icon.svg "$TMP/1024.png"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$TMP/1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$TMP"
echo "✔︎ Fertig: branding/AppIcon.icns"
