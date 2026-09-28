# Validation

## September 28 combined cleanup and updater validation

The combined reliability, connection-check, and Sparkle updater changes passed `./scripts/check.sh` locally:

- **112 XCTest cases: 111 passed, 1 opt-in network case skipped, 0 failures.**
- **8 filesystem watcher checks passed.**
- **33 AppKit UI checks passed**, including 6 new checks for update controls.
- The **universal arm64 + x86_64 app build passed**, including deep, strict code-signature verification of the app and its nested code.

These results validate the combined source, local harnesses, and packaged app. An actual Sparkle download and installation from a hosted feed has not yet been tested end to end. The September 21 installed-app and live-service evidence below is historical and does not validate the updater.

## September 28 reliability update

This update lets the menu-bar app recover from temporary problems without intervention, so it can stay on from login: automatic Codex rechecks with backoff, waiting for the network, a longer retry schedule, keep-original review items for images that cannot be named, recovery from a briefly unreadable folder, and a saved-path fallback when a rebuilt app cannot resolve its folder bookmark. The menu now shows why it needs attention, and **Open at Login** no longer unregisters when macOS approval is pending.

A [successful macOS CI run on September 28](https://github.com/Kevinmthau/Screenshotter/actions/runs/36484870640) compiled and tested commit `e7cdf04000b3a9ab1b65f488f52b51fd79ae940c`: Swift unit tests, the filesystem watcher harness, and the AppKit UI harness all passed. That temporary workflow did not package or install the app, run live model requests, or validate hosted updates. Its results supersede the earlier statement that the reliability update had not been compiled or tested.

`FailureRecoveryTests` and the updated `CapturePipelineTests` cover the retry schedule, connection-check backoff, and keep-original outcomes. The results in the dated sections below describe earlier releases.

## Repeatable validation

Run all offline checks and build a locally signed app archive with:

```sh
./scripts/check.sh
```

The script runs Swift unit tests, the filesystem watcher harness, the AppKit UI harness, and `build-app.sh`, including bundle signature verification. It uses a temporary-directory build cache, selects full Xcode for this process if the active Command Line Tools selection lacks XCTest, and leaves app installation and login-item settings untouched. Set `DEVELOPER_DIR` explicitly to use another Xcode installation.

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

The installed native interface was inspected through accessibility and screenshots. Connection status, generated preview results, privacy checkbox, disabled automatic activation before consent, History, and initial setup rendered correctly. The chosen Desktop bookmark resolved after replacing and reopening the app. Automatic naming remained disabled, and no existing Desktop file was renamed. Open at Login was left off.

## Practical limits and remaining user checks

- Validation was performed on this Mac, not on a separate macOS 13 machine. The deployment target and API availability are checked by compilation.
- Actual login-session relaunch has not been tested because Open at Login was intentionally left off. The app uses Apple's `SMAppService.mainApp` mechanism; enable it only when desired.
- English macOS screenshot names are supported in this first release. Customized or localized default filenames are conservatively excluded.
- Pause and shutdown invalidate outstanding work before rename and cancel the local child process; already submitted images cannot be recalled. The child-process cancellation is tested, while active Desktop capture/pause/wake behavior remains a user acceptance check after enabling.
- Destination no-overwrite is atomic. macOS does not provide a source-inode-conditioned rename; the implementation rechecks identity and content immediately before and after rename and attempts exclusive rollback on a race. Another process mutating the same file at the exact system-call boundary cannot be excluded absolutely.
- Model naming quality and privacy instructions were validated on generated examples, not on the user's private screenshots. Review the preview before enabling future Desktop capture processing.

## References

- [Apple File System Events](https://developer.apple.com/documentation/coreservices/file_system_events)
- [Apple login-item registration](https://developer.apple.com/documentation/servicemanagement/smappservice/register())
- [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode)
