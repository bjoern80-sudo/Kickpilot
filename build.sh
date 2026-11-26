#!/bin/bash
# Baut Kickbase.app aus dem Swift-Paket und legt sie in diesen Ordner.
set -euo pipefail
cd "$(dirname "$0")"

echo "▶︎ Kompiliere (Release) …"
swift build -c release

APP="Kickbase.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/KickbaseMac" "$APP/Contents/MacOS/Kickbase"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Kickbase</string>
    <key>CFBundleIdentifier</key><string>local.kickbase-mac</string>
    <key>CFBundleName</key><string>Kickbase</string>
    <key>CFBundleDisplayName</key><string>Kickbase</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.sports</string>
</dict>
</plist>
PLIST

# Lokale Ad-hoc-Signatur (nötig für den Schlüsselbund-Zugriff)
codesign --force --sign - "$APP"

echo "✅ Fertig: $(pwd)/$APP"
echo "   Starten mit: open \"$(pwd)/$APP\""
