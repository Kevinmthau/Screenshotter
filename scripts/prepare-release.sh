#!/bin/bash
set -euo pipefail

releaseRoot="$(cd "$(dirname "$0")/.." && pwd)"
cd "$releaseRoot"
fail() { printf 'Release preparation stopped: %s\n' "$*" >&2; exit 1; }
if [[ $# -ne 1 || "$1" == --help ]]; then
    printf 'Usage: %s NOTES.md\nBuild and sign local release assets without publishing. Store notes outside the repo or in ignored dist/.\n' "$0"
    [[ $# -eq 1 && "$1" == --help ]] && exit 0
    exit 1
fi
[[ "$(uname -s)" == Darwin ]] || fail 'macOS is required.'
[[ -f "$1" && -s "$1" ]] || fail 'A nonempty release-notes file is required.'
releaseNotes="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -z "${SCREENSHOT_RENAMER_VERSION+x}" && -z "${SCREENSHOT_RENAMER_BUILD_NUMBER+x}" ]] || fail 'Version/build overrides are forbidden; commit packaging/Info.plist instead.'
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Commit all source changes and remove untracked source files first.'
releaseRevision="$(git rev-parse HEAD)"
releaseVersion="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"
releaseBuild="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' packaging/Info.plist)"
[[ "$releaseVersion" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || fail 'Use a numeric major.minor.patch version without leading zeroes.'
[[ "$releaseBuild" =~ ^[1-9][0-9]{0,8}$ ]] || fail 'Use a positive integer build number without leading zeroes.'
releaseDirectory="$releaseRoot/dist/releases/v$releaseVersion"
[[ ! -e "$releaseDirectory" ]] || fail 'This version already has prepared assets; inspect them or move that directory aside before rebuilding.'

export SCREENSHOT_RENAMER_BUILD_PATH="${SCREENSHOT_RENAMER_BUILD_PATH:-${TMPDIR:-/tmp}/screenshot-renamer-build}"
"$releaseRoot/scripts/check.sh"
[[ "$(git rev-parse HEAD)" == "$releaseRevision" && -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Source changed during validation; start again from a clean revision.'
releaseTools="$SCREENSHOT_RENAMER_BUILD_PATH/artifacts/sparkle/Sparkle/bin"
releaseAccount=com.kevinthau.screenshot-renamer
releasePublicKey="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' packaging/Info.plist)"
[[ "$("$releaseTools/generate_keys" --account "$releaseAccount" -p)" == "$releasePublicKey" ]] || fail 'The Keychain signing key does not match the public key committed in Info.plist.'

mkdir -p "$releaseRoot/dist/releases"
releaseStage="$(mktemp -d "$releaseRoot/dist/releases/.prepare.XXXXXX")"
trap 'rm -rf "$releaseStage"' EXIT
releaseArchive="Screenshot-Renamer-$releaseVersion.zip"
cp "$releaseRoot/dist/Screenshot Renamer.zip" "$releaseStage/$releaseArchive"
cp "$releaseNotes" "$releaseStage/Screenshot-Renamer-$releaseVersion.md"
python3 - "$releaseStage/$releaseArchive" "$releaseRevision" "$releaseVersion" "$releaseBuild" "$releasePublicKey" "$releaseStage/source-revision.json" <<'PY'
import json, plistlib, sys, zipfile
archive, revision, version, build, key, output = sys.argv[1:]
with zipfile.ZipFile(archive) as bundle:
    info = plistlib.loads(bundle.read('Screenshot Renamer.app/Contents/Info.plist'))
expected = {'ScreenshotRenamerRevision': revision, 'CFBundleShortVersionString': version,
            'CFBundleVersion': build, 'SUPublicEDKey': key, 'SURequireSignedFeed': True,
            'SUVerifyUpdateBeforeExtraction': True,
            'SUFeedURL': 'https://github.com/Kevinmthau/Screenshotter/releases/latest/download/appcast.xml'}
for field, value in expected.items():
    if info.get(field) != value:
        raise SystemExit('Packaged app differs from committed release configuration: ' + field)
with open(output, 'w') as handle:
    json.dump({'repository': 'Kevinmthau/Screenshotter', 'commit': revision,
               'version': version, 'build': build, 'sparkle': '2.10.0'}, handle, indent=2)
    handle.write('\n')
PY
"$releaseTools/generate_appcast" --account "$releaseAccount" \
    --download-url-prefix "https://github.com/Kevinmthau/Screenshotter/releases/download/v$releaseVersion/" \
    --maximum-deltas 0 --embed-release-notes "$releaseStage"
"$releaseTools/sign_update" --account "$releaseAccount" --verify "$releaseStage/appcast.xml"
releaseSignature="$(python3 - "$releaseStage/appcast.xml" "$releaseArchive" "$releaseVersion" "$releaseBuild" <<'PY'
import sys, xml.etree.ElementTree as ET
path, archive, version, build = sys.argv[1:]
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(path).findall('./channel/item')
if len(items) != 1:
    raise SystemExit('Expected exactly one release in the generated feed.')
item = items[0]
enclosure = item.find('enclosure')
if enclosure is None or enclosure.get('url') != f'https://github.com/Kevinmthau/Screenshotter/releases/download/v{version}/{archive}':
    raise SystemExit('Generated feed has an unexpected download URL.')
if item.findtext(sparkle + 'version', enclosure.get(sparkle + 'version')) != build:
    raise SystemExit('Generated feed has an unexpected build number.')
if item.findtext(sparkle + 'shortVersionString', enclosure.get(sparkle + 'shortVersionString')) != version:
    raise SystemExit('Generated feed has an unexpected version.')
if not item.findtext('description'):
    raise SystemExit('Generated feed does not embed release notes.')
print(enclosure.attrib[sparkle + 'edSignature'])
PY
)"
"$releaseTools/sign_update" --account "$releaseAccount" --verify "$releaseStage/$releaseArchive" "$releaseSignature"
(
    cd "$releaseStage"
    shasum -a 256 "$releaseArchive" "Screenshot-Renamer-$releaseVersion.md" appcast.xml source-revision.json > SHA256SUMS
)
[[ "$(git rev-parse HEAD)" == "$releaseRevision" && -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Source changed while signing; release discarded.'
mv "$releaseStage" "$releaseDirectory"
trap - EXIT
printf '\nPrepared and verified: %s\n' "$releaseDirectory"
printf 'Review the notes and appcast, then publish with:\n  ./scripts/publish-release.sh --prepared dist/releases/v%s\n' "$releaseVersion"
if [[ "${SCREENSHOT_RENAMER_SIGNING_IDENTITY:--}" == - ]]; then
    printf 'This app is ad-hoc code-signed and is not notarized. Sparkle signatures authenticate its feed and update archive.\n'
fi
