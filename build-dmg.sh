#!/bin/bash
# build-dmg.sh — Package Foldiq.app as a DMG for direct download
# Run from the project root:
#   chmod +x build-dmg.sh && ./build-dmg.sh

set -e

PROJECT="Foldiq.xcodeproj"
SCHEME="Foldiq"
LOCAL_ARCHIVE="build/Foldiq.xcarchive"
ARCHIVE_PATH="/tmp/Foldiq.xcarchive"
EXPORT_DIR="/tmp/FoldiqExport"
VERSION="1.0"
DMG_NAME="Foldiq-${VERSION}.dmg"
OUTPUT="$HOME/Desktop/$DMG_NAME"

# ── 1. Archive (skip if build/Foldiq.xcarchive already exists) ─────────────
if [ -d "$LOCAL_ARCHIVE" ]; then
  echo "==> Using existing archive: $LOCAL_ARCHIVE"
  ARCHIVE_PATH="$LOCAL_ARCHIVE"
else
  echo "==> Building archive…"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    | grep -E "error:|warning:|Build succeeded|FAILED"
fi

# ── 2. Export .app ────────────────────────────────────────────────────────
echo "==> Exporting .app…"
rm -rf "$EXPORT_DIR"

cat > /tmp/ExportOptions.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist /tmp/ExportOptions.plist \
  | grep -E "error:|Export succeeded|FAILED" || true

APP="$EXPORT_DIR/Foldiq.app"

# Fallback: grab .app directly from archive if export left it there
if [ ! -d "$APP" ]; then
  APP=$(find "$ARCHIVE_PATH/Products" -name "Foldiq.app" | head -1)
  echo "  (using .app from archive: $APP)"
fi

if [ ! -d "$APP" ]; then
  echo "❌ Could not find Foldiq.app. Check signing settings."
  exit 1
fi

# ── 3. Create DMG ─────────────────────────────────────────────────────────
echo "==> Creating DMG…"
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "Foldiq" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$OUTPUT"

rm -rf "$STAGING"

echo ""
echo "✅  DMG ready: $OUTPUT"
echo "    Size: $(du -sh "$OUTPUT" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Upload $DMG_NAME to GitHub Releases, your server, or any CDN"
echo "  2. Update the download link in web/success.html"
