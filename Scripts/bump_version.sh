#!/bin/sh
# Foldiq — local build-number bump.
#
# Runs as the last build phase. Its ONLY job is to give LOCAL builds a unique,
# increasing build number (CFBundleVersion) so the in-app version label updates
# while developing.
#
# The marketing version (CFBundleShortVersionString) is NOT touched here — it
# comes from the target's MARKETING_VERSION build setting, which you control in
# Xcode (General → Version). Bump that when you ship a new version.
#
# In Xcode Cloud, this script does nothing: Xcode Cloud assigns the build number
# automatically and owns versioning for releases.

set -e

# --- Skip entirely in Xcode Cloud / CI ---------------------------------------
if [ -n "$CI" ] || [ -n "$CI_XCODE_CLOUD" ] || [ -n "$CI_BUILD_NUMBER" ]; then
  echo "Xcode Cloud / CI build detected — skipping local build-number bump."
  exit 0
fi

CONFIG="${SRCROOT}/version.config"
if [ ! -f "$CONFIG" ]; then
  echo "warning: version.config not found at $CONFIG — skipping build-number bump"
  exit 0
fi

B=$(grep '^CURRENT_PROJECT_VERSION' "$CONFIG" | cut -d= -f2 | tr -d ' "')
[ -z "$B" ] && B=0
B=$((B + 1))

# Persist the new local counter (preserve any comment lines above it).
TMP="$(mktemp)"
grep -v '^CURRENT_PROJECT_VERSION' "$CONFIG" > "$TMP" || true
printf 'CURRENT_PROJECT_VERSION=%s\n' "$B" >> "$TMP"
mv "$TMP" "$CONFIG"

# Stamp the built product's Info.plist with the new build number.
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -f "$PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $B" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $B" "$PLIST"
else
  echo "warning: Info.plist not found at $PLIST — built app not stamped"
fi

echo "Local build → ${MARKETING_VERSION:-?} ($B)"
