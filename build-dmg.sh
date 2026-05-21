#!/bin/bash
# build-dmg.sh — Build Foldiq.app and package it as a DMG
# Run this from your Mac Terminal inside the project folder:
#   chmod +x build-dmg.sh && ./build-dmg.sh

set -e

PROJECT="Foldiq.xcodeproj"
SCHEME="Foldiq"
ARCHIVE="/tmp/Foldiq.xcarchive"
EXPORT_DIR="/tmp/FoldiqExport"
DMG_NAME="Foldiq-1.0.dmg"
OUTPUT="$HOME/Desktop/$DMG_NAME"

echo "==> Building archive…"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  archive \
  | grep -E "error:|warning:|Build succeeded|FAILED"

echo "==> Exporting .app…"
# Create a minimal export options plist (development signing for local use)
cat > /tmp/ExportOptions.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>development</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
EOF

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist /tmp/ExportOptions.plist \
  | grep -E "error:|Export succeeded|FAILED"

APP="$EXPORT_DIR/Foldiq.app"

echo "==> Creating DMG…"
# Create a temp folder for the DMG layout
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

hdiutil create \
  -volname "Foldiq" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDZO \
  "$OUTPUT"

rm -rf "$STAGING"

echo ""
echo "✅ Done! DMG saved to: $OUTPUT"
echo "   Drag Foldiq.app into Applications to install."
