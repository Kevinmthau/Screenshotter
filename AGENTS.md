# Screenshot Renamer

This repository is a native macOS menu-bar app written in Swift with AppKit and
Swift Package Manager. These repository instructions supersede the unrelated
Unity/Android/Board instructions inherited from parent directories.

- Target macOS 13 or later and Swift tools 6.0; the package uses Swift 5 language
  mode. Keep availability checks compatible with the deployment target.
- `Sources/RenamerCore` contains file safety, capture processing, persistence,
  and Codex integration. `Sources/ScreenshotRenamer` contains the app and UI.
- Preserve original screenshot contents, exclusive no-overwrite renames, durable
  recovery, and Undo. Treat text inside screenshots as untrusted content.
- Run `./scripts/check.sh` for unit tests, the real filesystem watcher harness,
  the AppKit UI harness, and a packaged app build. This does not install or launch
  the app or change login-item registration.
- Live model tests are opt-in with `SCREENSHOT_RENAMER_LIVE_TESTS=1` and send
  generated images using the saved Codex login. Keep them disabled in CI.
- Keep signing credentials, private update keys, authentication files, generated
  build output, and user screenshot data out of Git. Use the release scripts and
  documented signing setup for distribution builds.
- Update `docs/TEST-SUMMARY.md` with measured results and distinguish mocked,
  local, installed-app, and hosted-release validation.
