#!/bin/bash
# Baut Kickpilot.app aus dem Swift-Paket und legt sie in diesen Ordner.
set -euo pipefail
cd "$(dirname "$0")"

echo "▶︎ Kompiliere (Release) …"
swift build -c release

APP="Kickpilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/KickbaseMac" "$APP/Contents/MacOS/Kickpilot"
cp "branding/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "custom_components/kickbase/brand/icon@2x.png" "$APP/Contents/Resources/Emblem.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Kickpilot</string>
    <key>CFBundleIdentifier</key><string>local.kickbase-mac</string>   <!-- bleibt gleich: Einstellungen + Schlüsselbund -->
    <key>CFBundleName</key><string>Kickpilot</string>
    <key>CFBundleDisplayName</key><string>Kickpilot</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.sports</string>
</dict>
</plist>
PLIST

# Signatur: bevorzugt mit eigenem Zertifikat „Kickbase Local Signing“
# (Schlüsselbundverwaltung → Zertifikatsassistent → Zertifikat erstellen,
# Typ „Codesignatur“). Damit bleibt die App-Identität über Builds hinweg gleich
# und „Immer erlauben“ beim Schlüsselbund-Zugriff gilt dauerhaft.
# Ohne Zertifikat: Ad-hoc-Signatur (macOS fragt dann nach jedem Build erneut).
SIGN_ID="Kickbase Local Signing"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
    echo "▶︎ Signiere mit „${SIGN_ID}“ …"
    codesign --force --sign "$SIGN_ID" "$APP"
else
    echo "⚠︎ Zertifikat „${SIGN_ID}“ nicht gefunden – Ad-hoc-Signatur."
    codesign --force --sign - "$APP"
fi

echo "✅ Fertig: $(pwd)/$APP"
echo "   Starten mit: open \"$(pwd)/$APP\""
