#!/bin/bash
set -euo pipefail

startupSourceRoot="$(cd "$(dirname "$0")/.." && pwd)"
startupBuildDir="$(mktemp -d "${TMPDIR:-/tmp}/screenshot-renamer-startup-build.XXXXXX")"
trap 'rm -rf "$startupBuildDir"' EXIT
startupPackageDir="${SCREENSHOT_RENAMER_BUILD_PATH:-$startupBuildDir/package}"

/usr/bin/xcrun swift build --package-path "$startupSourceRoot" \
  --scratch-path "$startupPackageDir" --configuration release --target RenamerCore
startupBinDir="$(/usr/bin/xcrun swift build --package-path "$startupSourceRoot" \
  --scratch-path "$startupPackageDir" --configuration release --show-bin-path)"
startupSparkleDir="$startupPackageDir/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
if [[ -d "$startupBinDir/Modules" ]]; then
  startupModuleDir="$startupBinDir/Modules"
  startupCoreObjects=("$startupBinDir"/RenamerCore.build/*.o)
else
  # SwiftPM's Xcode build engine places the module and merged object beside products.
  startupModuleDir="$startupBinDir"
  startupCoreObjects=("$startupBinDir/RenamerCore.o")
fi

/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -O \
  -I "$startupModuleDir" "${startupCoreObjects[@]}" \
  -F "$startupSparkleDir" \
  "$startupSourceRoot/Sources/ScreenshotRenamer/AppController.swift" \
  "$startupSourceRoot/Sources/ScreenshotRenamer/AppUI.swift" \
  "$startupSourceRoot/Sources/ScreenshotRenamer/AppUpdater.swift" \
  "$startupSourceRoot/Sources/ScreenshotRenamer/DirectoryWatcher.swift" \
  "$startupSourceRoot/scripts/verify-startup.swift" \
  -framework CoreServices -framework ServiceManagement -framework Sparkle \
  -Xlinker -rpath -Xlinker "$startupSparkleDir" -o "$startupBuildDir/verify-startup"

"$startupBuildDir/verify-startup"
