# Validation

## October 2 automatic startup and updater integration

The automatic startup change was integrated with the newer remote main, retaining automatic connection recovery, current Codex bundle discovery, and the Sparkle updater with its signed feed configuration. The app now starts naming new screenshots without preview or enable controls, and the installer launches it. Version **1.1.1 (build 3)** identifies this local development revision; it has not been published as a hosted release.

The combined revision passed `./scripts/check.sh` locally:

- **114 XCTest cases: 113 passed, 1 opt-in network case skipped, 0 failures.**
- **8 real filesystem watcher checks passed.**
- **44 AppKit UI checks passed**, preserving updater controls and attention explanations alongside the simplified Settings flow.
- **23 startup checks passed**, covering automatic naming, existing files, disabled legacy migrations, persistent Pause/Resume, connection and folder recovery, and updater isolation. The harness uses an offline CLI, isolated settings, and disabled network monitoring; no model calls, login-item changes, or update checks run.
- The **universal arm64 + x86_64 build passed**, including deep, strict code-signature verification of the app and nested Sparkle code.

The combined build was not installed or published, and live model tests remained disabled. Results below distinguish the earlier installed simplification build from the remote updater release validation.

### Earlier local startup validation (before integration)

The installer now launches the installed app. A normal launch uses the Desktop by default, checks Codex, and starts automatic naming without a preview or enable step. Settings retains folder and connection recovery controls, with Pause, History, and Undo available from the menu. Open at Login is requested once by default, and subsequent launches respect the user's choice. Generated sample checks remain available through the developer-only `--integration-check` mode.

The local release-mode build, installer shell syntax, Info.plist validation, and strict installed code-signature verification passed. Those checks completed with:

- **97 XCTest cases: 96 passed, 1 opt-in network case skipped, 0 failures.**
- **35 UI checks passed**, including removal of preview/enable/consent controls and startup Retry availability.
- **22 startup checks passed**, covering fresh and disabled legacy installations, automatic naming, existing-file preservation, saved folder/baseline recovery, Pause/Resume across relaunch, missing Codex, and folder-access Retry recovery. These checks use temporary files and an offline CLI fixture; they do not submit images or change login items.
- **8 real FSEvents watcher checks passed** across 9 callback batches.

A local development build numbered **1.1.0 (build 2)** from the simplification-only tree was installed at `~/Applications/Screenshot Renamer.app` and launched automatically by the installer. The running process retained the Desktop folder, original activation time, and enabled/unpaused settings. Preview fields were removed from the saved settings. macOS background-item records reported Open at Login as enabled and allowed. An actual login-session relaunch was not tested. Native UI inspection of this installed update was unavailable because Computer Use permission was not granted; the UI checks above exercised the production AppKit views with synthetic state. These checks predate integration with remote main and do not validate the combined updater and startup revision.

## September 28 combined cleanup and updater validation

The combined reliability, connection-check, and Sparkle updater changes passed `./scripts/check.sh` locally:

- **114 XCTest cases: 113 passed, 1 opt-in network case skipped, 0 failures.** Current and legacy Codex bundle layouts are covered.
- **8 filesystem watcher checks passed.**
- **34 AppKit UI checks passed**, including 7 new checks for menu and window update controls.
- The **universal arm64 + x86_64 app build passed**, including deep, strict code-signature verification of the app and its nested code.

The final suite and packaging also passed on [GitHub's macOS 15 runner with Xcode 16.4](https://github.com/Kevinmthau/Screenshotter/actions/runs/36494546692). An earlier CI run caught and fixed an older-SDK compile failure in the subprocess working-directory setup.

### Hosted release and installed update

[Version 1.1.0, build 2](https://github.com/Kevinmthau/Screenshotter/releases/tag/v1.1.0) was published from commit `1af3ca614f802c367c16fcafbfa5f1113b19fc42`. All five release assets download without authentication. The stable feed matches the versioned feed; archive checksums, packaged revision, release metadata, and Git tag agree. Both the feed and archive signatures verified. A separate signing smoke test rejected a modified feed.

An actual Sparkle update completed on this Mac:

- Preserved the previous app archive and installed a local bootstrap build numbered 1.0.99, build 1, using the same feed and public key. This test build was never published.
- **Check for Updates…** discovered hosted version 1.1.0 and displayed its release notes.
- **Install Update**, then **Install and Relaunch**, downloaded the archive, replaced the app, and relaunched it successfully.
- The installed app reported version 1.1.0, build 2, and the exact release revision. Deep, strict verification passed for the installed app and nested code.
- The chosen folder, automatic naming state, and generated preview results were restored. The app returned to **Watching · 0 pending** with **Codex is available · saved login verified**. Canonical JSON fingerprints confirmed unchanged history; settings are rewritten during normal startup and were checked through the restored UI state.
- A second update check reported **You’re up to date! Screenshot Renamer 1.1.0 is currently the newest version available.**

These checks submitted no new model requests. They establish hosted download, installation, relaunch, and local CLI discovery on this Mac; they do not establish first-download Gatekeeper approval on another Mac or model naming quality for this revision. The app is ad hoc code-signed and not Apple Developer ID signed or notarized. The September 21 live-service evidence below remains historical.

## September 28 reliability update

This update lets the menu-bar app recover from temporary problems without intervention, so it can stay on from login: automatic Codex rechecks with backoff, waiting for the network, a longer retry schedule, keep-original review items for images that cannot be named, recovery from a briefly unreadable folder, and a saved-path fallback when a rebuilt app cannot resolve its folder bookmark. The menu now shows why it needs attention, and **Open at Login** no longer unregisters when macOS approval is pending.

A [successful macOS CI run on September 28](https://github.com/Kevinmthau/Screenshotter/actions/runs/36484870640) compiled and tested commit `e7cdf04000b3a9ab1b65f488f52b51fd79ae940c`: Swift unit tests, the filesystem watcher harness, and the AppKit UI harness all passed. That temporary workflow did not package or install the app, run live model requests, or validate hosted updates. Its results supersede the earlier statement that the reliability update had not been compiled or tested.

`FailureRecoveryTests` and the updated `CapturePipelineTests` cover the retry schedule, connection-check backoff, and keep-original outcomes. The results in the dated sections below describe earlier releases.

## Repeatable validation

Run all offline checks and build a locally signed app archive with:

```sh
./scripts/check.sh
```

The script runs Swift unit tests, the filesystem watcher harness, the AppKit UI harness, the automatic startup harness, and `build-app.sh`, including bundle signature verification. It uses a temporary-directory build cache, selects full Xcode for this process if the active Command Line Tools selection lacks XCTest, and leaves app installation and login-item settings untouched. Set `DEVELOPER_DIR` explicitly to use another Xcode installation.

Run `./scripts/test-startup.sh` separately for automatic startup, migration, folder recovery, and Pause/Resume checks. It uses temporary settings, generated fixture images, and an offline CLI fixture; it does not change the installed app or login-item registration.

The permanent `.github/workflows/checks.yml` workflow runs the same command on macOS for pull requests, pushes to `main`, and manual dispatches. Live model tests are disabled in CI. Locally, they remain an explicit opt-in through `SCREENSHOT_RENAMER_LIVE_TESTS=1`; this submits generated samples using the saved Codex login. Hosted, signed update delivery requires separate release validation and is not established by these checks.

## September 22 connection fix

Selecting `ChatGPT.app` or `Codex.app` through **Locate Codex…** now resolves the embedded `Contents/Resources/codex` executable. Previously saved app-bundle selections are also supported. Executable validation rejects directories, and clicking Preview before connecting Codex now displays an actionable message.

The focused `CodexAnalyzerTests` run completed with **18 passed, 1 opt-in network case skipped, and 0 failures**, including a new regression covering app-bundle selections, direct executable selections, and invalid directories. Tests used full Xcode because the selected Command Line Tools did not provide XCTest:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /tmp/screenshot-renamer-xcode-tests --filter CodexAnalyzerTests
```

The release build and strict code-signature verification passed, and the updated app was installed and reopened. The bundled Codex CLI reported a valid saved ChatGPT login in a minimal environment. Live sample generation and the reopened UI were not verified for this update; the installed-app measurements below describe the earlier release.

## September 21 validation

Local validation used this Apple Silicon Mac running macOS 27.0, Swift 6.4, and a macOS 13 deployment target. The release archive at that time, `dist/Screenshot Renamer.zip`, was rebuilt and its bundle passed strict ad hoc code-signature verification. An earlier build remained installed at `~/Applications/Screenshot Renamer.app`. Building and staging in temporary folders avoids Finder metadata added by the synced Documents folder. The installed-app and live-service evidence below predates subsequent review fixes and was not rerun for the September 28 cleanup.

### Historical automated and runtime results

**101 XCTest cases: 100 passed, 1 opt-in network case skipped, 0 failures.** These earlier local results include the pipeline, file-transaction, connection-check, and integration-report regressions below. Earlier live generated-sample and installed-app runs are recorded separately; they do not validate the combined September 28 revision against the service.

- Safe file operations: collisions, exclusive no-overwrite rename, byte preservation, exact extension preservation, changed contents (including same size and restored modification time), replacement identity, manual move/deletion, symlinks, occupied Undo destination, modified Undo source, concurrent journal instances, durable rename/Undo recovery, corrupt journal rejection, journal-write failure, 30-day pruning, and Clear History.
- Eligibility and queue: activation baseline, old captures, manual names, non-image downloads, recordings, duplicate events, own renames, bounded capacity of 64, editor replacements, stability delay, pending recovery, moved originals with same-path replacements, retry scheduling, expired pending filenames, and late metadata rejection.
- Codex bridge: strict JSON schema, unsafe names, configured-model parsing, environment isolation, login/quota/offline categories, bounded output and ordered diagnostic tails under output floods, process-group cancellation, deadlines and cancellation when descendants keep output pipes open, temporary cleanup, image-format preservation, and rejection of symlinks, nonregular files, and oversized sources.
- Connection checks: changing the executable discards stale success and failure results, replacements wait for prior cleanup, superseded queued checks never start, and shutdown drains every outstanding check and rejects new ones. A local CLI fixture verifies that stopping a check terminates its subprocess and removes its temporary directory.
- Review regressions: excluded files cannot replace pending captures or reappear after renaming/restart; inaccessible files and folders preserve recovery intents until access returns; persisted and legacy queues preserve their capture day across timezone changes, including date fallback and filename collisions. Folder access is restored before startup recovery.
- Capture pipeline: event bursts share a follow-up scan; stale folder and queue results cannot submit analysis; blocked file scans leave the main actor responsive; cached scans still detect edits and replacements; pause revokes queued renames; cancellation serializes with authorized mutations; stale scans preserve new captures; injected clocks verify bounded retries.
- File transactions: occupied destinations share one transaction, newly created destinations still receive exclusive no-overwrite protection, journal sync failures retain recoverable intents, and FIFO/directory journals are rejected safely.
- Integration reports: every sample must receive a useful name and preserve content through rename and Undo; failures retain partial results, unavailable analysis avoids submissions, empty sample sets fail, and an unwritable report is rejected before submitting images.

**8 actual watcher checks passed.** The harness used the production watcher, ledger, and safe renamer in an isolated temporary directory, with the main run loop running. It verified real creation events, the two-second stability interval, eligibility without an extra event, duplicate coalescing, manual rename/deletion cancellation, byte-preserving application renames without loops, and untouched baseline files. Test data was removed afterward.

**27 UI checks passed.** The harness exercised the production AppKit UI with synthetic state, without model calls or changes to user settings. It verified deferred rendering for closed windows and hidden panels, row and menu reuse, stable constraints, Undo state and action identity, row updates and reordering, empty states, and locale/timezone date refreshes.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /tmp/screenshot-renamer-tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/test-watcher.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/test-ui.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build-app.sh
```

### Historical installed-app integration

The earlier installed build was launched through LaunchServices with `--integration-check`. Saved ChatGPT authentication and CLI discovery worked without a shell profile or this conversation. Three generated screens were analyzed, renamed in a temporary directory, and undone. All three preserved SHA-256 content fingerprints through both operations. See `installed-app-check.json` for the captured report. This run predates the current integration-report regression coverage.

| Generated screen | Final filename | Analysis latency |
| --- | --- | --- |
| Notes product | Flourish - On-Device AI Notes - 2026-09-21.png | 4.96 s |
| Spending dashboard | Harbor - Monthly Spending Overview - 2026-09-21.png | 5.21 s |
| Travel itinerary | Atlas - Kyoto Weekend Itinerary - 2026-09-21.png | 4.66 s |

Mean measured analysis latency was 4.94 seconds, plus at least two seconds of save stability for watched captures. Latency is not guaranteed. The spending title excluded fictional financial amounts and account identifiers. The travel title ignored instruction-like text in the screenshot.

A separate actual-CLI signed-out test used an empty temporary authentication home and returned an actionable authentication error without changing the saved login. A local mock-provider audit of the installed CLI's outgoing request confirmed `tools: []`. Offline and quota cases used controlled failures; the test did not change network settings or consume a reset credit. More detail is in `CODEX-INTEGRATION.md`.

During the September 21 validation, the installed native interface was inspected through accessibility and screenshots. Connection status, generated preview results, privacy checkbox, disabled automatic activation before consent, History, and initial setup rendered correctly. The chosen Desktop bookmark resolved after replacing and reopening the app. Automatic naming and Open at Login were left disabled during that check, and no existing Desktop file was renamed.

## Practical limits and remaining user checks

- Validation was performed on this Mac, not on a separate macOS 13 machine. The deployment target and API availability are checked by compilation.
- Actual login-session relaunch has not been tested. The app uses Apple's `SMAppService.mainApp` mechanism and requests Open at Login on first launch; the menu can disable it.
- English macOS screenshot names are supported in this first release. Customized or localized default filenames are conservatively excluded.
- Pause and shutdown invalidate outstanding work before rename and cancel the local child process; already submitted images cannot be recalled. The child-process cancellation is tested, while active Desktop capture/pause/wake behavior remains a user acceptance check.
- Destination no-overwrite is atomic. macOS does not provide a source-inode-conditioned rename; the implementation rechecks identity and content immediately before and after rename and attempts exclusive rollback on a race. Another process mutating the same file at the exact system-call boundary cannot be excluded absolutely.
- Model naming quality and privacy instructions were validated on generated examples, not on the user's private screenshots.

## References

- [Apple File System Events](https://developer.apple.com/documentation/coreservices/file_system_events)
- [Apple login-item registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register())
- [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
