#!/bin/bash
# notarize.sh — Build the Foldiq.dmg sold on foldiq.app: signed with Developer ID
# and notarized by Apple, so Gatekeeper opens it without warnings.
#
# Run from the project root on your Mac:   bash notarize.sh
# To reuse the archive from the previous run: bash notarize.sh --skip-archive
#
# Needs, once:
#   • A "Developer ID Application" certificate in your keychain
#     (Xcode → Settings → Accounts → your team → Manage Certificates → + )
#   • Notarization credentials; the script asks for an app-specific password
#     (appleid.apple.com → Sign-In and Security → App-Specific Passwords) the
#     first time and keeps it in the keychain.
#
# Every step stops the script if it fails. It never ships an unsigned app:
# that is what made macOS call the old Foldiq.dmg "damaged".

set -euo pipefail

APPLE_ID="enrique.padron853@gmail.com"
TEAM_ID="V6F97AK8AD"
KEYCHAIN_PROFILE="FoldiqNotarization"
OUT_DIR="build/Mac Download"
ARCHIVE="$OUT_DIR/Foldiq.xcarchive"
EXPORT_DIR="$OUT_DIR/Export"
FINAL_DMG="$OUT_DIR/Foldiq.dmg"
BACKGROUND_SRC="build/dmg-background.png"

echo ""
echo "Foldiq — build the notarized Mac download"
echo ""

# ── 1. Certificate ────────────────────────────────────────────────────────────
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  echo "❌ No 'Developer ID Application' certificate in your keychain."
  echo "   Xcode → Settings → Accounts → your team → Manage Certificates → + → Developer ID Application"
  exit 1
fi
echo "==> Developer ID certificate found ✓"

# ── 2. Notarization credentials (asked once) ─────────────────────────────────
if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" &>/dev/null; then
  echo "==> Saving notarization credentials in your keychain (asks for an app-specific password)…"
  xcrun notarytool store-credentials "$KEYCHAIN_PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID"
fi
echo "==> Notarization credentials ready ✓"

# ── 3. Fresh archive of the current code ─────────────────────────────────────
if [ "${1:-}" = "--skip-archive" ] && [ -d "$ARCHIVE" ]; then
  echo "==> Reusing the archive from the previous run ✓"
  rm -rf "$EXPORT_DIR" "$FINAL_DMG"
else
  rm -rf "$OUT_DIR"
  mkdir -p "$OUT_DIR"
  echo "==> Archiving the current code (a few minutes)…"
  xcodebuild -project Foldiq.xcodeproj -scheme Foldiq -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" archive -quiet
fi

# ── 4. Export signed with Developer ID ───────────────────────────────────────
echo "==> Exporting with Developer ID…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist distribution/ExportOptions-DeveloperID.plist -quiet
APP="$EXPORT_DIR/Foldiq.app"
[ -d "$APP" ] || { echo "❌ Export did not produce Foldiq.app"; exit 1; }
codesign --verify --deep --strict "$APP"
# -dvv lists the signing authority (plain -dv does not).
SIGNATURE=$(codesign -dvv "$APP" 2>&1)
if ! echo "$SIGNATURE" | grep -q "Authority=Developer ID Application"; then
  echo "❌ Foldiq.app is not signed with Developer ID:"
  echo "$SIGNATURE" | grep -E "Authority|TeamIdentifier" || echo "$SIGNATURE"
  exit 1
fi
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "==> Foldiq $VERSION signed with Developer ID ✓"

# ── 5. Disk image ────────────────────────────────────────────────────────────
echo "==> Creating Foldiq.dmg…"
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
if [ -f "$BACKGROUND_SRC" ]; then
  mkdir -p "$STAGING/.background"
  cp "$BACKGROUND_SRC" "$STAGING/.background/background.png"
fi
hdiutil create -volname "Foldiq" -srcfolder "$STAGING" -ov -format UDZO -imagekey zlib-level=9 "$FINAL_DMG" -quiet
rm -rf "$STAGING"
codesign --force --sign "Developer ID Application" --timestamp "$FINAL_DMG"

# ── 6. Notarize and staple ───────────────────────────────────────────────────
echo "==> Sending to Apple for notarization (usually 1–5 minutes)…"
RESULT=$(xcrun notarytool submit "$FINAL_DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait --timeout 20m --output-format plist)
STATUS=$(echo "$RESULT" | plutil -extract status raw -o - - 2>/dev/null || echo "Unknown")
if [ "$STATUS" != "Accepted" ]; then
  echo "❌ Notarization status: $STATUS"
  SUBMISSION=$(echo "$RESULT" | plutil -extract id raw -o - - 2>/dev/null || true)
  [ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$KEYCHAIN_PROFILE"
  exit 1
fi
xcrun stapler staple "$FINAL_DMG"
xcrun stapler validate "$FINAL_DMG"
spctl --assess --type open --context context:primary-signature -v "$FINAL_DMG"

echo ""
echo "✅ Notarized download ready: $FINAL_DMG (Foldiq $VERSION, $(du -sh "$FINAL_DMG" | cut -f1))"
echo ""
echo "Next:"
echo "  1. Add it to the latest GitHub release as 'Foldiq.dmg' (same release as Foldiq-Setup.exe)."
echo "  2. Set \"version\": \"$VERSION\" in web/mac-version.json and deploy, so earlier web copies see the update."
