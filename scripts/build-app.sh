#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

BUILD_DIRECTORY="${SCREENSHOT_RENAMER_BUILD_PATH:-${TMPDIR:-/tmp}/screenshot-renamer-build}"
BUILD_OPTIONS=(--scratch-path "$BUILD_DIRECTORY" --configuration release --arch arm64 --arch x86_64)
xcrun swift build "${BUILD_OPTIONS[@]}" --product ScreenshotRenamer
BINARY_DIRECTORY="$(xcrun swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
SPARKLE_DIRECTORY="$BUILD_DIRECTORY/artifacts/sparkle/Sparkle"
mkdir -p "$PROJECT_ROOT/dist"
STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/screenshot-renamer-bundle.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
BUNDLE_PATH="$STAGING_DIRECTORY/Screenshot Renamer.app"
mkdir -p "$BUNDLE_PATH/Contents/MacOS" "$BUNDLE_PATH/Contents/Resources" "$BUNDLE_PATH/Contents/Frameworks"
cp "$BINARY_DIRECTORY/ScreenshotRenamer" "$BUNDLE_PATH/Contents/MacOS/ScreenshotRenamer"
cp "$PROJECT_ROOT/packaging/Info.plist" "$BUNDLE_PATH/Contents/Info.plist"
/usr/bin/ditto "$SPARKLE_DIRECTORY/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$BUNDLE_PATH/Contents/Frameworks/Sparkle.framework"
cp "$SPARKLE_DIRECTORY/LICENSE" "$BUNDLE_PATH/Contents/Resources/Sparkle-LICENSE.txt"
cp "$PROJECT_ROOT/LICENSE" "$BUNDLE_PATH/Contents/Resources/LICENSE.txt"

# Identify the exact source revision separately from Sparkle's numeric build number.
SOURCE_REVISION="$(git rev-parse HEAD 2>/dev/null || printf 'source-archive')"
if [[ "$SOURCE_REVISION" != "source-archive" && -n "$(git status --porcelain --untracked-files=normal)" ]]; then SOURCE_REVISION="$SOURCE_REVISION-dirty"; fi
/usr/bin/plutil -insert ScreenshotRenamerRevision -string "$SOURCE_REVISION" "$BUNDLE_PATH/Contents/Info.plist"
# Overrides are useful for an isolated older-build updater smoke test.
if [[ -n "${SCREENSHOT_RENAMER_VERSION:-}" ]]; then
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$SCREENSHOT_RENAMER_VERSION" "$BUNDLE_PATH/Contents/Info.plist"
fi
if [[ -n "${SCREENSHOT_RENAMER_BUILD_NUMBER:-}" ]]; then
    /usr/bin/plutil -replace CFBundleVersion -string "$SCREENSHOT_RENAMER_BUILD_NUMBER" "$BUNDLE_PATH/Contents/Info.plist"
fi

xcrun swift "$PROJECT_ROOT/packaging/generate-icon.swift" "$STAGING_DIRECTORY/AppIcon.iconset"
/usr/bin/iconutil --convert icns --output "$BUNDLE_PATH/Contents/Resources/AppIcon.icns" "$STAGING_DIRECTORY/AppIcon.iconset"
/usr/bin/plutil -lint "$BUNDLE_PATH/Contents/Info.plist"
# Synced workspaces may attach Finder metadata, which codesign rejects in bundles.
# Remove only these two metadata attributes from this generated output.
/usr/bin/xattr -dr com.apple.FinderInfo "$BUNDLE_PATH" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$BUNDLE_PATH" 2>/dev/null || true
SIGN_OPTIONS=(--force --sign "${SCREENSHOT_RENAMER_SIGNING_IDENTITY:--}")
if [[ "${SCREENSHOT_RENAMER_SIGNING_IDENTITY:--}" == "-" ]]; then
    SIGN_OPTIONS+=(--timestamp=none)
else
    SIGN_OPTIONS+=(--options runtime --timestamp)
fi
# Sign nested executable code from the inside out; preserve framework symlinks.
FRAMEWORK="$BUNDLE_PATH/Contents/Frameworks/Sparkle.framework"
for COMPONENT in "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
                 "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
                 "$FRAMEWORK/Versions/B/Autoupdate" \
                 "$FRAMEWORK/Versions/B/Updater.app" "$FRAMEWORK" "$BUNDLE_PATH"; do
    if [[ "$COMPONENT" == */Downloader.xpc ]]; then
        /usr/bin/codesign "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$COMPONENT"
    else
        /usr/bin/codesign "${SIGN_OPTIONS[@]}" "$COMPONENT"
    fi
done
/usr/bin/codesign --verify --deep --strict "$BUNDLE_PATH"

OUTPUT_PATH="$PROJECT_ROOT/dist/Screenshot Renamer.zip"
# A ZIP prevents synced folders from adding metadata inside the signed app.
/usr/bin/ditto --noextattr --norsrc -c -k --keepParent "$BUNDLE_PATH" "$STAGING_DIRECTORY/Screenshot Renamer.zip"
mv -f "$STAGING_DIRECTORY/Screenshot Renamer.zip" "$OUTPUT_PATH"
if [[ -e "$PROJECT_ROOT/dist/Screenshot Renamer.app" ]]; then
    rm -rf "$PROJECT_ROOT/dist/Screenshot Renamer.app"
fi
printf 'Built: %s\n' "$OUTPUT_PATH"
printf 'Install with: %s/scripts/install.sh\n' "$PROJECT_ROOT"
