#!/bin/bash
set -euo pipefail

releaseRoot="$(cd "$(dirname "$0")/.." && pwd)"
cd "$releaseRoot"
releaseRepo=Kevinmthau/Screenshotter
releaseAccount=com.kevinthau.screenshot-renamer
fail() { printf 'Release publication stopped: %s\n' "$*" >&2; exit 1; }
usage() {
    printf 'Usage: %s NOTES.md\n       %s --prepare-only NOTES.md\n       %s --prepared dist/releases/vVERSION\n' "$0" "$0" "$0"
}
if [[ $# -eq 1 && "$1" == --help ]]; then usage; exit 0; fi
if [[ $# -eq 2 && "$1" == --prepare-only ]]; then
    exec "$releaseRoot/scripts/prepare-release.sh" "$2"
fi
releasePrepared=false
if [[ $# -eq 2 && "$1" == --prepared ]]; then
    releasePrepared=true
    releaseInput="$2"
elif [[ $# -eq 1 && "$1" != --* ]]; then
    releaseInput="$1"
else
    usage; exit 1
fi
[[ "$(uname -s)" == Darwin ]] || fail 'macOS is required.'
command -v gh >/dev/null || fail 'Install GitHub CLI and sign in with gh auth login.'
[[ -z "${SCREENSHOT_RENAMER_VERSION+x}" && -z "${SCREENSHOT_RENAMER_BUILD_NUMBER+x}" ]] || fail 'Version/build overrides are forbidden.'
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Commit all source changes and remove untracked source files first.'
[[ "$(git symbolic-ref --quiet --short HEAD)" == main ]] || fail 'Publish only from main.'
releaseOrigin="$(git remote get-url origin)"
case "$releaseOrigin" in
    https://github.com/Kevinmthau/Screenshotter|https://github.com/Kevinmthau/Screenshotter.git|git@github.com:Kevinmthau/Screenshotter|git@github.com:Kevinmthau/Screenshotter.git|ssh://git@github.com/Kevinmthau/Screenshotter.git) ;;
    *) fail 'origin must point to Kevinmthau/Screenshotter on github.com.' ;;
esac
[[ "$(gh api "repos/$releaseRepo" --jq '.visibility')" == public ]] || fail 'The update feed requires this repository to be public.'
git fetch --quiet origin main
releaseRevision="$(git rev-parse HEAD)"
[[ "$releaseRevision" == "$(git rev-parse origin/main)" ]] || fail 'main must be pushed and exactly synchronized with origin/main.'
releaseVersion="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' packaging/Info.plist)"
releaseBuild="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' packaging/Info.plist)"
[[ "$releaseVersion" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || fail 'Use a numeric major.minor.patch version without leading zeroes.'
[[ "$releaseBuild" =~ ^[1-9][0-9]{0,8}$ ]] || fail 'Use a positive integer build number without leading zeroes.'
releaseTag="v$releaseVersion"
releaseArchive="Screenshot-Renamer-$releaseVersion.zip"
releaseNotes="Screenshot-Renamer-$releaseVersion.md"
releaseWork="$(mktemp -d "${TMPDIR:-/tmp}/screenshot-renamer-publication.XXXXXX")"
trap 'rm -rf "$releaseWork"' EXIT

readLatest() {
    gh release list --repo "$releaseRepo" --limit 1000 --json tagName,isLatest,isDraft,isPrerelease > "$releaseWork/releases.json"
    python3 - "$releaseWork/releases.json" "$releaseTag" <<'PY'
import json, sys
releases = json.load(open(sys.argv[1]))
if any(release['tagName'] == sys.argv[2] for release in releases):
    raise SystemExit('This tag already has a release, possibly a draft; existing releases are never overwritten.')
stable = [release for release in releases if not release['isDraft'] and not release['isPrerelease']]
latest = [release for release in stable if release['isLatest']]
if stable and len(latest) != 1:
    raise SystemExit('Could not identify exactly one latest stable release.')
print(latest[0]['tagName'] if latest else '')
PY
}
releasePrevious="$(readLatest)"
releaseRemoteTag="$(git ls-remote --tags origin "refs/tags/$releaseTag" "refs/tags/$releaseTag^{}")"
[[ -z "$releaseRemoteTag" ]] || fail 'The remote release tag already exists; tags are never overwritten.'
if git show-ref --verify --quiet "refs/tags/$releaseTag"; then fail 'The local release tag already exists; remove ambiguity before publication.'; fi
if [[ -n "$releasePrevious" ]]; then
    /usr/bin/curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        "https://github.com/$releaseRepo/releases/download/$releasePrevious/appcast.xml" -o "$releaseWork/previous-appcast.xml"
    python3 - "$releaseWork/previous-appcast.xml" "$releasePrevious" "$releaseVersion" "$releaseBuild" <<'PY'
import re, sys, xml.etree.ElementTree as ET
feed, previous, version, build = sys.argv[1:]
pattern = r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
if not re.fullmatch('v' + pattern, previous):
    raise SystemExit('The latest release tag does not have the expected numeric version.')
if tuple(map(int, version.split('.'))) <= tuple(map(int, previous[1:].split('.'))):
    raise SystemExit('The new version must be greater than the latest published version.')
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(feed).findall('./channel/item')
if not items:
    raise SystemExit('The latest release has an empty feed.')
for item in items:
    enclosure = item.find('enclosure')
    if enclosure is None:
        raise SystemExit('The latest feed has no download enclosure.')
    old_build = item.findtext(sparkle + 'version', enclosure.get(sparkle + 'version'))
    if not old_build or not re.fullmatch(r'[1-9][0-9]*', old_build) or int(build) <= int(old_build):
        raise SystemExit('The new build number must exceed every build in the latest feed.')
PY
fi

export SCREENSHOT_RENAMER_BUILD_PATH="${SCREENSHOT_RENAMER_BUILD_PATH:-${TMPDIR:-/tmp}/screenshot-renamer-build}"
if [[ "$releasePrepared" == true ]]; then
    [[ -d "$releaseInput" ]] || fail 'The prepared release directory does not exist.'
    releaseDirectory="$(cd "$releaseInput" && pwd)"
else
    "$releaseRoot/scripts/prepare-release.sh" "$releaseInput"
    releaseDirectory="$releaseRoot/dist/releases/$releaseTag"
fi
releaseTools="$SCREENSHOT_RENAMER_BUILD_PATH/artifacts/sparkle/Sparkle/bin"
[[ -x "$releaseTools/sign_update" ]] || fail 'Sparkle tools are missing; use the same SCREENSHOT_RENAMER_BUILD_PATH as preparation.'
releasePublicKey="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' packaging/Info.plist)"
[[ "$("$releaseTools/generate_keys" --account "$releaseAccount" -p)" == "$releasePublicKey" ]] || fail 'The Keychain signing key does not match Info.plist.'
if [[ -n "$releasePrevious" ]]; then
    "$releaseTools/sign_update" --account "$releaseAccount" --verify "$releaseWork/previous-appcast.xml"
fi
python3 - "$releaseDirectory" "$releaseRevision" "$releaseVersion" "$releaseBuild" "$releasePublicKey" <<'PY'
import hashlib, json, pathlib, plistlib, re, sys, zipfile
path = pathlib.Path(sys.argv[1])
revision, version, build, key = sys.argv[2:]
archive = f'Screenshot-Renamer-{version}.zip'
expected_files = {archive, f'Screenshot-Renamer-{version}.md', 'appcast.xml', 'source-revision.json'}
manifest = {}
for line in (path / 'SHA256SUMS').read_text().splitlines():
    match = re.fullmatch(r'([a-f0-9]{64})  ([A-Za-z0-9.-]+)', line)
    if not match or match[2] in manifest:
        raise SystemExit('Invalid release checksum manifest.')
    manifest[match[2]] = match[1]
if set(manifest) != expected_files:
    raise SystemExit('Release checksum manifest has an unexpected file list.')
for name, digest in manifest.items():
    if hashlib.sha256((path / name).read_bytes()).hexdigest() != digest:
        raise SystemExit('Release checksum failed: ' + name)
metadata = json.loads((path / 'source-revision.json').read_text())
for field, value in {'repository': 'Kevinmthau/Screenshotter', 'commit': revision, 'version': version, 'build': build, 'sparkle': '2.10.0'}.items():
    if metadata.get(field) != value:
        raise SystemExit('Prepared source metadata does not match current HEAD: ' + field)
with zipfile.ZipFile(path / archive) as bundle:
    info = plistlib.loads(bundle.read('Screenshot Renamer.app/Contents/Info.plist'))
for field, value in {'ScreenshotRenamerRevision': revision, 'CFBundleShortVersionString': version, 'CFBundleVersion': build,
                     'SUPublicEDKey': key, 'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True,
                     'SUFeedURL': 'https://github.com/Kevinmthau/Screenshotter/releases/latest/download/appcast.xml'}.items():
    if info.get(field) != value:
        raise SystemExit('Prepared app does not match the current release configuration: ' + field)
PY
"$releaseTools/sign_update" --account "$releaseAccount" --verify "$releaseDirectory/appcast.xml"
releaseSignature="$(python3 - "$releaseDirectory/appcast.xml" "$releaseVersion" "$releaseBuild" "$releaseDirectory/$releaseArchive" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
feed, version, build, archive = sys.argv[1:]
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(feed).findall('./channel/item')
if len(items) != 1:
    raise SystemExit('Expected one release item.')
item = items[0]
enclosure = item.find('enclosure')
if enclosure is None or enclosure.get('url') != f'https://github.com/Kevinmthau/Screenshotter/releases/download/v{version}/Screenshot-Renamer-{version}.zip':
    raise SystemExit('Unexpected release download URL.')
if item.findtext(sparkle + 'version', enclosure.get(sparkle + 'version')) != build or item.findtext(sparkle + 'shortVersionString', enclosure.get(sparkle + 'shortVersionString')) != version:
    raise SystemExit('The signed feed does not match the prepared version/build.')
if enclosure.get('length') != str(pathlib.Path(archive).stat().st_size):
    raise SystemExit('The signed feed archive size is incorrect.')
print(enclosure.attrib[sparkle + 'edSignature'])
PY
)"
"$releaseTools/sign_update" --account "$releaseAccount" --verify "$releaseDirectory/$releaseArchive" "$releaseSignature"

# Recheck after the potentially long build, before making any GitHub changes.
git fetch --quiet origin main
[[ "$(git symbolic-ref --quiet --short HEAD)" == main && "$(git rev-parse HEAD)" == "$releaseRevision" && "$(git rev-parse origin/main)" == "$releaseRevision" && -z "$(git status --porcelain --untracked-files=all)" ]] || fail 'Source or origin/main changed during preparation.'
releaseLatestNow="$(readLatest)"
[[ "$releaseLatestNow" == "$releasePrevious" ]] || fail 'The latest release changed during preparation.'
releaseRemoteTag="$(git ls-remote --tags origin "refs/tags/$releaseTag" "refs/tags/$releaseTag^{}")"
[[ -z "$releaseRemoteTag" ]] || fail 'The release tag appeared during preparation.'
releaseAssets=("$releaseDirectory/$releaseArchive" "$releaseDirectory/$releaseNotes" "$releaseDirectory/appcast.xml" "$releaseDirectory/source-revision.json" "$releaseDirectory/SHA256SUMS")
printf 'Creating draft %s from %s…\n' "$releaseTag" "$releaseRevision"
gh release create "$releaseTag" --repo "$releaseRepo" --target "$releaseRevision" --draft \
    --title "Screenshot Renamer $releaseVersion" --notes-file "$releaseDirectory/$releaseNotes" "${releaseAssets[@]}"
# A failure from here leaves a draft for inspection, never a partial public update.
gh release view "$releaseTag" --repo "$releaseRepo" --json isDraft,targetCommitish,assets > "$releaseWork/draft.json"
python3 - "$releaseWork/draft.json" "$releaseRevision" "$releaseDirectory" "$releaseArchive" "$releaseNotes" <<'PY'
import json, pathlib, sys
metadata = json.load(open(sys.argv[1]))
path = pathlib.Path(sys.argv[3])
expected = {sys.argv[4], sys.argv[5], 'appcast.xml', 'source-revision.json', 'SHA256SUMS'}
if not metadata['isDraft'] or metadata['targetCommitish'] != sys.argv[2]:
    raise SystemExit('Draft release is not pinned to the expected source revision.')
assets = {asset['name']: asset for asset in metadata['assets']}
if set(assets) != expected or any(assets[name]['size'] != (path / name).stat().st_size for name in expected):
    raise SystemExit('Draft release uploads are incomplete.')
PY
mkdir "$releaseWork/downloaded"
gh release download "$releaseTag" --repo "$releaseRepo" --dir "$releaseWork/downloaded"
python3 - "$releaseDirectory" "$releaseWork/downloaded" <<'PY'
import hashlib, pathlib, sys
source, downloaded = map(pathlib.Path, sys.argv[1:])
names = ['SHA256SUMS'] + [line.split('  ', 1)[1] for line in (source / 'SHA256SUMS').read_text().splitlines()]
for name in names:
    if hashlib.sha256((source / name).read_bytes()).digest() != hashlib.sha256((downloaded / name).read_bytes()).digest():
        raise SystemExit('Uploaded asset differs from the verified local file: ' + name)
PY
gh release edit "$releaseTag" --repo "$releaseRepo" --draft=false --latest
# Confirm GitHub exposed the exact commit and signed feed just published.
releaseRemoteRevision="$(gh api "repos/$releaseRepo/commits/$releaseTag" --jq '.sha')"
[[ "$releaseRemoteRevision" == "$releaseRevision" ]] || fail 'Published tag does not resolve to the expected commit; inspect GitHub immediately.'
/usr/bin/curl --fail --silent --show-error --location --retry 3 --proto '=https' --proto-redir '=https' \
    "https://github.com/$releaseRepo/releases/latest/download/appcast.xml" -o "$releaseWork/published-appcast.xml"
cmp -s "$releaseDirectory/appcast.xml" "$releaseWork/published-appcast.xml" || fail 'Published latest feed differs from prepared feed; inspect GitHub.'
"$releaseTools/sign_update" --account "$releaseAccount" --verify "$releaseWork/published-appcast.xml"
printf '\nPublished: https://github.com/%s/releases/tag/%s\n' "$releaseRepo" "$releaseTag"
