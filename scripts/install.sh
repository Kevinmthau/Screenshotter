#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ARCHIVE="$PROJECT_ROOT/dist/Screenshot Renamer.zip"
APPLICATIONS_DIRECTORY="${1:-$HOME/Applications}"
if [[ ! -f "$SOURCE_ARCHIVE" ]]; then
    printf 'Build the app first: %s/scripts/build-app.sh\n' "$PROJECT_ROOT" >&2
    exit 1
fi
mkdir -p "$APPLICATIONS_DIRECTORY"
APPLICATIONS_DIRECTORY="$(cd "$APPLICATIONS_DIRECTORY" && pwd)"
DESTINATION_APP="$APPLICATIONS_DIRECTORY/Screenshot Renamer.app"
STAGING_DIRECTORY="$(mktemp -d "$APPLICATIONS_DIRECTORY/.screenshot-renamer-install.XXXXXX")"
BACKUP_APP="$STAGING_DIRECTORY/Previous Screenshot Renamer.app"
cleanup() {
    if [[ -e "$BACKUP_APP" && ! -e "$DESTINATION_APP" ]]; then
        mv "$BACKUP_APP" "$DESTINATION_APP"
    fi
    rm -rf "$STAGING_DIRECTORY"
}
trap cleanup EXIT
/usr/bin/ditto -x -k "$SOURCE_ARCHIVE" "$STAGING_DIRECTORY"
/usr/bin/xattr -dr com.apple.FinderInfo "$STAGING_DIRECTORY/Screenshot Renamer.app" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$STAGING_DIRECTORY/Screenshot Renamer.app" 2>/dev/null || true
/usr/bin/codesign --verify --strict "$STAGING_DIRECTORY/Screenshot Renamer.app"
if [[ -e "$DESTINATION_APP" ]]; then
    mv "$DESTINATION_APP" "$BACKUP_APP"
fi
mv "$STAGING_DIRECTORY/Screenshot Renamer.app" "$DESTINATION_APP"
printf 'Installed: %s\n' "$DESTINATION_APP"
/usr/bin/open "$DESTINATION_APP"
printf 'Started Screenshot Renamer. Allow Desktop access if macOS asks.\n'
