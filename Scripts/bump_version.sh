#!/bin/sh
# Foldiq — auto version & build bump.
# Runs as the last build phase. Increments the patch of MARKETING_VERSION and
# the CURRENT_PROJECT_VERSION on every build, persists them to version.config
# (the single source of truth), and writes them into the built app's Info.plist.

set -e

CONFIG="${SRCROOT}/version.config"
if [ ! -f "$CONFIG" ]; then
  echo "warning: version.config not found at $CONFIG — skipping version bump"
  exit 0
fi

M=$(grep '^MARKETING_VERSION'      "$CONFIG" | cut -d= -f2 | tr -d ' "')
B=$(grep '^CURRENT_PROJECT_VERSION' "$CONFIG" | cut -d= -f2 | tr -d ' "')

MAJ=$(echo "$M" | cut -d. -f1)
MIN=$(echo "$M" | cut -d. -f2)
PAT=$(echo "$M" | cut -d. -f3)
[ -z "$MAJ" ] && MAJ=1
[ -z "$MIN" ] && MIN=0
[ -z "$PAT" ] && PAT=0
[ -z "$B" ]   && B=0

PAT=$((PAT + 1))
B=$((B + 1))
NEW_MARKETING="${MAJ}.${MIN}.${PAT}"

# Persist new values for next build.
printf 'MARKETING_VERSION=%s\nCURRENT_PROJECT_VERSION=%s\n' "$NEW_MARKETING" "$B" > "$CONFIG"

# Stamp the built product's Info.plist so this build reflects the new values.
PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
if [ -f "$PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_MARKETING" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $NEW_MARKETING" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $B" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $B" "$PLIST"
else
  echo "warning: Info.plist not found at $PLIST — built app not stamped"
fi

echo "Foldiq version → ${NEW_MARKETING} (${B})"
