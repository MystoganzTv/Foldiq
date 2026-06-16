#!/bin/sh
# Foldiq — build-number stamp.
#
# Runs as a late build phase. Its ONLY job is to stamp the built product's
# CFBundleVersion from the target-specific repo baseline. Xcode Cloud's
# CI_BUILD_NUMBER is allowed for iOS/iPadOS only; Mac stays frozen until an
# intentional Mac release.
#
# The marketing version (CFBundleShortVersionString) is NOT touched here — it
# comes from the target's MARKETING_VERSION build setting, which you control in
# Xcode (General → Version). Bump that when you ship a new version.
#
# The script intentionally does not edit version.config. Local builds should not
# dirty the worktree.

set -e

CONFIG="${SRCROOT}/version.config"
B=""
CONFIG_KEY="MAC_CURRENT_PROJECT_VERSION"
ALLOW_CI_BUILD_NUMBER="NO"

case "${PRODUCT_BUNDLE_IDENTIFIER:-}" in
  com.MystoganzTv.Foldiq.iOS)
    CONFIG_KEY="IOS_CURRENT_PROJECT_VERSION"
    ALLOW_CI_BUILD_NUMBER="YES"
    ;;
  *)
    CONFIG_KEY="MAC_CURRENT_PROJECT_VERSION"
    ;;
esac

if [ "$ALLOW_CI_BUILD_NUMBER" = "YES" ] && [ -n "${CI_BUILD_NUMBER:-}" ]; then
  B="${CI_BUILD_NUMBER}"
fi

if [ -z "$B" ] && [ -f "$CONFIG" ]; then
  B=$(grep "^${CONFIG_KEY}=" "$CONFIG" | cut -d= -f2 | tr -d ' "')
fi

if [ -z "$B" ]; then
  B="${CURRENT_PROJECT_VERSION:-1}"
fi

# Stamp the built product's Info.plist with the new build number.
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -f "$PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $B" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $B" "$PLIST"
else
  echo "warning: Info.plist not found at $PLIST — built app not stamped"
fi

echo "Foldiq build stamp → ${TARGET_NAME:-?} ${MARKETING_VERSION:-?} ($B)"
