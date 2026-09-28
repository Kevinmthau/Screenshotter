# App updates and releases

Screenshot Renamer uses Sparkle 2.10.0. The app checks daily for updates and offers
**Check for Updates…** in its menu. Downloading and installing an available update
requires the user's approval; silent installation is disabled. A Mac running the
older app without Sparkle needs one manual installation of version 1.1.0 or later.

The public repository contains the source and release assets:

- Releases: <https://github.com/Kevinmthau/Screenshotter/releases>
- Stable feed: <https://github.com/Kevinmthau/Screenshotter/releases/latest/download/appcast.xml>

Both the feed and each update ZIP have Ed25519 signatures. The public verification
key is committed in `packaging/Info.plist`; the private signing key remains in the
maintainer's macOS Keychain under account `com.kevinthau.screenshot-renamer`.
The release scripts never export it. macOS may separately ask for local Keychain
approval when `generate_appcast` or `sign_update` first accesses this key. Approve
the expected Sparkle tool in the system prompt yourself; automated UI cannot
handle this security prompt. Do not export the key or weaken Keychain access to
bypass it. Keep a secure backup of that Keychain and do not replace the key casually: existing installations trust the current key.

## Signing status

The initial distribution is **ad-hoc code-signed and not notarized** because this
Mac has no Apple Developer ID signing certificate. Sparkle verifies that updates
come from the holder of the update signing key and have not changed. Those
signatures do not provide Apple Gatekeeper trust. A first installation downloaded
from GitHub can therefore require a manual macOS security approval.

For ordinary public distribution, obtain an Apple Developer ID Application
certificate and notarize the app with Apple. `scripts/build-app.sh` already accepts
`SCREENSHOT_RENAMER_SIGNING_IDENTITY` for Developer ID signing, with hardened
runtime and a secure timestamp. The current release scripts do **not** submit to
Apple's notarization service or staple tickets; add and validate those steps before
claiming releases are notarized. Never put the signing certificate's private key,
Apple credentials, or Sparkle private key in this repository.

## Publish a new version

Use the maintainer Mac with Xcode, Python 3, GitHub CLI authenticated for this
repository, and the existing Sparkle signing key available in its login Keychain.
Releases run locally; GitHub Actions checks pull requests without release keys.

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in
   `packaging/Info.plist`. Use a numeric `major.minor.patch` version and a positive
   integer build number. Both must be greater than the latest release. Commit all
   source changes, merge them into `main`, and push `main`.
2. Write release notes to a Markdown file outside the source tree, such as
   `/tmp/screenshot-renamer-release-notes.md`. The notes are published verbatim in
   the GitHub release and embedded in the signed update feed.
3. From a clean `main` synchronized with `origin/main`, run:

   ```sh
   ./scripts/publish-release.sh /tmp/screenshot-renamer-release-notes.md
   ```

This runs the unit, watcher, and AppKit checks and builds a universal arm64/x86_64
app. It checks that the Keychain key matches the app, creates a versioned archive,
signs the feed and archive, verifies both signatures, and records the exact source
revision plus SHA-256 checksums. It compares the new version/build with the latest
hosted signed feed, creates a draft release pinned to the verified commit, uploads
all assets, downloads and checks their contents, then publishes it as latest.
Existing tags and releases are never overwritten. The previous release remains
latest until the complete draft is published.

To prepare and review everything before publication:

```sh
./scripts/publish-release.sh --prepare-only /tmp/screenshot-renamer-release-notes.md
# Inspect dist/releases/v1.1.0/ (substitute the version you prepared).
./scripts/publish-release.sh --prepared dist/releases/v1.1.0
```

Preparation can run on a clean feature branch; publication requires that exact
revision to be the current `main` and `origin/main`. Do not edit prepared notes,
ZIPs, or the appcast: this invalidates their checksums or signatures. Move an old
prepared directory aside if you intentionally need to rebuild the same unpublished
version. Version/build environment overrides are rejected for releases; the source
plist is the authoritative version record.

The default build cache is `${TMPDIR:-/tmp}/screenshot-renamer-build`. If you set
`SCREENSHOT_RENAMER_BUILD_PATH`, use the same value for preparation and publication
so the publisher can find Sparkle's verification tools. Outputs under `dist/` are
ignored by Git. Each prepared release contains:

- `Screenshot-Renamer-VERSION.zip` — the signed app bundle.
- `Screenshot-Renamer-VERSION.md` — public release notes.
- `appcast.xml` — signed feed with embedded notes and archive signature.
- `source-revision.json` — repository, commit, version, build, and Sparkle version.
- `SHA256SUMS` — checksums for the four files above.

If an upload or verification fails, the script leaves any draft for inspection and
stops without making it latest. It deliberately refuses to overwrite or silently
resume that draft. Inspect the failure, then remove the unpublished draft (and any
unpublished tag, if GitHub created one) before retrying. Do not delete a published
release to reuse its version; fix the problem in a new version with a higher build.

## Verify an update

Install the initial Sparkle-enabled app using `scripts/install.sh`, launch it, and
choose **Check for Updates…**. A current installation should report that it is up
to date. To verify an actual update installation, use a disposable app installation
built with an older test build number; preserve the production app and its data.
Do not publish an older test build. The complete update test must confirm download,
signature verification, replacement, relaunch, and the resulting app version.

A successful build, signed appcast, or “up to date” dialog alone does not prove that
an older installation was successfully upgraded. Record that test separately in
`docs/TEST-SUMMARY.md` when it has actually run.
