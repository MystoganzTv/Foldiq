#!/bin/bash
# build-dmg.sh — Package Foldiq.app as a professional styled DMG
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
FINAL_DMG="$HOME/Desktop/$DMG_NAME"
BACKGROUND_SRC="$(dirname "$0")/build/dmg-background.png"

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

# ── 3. Build background image (if not already built) ─────────────────────
if [ ! -f "$BACKGROUND_SRC" ]; then
  echo "==> Generating DMG background…"
  mkdir -p "$(dirname "$0")/build"
  python3 - << 'PYEOF'
from PIL import Image, ImageDraw, ImageFont
import math, os

W, H = 660, 400
img = Image.new("RGB", (W, H), (255, 255, 255))
draw = ImageDraw.Draw(img)

# Subtle blue-white vertical gradient
for y in range(H):
    t = y / H
    r = int(238 + (255 - 238) * t)
    g = int(244 + (255 - 244) * t)
    b = 255
    draw.line([(0, y), (W, y)], fill=(r, g, b))

# Horizontal arrow center
arrow_x1, arrow_x2, arrow_y = 275, 382, H // 2
draw.line([(arrow_x1, arrow_y), (arrow_x2 - 12, arrow_y)], fill=(160, 175, 210), width=3)
draw.polygon([
    (arrow_x2, arrow_y),
    (arrow_x2 - 14, arrow_y - 9),
    (arrow_x2 - 14, arrow_y + 9),
], fill=(160, 175, 210))

# Bottom label
try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 14)
except:
    font = ImageFont.load_default()

text = "Drag Foldiq to your Applications folder"
bbox = draw.textbbox((0, 0), text, font=font)
tw = bbox[2] - bbox[0]
draw.text(((W - tw) // 2, H - 44), text, fill=(120, 135, 165), font=font)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)) if '__file__' in dir() else '.', 'build/dmg-background.png')
# Write relative to script dir — use env var passed in
out = os.environ.get('BG_OUT', 'build/dmg-background.png')
img.save(out, "PNG")
print(f"Background: {out}")
PYEOF
fi

# ── 4. Create writable staging DMG → style it → convert to final ─────────
echo "==> Creating styled DMG…"

STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Copy background into hidden folder inside staging
mkdir -p "$STAGING/.background"
if [ -f "$BACKGROUND_SRC" ]; then
  cp "$BACKGROUND_SRC" "$STAGING/.background/background.png"
fi

# Create a writable temp DMG first (so we can run AppleScript on it)
TMP_DMG="/tmp/Foldiq_rw.dmg"
rm -f "$TMP_DMG"

hdiutil create \
  -volname "Foldiq" \
  -srcfolder "$STAGING" \
  -ov \
  -format UDRW \
  -size 300m \
  "$TMP_DMG"

rm -rf "$STAGING"

# Mount the writable DMG
MOUNT_OUT=$(hdiutil attach -readwrite -noverify "$TMP_DMG" | grep "Foldiq")
VOLUME=$(echo "$MOUNT_OUT" | awk '{print $NF}')

if [ -z "$VOLUME" ]; then
  echo "❌ Could not mount DMG"
  exit 1
fi

echo "  Mounted at: $VOLUME"
sleep 1

# Style the DMG window using AppleScript
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

# Sync and unmount
sync
hdiutil detach "$VOLUME" -quiet

# ── 5. Convert to compressed final DMG ────────────────────────────────────
echo "==> Compressing final DMG…"
rm -f "$FINAL_DMG"
hdiutil convert "$TMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$FINAL_DMG"

rm -f "$TMP_DMG"

echo ""
echo "✅  DMG ready: $FINAL_DMG"
echo "    Size: $(du -sh "$FINAL_DMG" | cut -f1)"
echo ""
echo "Next steps:"
echo "  1. Upload $DMG_NAME to GitHub Releases"
echo "  2. Done — download link in web/success.html already points to GitHub Releases"
