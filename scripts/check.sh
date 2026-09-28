#!/bin/bash
set -euo pipefail

checkSourceRoot="$(cd "$(dirname "$0")/.." && pwd)"
cd "$checkSourceRoot"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'Screenshot Renamer checks require macOS and Xcode.\n' >&2
    exit 1
fi

# XCTest needs full Xcode on Macs whose active selection is Command Line Tools.
# This changes only this process and its children, never the global selection.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == */CommandLineTools && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

export SCREENSHOT_RENAMER_BUILD_PATH="${SCREENSHOT_RENAMER_BUILD_PATH:-${TMPDIR:-/tmp}/screenshot-renamer-checks}"
export SCREENSHOT_RENAMER_LIVE_TESTS="${SCREENSHOT_RENAMER_LIVE_TESTS:-0}"

printf 'Running unit tests…\n'
xcrun swift test --scratch-path "$SCREENSHOT_RENAMER_BUILD_PATH"
printf 'Running filesystem watcher checks…\n'
"$checkSourceRoot/scripts/test-watcher.sh"
printf 'Running AppKit UI checks…\n'
"$checkSourceRoot/scripts/test-ui.sh"
printf 'Building and verifying the app bundle…\n'
"$checkSourceRoot/scripts/build-app.sh"
printf 'All checks passed. The app has not been installed or launched.\n'
