#!/bin/bash
# notarize.sh — Sign, notarize, and staple Foldiq for direct distribution
# Run from the project root: bash notarize.sh
#
# Prerequisites:
#   • Developer ID Application certificate in Keychain
#   • App-Specific Password stored via:
#     xcrun notarytool store-credentials "FoldiqNotarization" \
#       --apple-id "enrique.padron853@gmail.com" \
#       --team-id "V6F97AK8AD" \
#       --password "xxxx-xxxx-xxxx-xxxx"

set -e

# ── Config ────────────────────────────────────────────────────────────────────
APPLE_ID="enrique.padron853@gmail.com"
TEAM_ID="V6F97AK8AD"
SIGN_IDENTITY="Developer ID Application: Enrique Padron spaangberg (V6F97AK8AD)"
KEYCHAIN_PROFILE="FoldiqNotarization"
VERSION="1.0"
DMG_NAME="Foldiq-${VERSION}.dmg"
FINAL_DMG="$HOME/Desktop/$DMG_NAME"
LOCAL_ARCHIVE="build/Foldiq.xcarchive"
EXPORT_DIR="/tmp/FoldiqExport"
BACKGROUND_SRC="$(dirname "$0")/build/dmg-background.png"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║        Foldiq — Sign & Notarize              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Step 1: Store credentials (only needed once) ──────────────────────────────
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
  echo "==> Storing notarization credentials in Keychain…"
  xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" \
    --apple-id "$APPLE_ID" \
    --team-id "$TEAM_ID"
  echo "  ✓ Credentials stored"
else
  echo "==> Credentials already stored ✓"
fi

# ── Step 2: Export .app from archive ─────────────────────────────────────────
if [ ! -d "$LOCAL_ARCHIVE" ]; then
  echo "❌ No archive found at $LOCAL_ARCHIVE"
  echo "   Run build-dmg.sh first to create the archive."
  exit 1
fi

echo "==> Exporting .app from archive…"
rm -rf "$EXPORT_DIR"

cat > /tmp/ExportOptions.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>V6F97AK8AD</string>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$LOCAL_ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist /tmp/ExportOptions.plist \
  | grep -E "error:|Export succeeded|FAILED" || true

APP="$EXPORT_DIR/Foldiq.app"

# Fallback: grab from archive Products
if [ ! -d "$APP" ]; then
  APP=$(find "$LOCAL_ARCHIVE/Products" -name "Foldiq.app" | head -1)
  echo "  (using .app from archive: $APP)"
fi

if [ ! -d "$APP" ]; then
  echo "❌ Could not find Foldiq.app"
  exit 1
fi

# ── Step 3: Deep-sign the .app ────────────────────────────────────────────────
echo "==> Signing .app with Developer ID…"

# Sign all nested binaries/frameworks first, then the main bundle
find "$APP" -name "*.dylib" -o -name "*.framework" | while read f; do
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$f" 2>/dev/null || true
done

codesign \
  --force \
  --deep \
  --sign "$SIGN_IDENTITY" \
  --timestamp \
  --options runtime \
  --entitlements "Foldiq/Foldiq.entitlements" \
  "$APP"

echo "  Verifying signature…"
codesign --verify --deep --strict "$APP" && echo "  ✓ Signature valid"

# ── Step 4: Create DMG ────────────────────────────────────────────────────────
echo "==> Creating DMG…"
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

mkdir -p "$STAGING/.background"
[ -f "$BACKGROUND_SRC" ] && cp "$BACKGROUND_SRC" "$STAGING/.background/background.png"

TMP_DMG="/tmp/Foldiq_rw.dmg"
rm -f "$TMP_DMG"

hdiutil create \
  -volname "Foldiq" \
  -srcfolder "$STAGING" \
  -ov -format UDRW -size 300m \
  "$TMP_DMG"

rm -rf "$STAGING"

MOUNT_OUT=$(hdiutil attach -readwrite -noverify "$TMP_DMG" | grep "Foldiq")
VOLUME=$(echo "$MOUNT_OUT" | awk '{print $NF}')
sleep 1

osascript << APPLESCRIPT
tell application "Finder"
  tell disk "Foldiq"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {100, 100, 760, 500}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 14
    set background picture of viewOptions to file ".background:background.png"
    set position of item "Foldiq.app" of container window to {155, 185}
    set position of item "Applications" of container window to {505, 185}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$VOLUME" -quiet

rm -f "$FINAL_DMG"
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG"
rm -f "$TMP_DMG"

# ── Step 5: Sign the DMG ──────────────────────────────────────────────────────
echo "==> Signing DMG…"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$FINAL_DMG"
echo "  ✓ DMG signed"

# ── Step 6: Notarize ──────────────────────────────────────────────────────────
echo "==> Submitting to Apple for notarization (this takes 1-5 min)…"
xcrun notarytool submit "$FINAL_DMG" \
  --keychain-profile "$KEYCHAIN_PROFILE" \
  --wait \
  --timeout 10m

# ── Step 7: Staple ────────────────────────────────────────────────────────────
echo "==> Stapling notarization ticket…"
xcrun stapler staple "$FINAL_DMG"

echo ""
echo "✅  Done! Notarized DMG ready: $FINAL_DMG"
echo "    Size: $(du -sh "$FINAL_DMG" | cut -f1)"
echo ""
echo "Next: upload to GitHub Releases and replace the existing Foldiq-1.0.dmg"
