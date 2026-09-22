#!/bin/bash
set -euo pipefail

uiSourceRoot="$(cd "$(dirname "$0")/.." && pwd)"
uiBuildDir="$(mktemp -d "${TMPDIR:-/tmp}/screenshot-renamer-ui-build.XXXXXX")"
trap 'rm -rf "$uiBuildDir"' EXIT

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -O \
  "$uiSourceRoot/Sources/ScreenshotRenamer/AppUI.swift" \
  "$uiSourceRoot/scripts/verify-ui.swift" \
  -o "$uiBuildDir/verify-ui"

"$uiBuildDir/verify-ui"
