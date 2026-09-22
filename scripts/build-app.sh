#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

BUILD_DIRECTORY="${SCREENSHOT_RENAMER_BUILD_PATH:-${TMPDIR:-/tmp}/screenshot-renamer-build}"
xcrun swift build --scratch-path "$BUILD_DIRECTORY" --configuration release --product ScreenshotRenamer
BINARY_DIRECTORY="$(xcrun swift build --scratch-path "$BUILD_DIRECTORY" --configuration release --show-bin-path)"
mkdir -p "$PROJECT_ROOT/dist"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/screenshot-renamer-bundle.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
BUNDLE_PATH="$STAGING_DIRECTORY/Screenshot Renamer.app"
mkdir -p "$BUNDLE_PATH/Contents/MacOS" "$BUNDLE_PATH/Contents/Resources"
cp "$BINARY_DIRECTORY/ScreenshotRenamer" "$BUNDLE_PATH/Contents/MacOS/ScreenshotRenamer"
cp "$PROJECT_ROOT/packaging/Info.plist" "$BUNDLE_PATH/Contents/Info.plist"

xcrun swift "$PROJECT_ROOT/packaging/generate-icon.swift" "$STAGING_DIRECTORY/AppIcon.iconset"
/usr/bin/iconutil --convert icns --output "$BUNDLE_PATH/Contents/Resources/AppIcon.icns" "$STAGING_DIRECTORY/AppIcon.iconset"
/usr/bin/plutil -lint "$BUNDLE_PATH/Contents/Info.plist"
# Synced workspaces may attach Finder metadata, which codesign rejects in bundles.
# Remove only these two metadata attributes from this generated output.
/usr/bin/xattr -dr com.apple.FinderInfo "$BUNDLE_PATH" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$BUNDLE_PATH" 2>/dev/null || true
/usr/bin/codesign --force --sign - --timestamp=none "$BUNDLE_PATH"
/usr/bin/codesign --verify --strict "$BUNDLE_PATH"

OUTPUT_PATH="$PROJECT_ROOT/dist/Screenshot Renamer.zip"
# A ZIP prevents synced folders from adding metadata inside the signed app.
/usr/bin/ditto --noextattr --norsrc -c -k --keepParent "$BUNDLE_PATH" "$STAGING_DIRECTORY/Screenshot Renamer.zip"
mv -f "$STAGING_DIRECTORY/Screenshot Renamer.zip" "$OUTPUT_PATH"
if [[ -e "$PROJECT_ROOT/dist/Screenshot Renamer.app" ]]; then
    rm -rf "$PROJECT_ROOT/dist/Screenshot Renamer.app"
fi
printf 'Built: %s\n' "$OUTPUT_PATH"
printf 'Install with: %s/scripts/install.sh\n' "$PROJECT_ROOT"
