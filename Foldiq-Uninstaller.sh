#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  Foldiq Uninstaller
#  Removes Foldiq.app and all associated data from your Mac.
#  Run from Terminal:  bash Foldiq-Uninstaller.sh
# ─────────────────────────────────────────────────────────────

APP_NAME="Foldiq"
BUNDLE_ID="com.enrique.Foldiq"   # adjust if your bundle ID differs

echo ""
echo "╔══════════════════════════════════╗"
echo "║     Foldiq Uninstaller           ║"
echo "╚══════════════════════════════════╝"
echo ""
echo "This will remove Foldiq and all its data from your Mac."
echo ""
read -p "Are you sure you want to continue? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "🔍 Finding all Foldiq installations..."

REMOVED=0
ERRORS=0

# ── 1. Quit the app if running ─────────────────────────────────
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "  ⏹  Quitting $APP_NAME..."
    pkill -x "$APP_NAME" 2>/dev/null
    sleep 1
fi

# ── 2. Remove .app bundles (all locations) ─────────────────────
APP_PATHS=(
    "/Applications/${APP_NAME}.app"
    "$HOME/Applications/${APP_NAME}.app"
    "$HOME/Desktop/${APP_NAME}.app"
    "$HOME/Downloads/${APP_NAME}.app"
)

# Also search DerivedData
DERIVED=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "${APP_NAME}.app" -maxdepth 6 2>/dev/null)

for path in "${APP_PATHS[@]}"; do
    if [ -d "$path" ]; then
        echo "  🗑  Removing $path"
        rm -rf "$path" && REMOVED=$((REMOVED+1)) || ERRORS=$((ERRORS+1))
    fi
done

if [ -n "$DERIVED" ]; then
    echo "$DERIVED" | while IFS= read -r path; do
        echo "  🗑  Removing DerivedData copy: $path"
        rm -rf "$path" && REMOVED=$((REMOVED+1)) || ERRORS=$((ERRORS+1))
    done
fi

# ── 3. Preferences ────────────────────────────────────────────
PREF_FILES=(
    "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
    "$HOME/Library/Preferences/${BUNDLE_ID}.*.plist"
)
for f in "${PREF_FILES[@]}"; do
    for match in $f; do
        if [ -f "$match" ]; then
            echo "  🗑  Removing preference: $match"
            rm -f "$match" && REMOVED=$((REMOVED+1)) || ERRORS=$((ERRORS+1))
        fi
    done
done

# Also flush via defaults
defaults delete "$BUNDLE_ID" 2>/dev/null

# ── 4. Application Support ────────────────────────────────────
AS_DIR="$HOME/Library/Application Support/${APP_NAME}"
if [ -d "$AS_DIR" ]; then
    echo "  🗑  Removing Application Support: $AS_DIR"
    rm -rf "$AS_DIR" && REMOVED=$((REMOVED+1)) || ERRORS=$((ERRORS+1))
fi

# ── 5. Caches ─────────────────────────────────────────────────
CACHE_DIRS=(
    "$HOME/Library/Caches/${BUNDLE_ID}"
    "$HOME/Library/Caches/${APP_NAME}"
)
for d in "${CACHE_DIRS[@]}"; do
    if [ -d "$d" ]; then
        echo "  🗑  Removing cache: $d"
        rm -rf "$d" && REMOVED=$((REMOVED+1)) || ERRORS=$((ERRORS+1))
    fi
done

# ── 6. Saved Application State ───────────────────────────────
STATE="$HOME/Library/Saved Application State/${BUNDLE_ID}.savedState"
if [ -d "$STATE" ]; then
    echo "  🗑  Removing saved state: $STATE"
    rm -rf "$STATE" && REMOVED=$((REMOVED+1)) || ERRORS=$((ERRORS+1))
fi

# ── 7. Containers (sandboxed apps) ────────────────────────────
CONTAINER="$HOME/Library/Containers/${BUNDLE_ID}"
if [ -d "$CONTAINER" ]; then
    echo "  🗑  Removing sandbox container: $CONTAINER"
    rm -rf "$CONTAINER" && REMOVED=$((REMOVED+1)) || ERRORS=$((ERRORS+1))
fi

# ── 8. Group Containers ───────────────────────────────────────
for gc in "$HOME/Library/Group Containers/"*${APP_NAME}*; do
    if [ -d "$gc" ]; then
        echo "  🗑  Removing group container: $gc"
        rm -rf "$gc" && REMOVED=$((REMOVED+1)) || ERRORS=$((ERRORS+1))
    fi
done

# ── 9. Re-index Spotlight ─────────────────────────────────────
echo ""
echo "🔄 Flushing Spotlight index so ghost entries disappear..."
sudo mdutil -E / 2>/dev/null && echo "  ✓  Spotlight re-indexed" || echo "  ⚠  Spotlight re-index skipped (needs sudo)"

# ── Summary ──────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────"
if [ $ERRORS -eq 0 ]; then
    echo "✅  Foldiq uninstalled successfully."
else
    echo "⚠️  Finished with $ERRORS error(s). Some files may need manual removal."
fi
echo "   Items removed: $REMOVED"
echo "────────────────────────────────────"
echo ""
echo "You can safely delete this script."
echo ""
