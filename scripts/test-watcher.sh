#!/bin/bash
set -euo pipefail

watcherSourceRoot="$(cd "$(dirname "$0")/.." && pwd)"
watcherBuildDir="$(mktemp -d "${TMPDIR:-/tmp}/screenshot-renamer-watcher-build.XXXXXX")"
trap 'rm -rf "$watcherBuildDir"' EXIT

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -O \
  "$watcherSourceRoot/Sources/RenamerCore/CaptureLedger.swift" \
  "$watcherSourceRoot/Sources/RenamerCore/SafeFiles.swift" \
  "$watcherSourceRoot/Sources/RenamerCore/FileMutationAuthorization.swift" \
  "$watcherSourceRoot/Sources/ScreenshotRenamer/DirectoryWatcher.swift" \
  "$watcherSourceRoot/scripts/verify-watcher.swift" \
  -framework CoreServices -o "$watcherBuildDir/verify-watcher"

"$watcherBuildDir/verify-watcher"
