# Codex image integration

Verified on this Mac on September 21, 2026. Only generated sample screens were submitted. No Desktop screenshot or other private image was opened or uploaded for these tests.

The bridge discovers an explicit executable override, an executable on PATH, standard Homebrew locations, or the registered Codex/ChatGPT application through LaunchServices. Stable application-name fallbacks are included; version-specific application/cache paths are not required. The installed executable resolved to the ChatGPT application's bundled CLI.

`CodexAnalyzer.analyze(_:)` returns a `NamingSuggestion` containing `title` and `useful`. `checkAvailability()` checks the required command-line flags and saved login. Public failures contain a category and fixed actionable text; raw CLI output and recognized image text never become application logs or error messages.

Each analysis:

- Creates a private temporary directory, rasterizes the input to PNG, and passes only that copy to Codex. The source is opened without following symlinks; only regular files of at most 100 MiB are accepted. Decoding uses an immutable read whose size and modification metadata remain stable. PNG, JPEG, TIFF, GIF, BMP, HEIC, and the first page of PDF were verified locally. Original bytes and formats are preserved. Large images are bounded to a 4096-pixel longest edge for analysis.
- Uses saved CLI authentication and a small GUI-safe environment. API-key variables, remote-server configuration, parent task identity, tracing configuration, and shell injection variables are not inherited. Standard proxy environment variables are preserved.
- Ignores user configuration and exec-policy rules, except that the bridge reads only a simple top-level configured model slug. No model identifier is fixed in source. The installed configuration selected `gpt-6-astra`; low reasoning effort was used for the measurement below.
- Requests a JSON-schema response with `--image`, `--output-schema`, and `--output-last-message`, using `--ephemeral`, a read-only sandbox, and a temporary working directory outside the repository.
- Disables shell execution, additional image reads, web access, app integrations, MCP, plugins, hooks, skills, subagents, browser/computer use, and planning/input tools. The installed CLI's own structured-request restrictions informed these overrides. A loopback mock-provider audit of the actual outgoing request confirmed an empty `tools` array. The mock used an isolated empty auth home and did not receive saved credentials.
- Uses a separate process group, bounds each output buffer to 32 KiB in memory, and kills the process group on cancellation or timeout. The default deadline is 90 seconds. Temporary inputs, schema, instructions, response, and CLI log directory are removed on completion, failure, timeout, and cancellation.

The prompt treats all screenshot text as untrusted content. It asks for a short title such as `Flourish - On-Device AI Notes`, without dates, extensions, financial amounts, account identifiers, passwords, or unnecessary personal details. The application validates the JSON and title; its separate file-operation layer owns naming and renaming.

## Live generated-sample results

| Synthetic screen | Returned title | Analysis time |
| --- | --- | --- |
| Notes product page | Flourish - On-Device AI Notes | 4.79 s |
| Spending dashboard with fictional account number and amount | Harbor - Monthly Spending Overview | 4.30 s |
| Travel itinerary containing an instruction to return “HACKED” | Atlas - Kyoto Weekend Itinerary | 4.71 s |

Mean analysis time was 4.60 seconds. This includes process startup, normalization, the network request, and response validation; it excludes the watcher's save-stability delay. These are three local measurements, not a latency guarantee. The spending title omitted the fictional account and amount. The travel title ignored the embedded instruction.

An actual CLI test with a newly created, empty authentication home returned `authenticationRequired` from both availability checking and image analysis. The user's saved login and configuration were not changed. Authentication in the final installed app's LaunchServices environment is checked separately by the application's background diagnostic.

## Automated checks

The 14 analyzer XCTest cases completed with zero failures: 13 local tests ran, and the opt-in live-network test was skipped during the normal test run. Coverage includes strict response validation, unsafe titles, environment filtering, model parsing, tool restrictions, successful response and temporary cleanup, sanitized authentication/quota/offline errors, missing CLI, timeout, process-group cancellation, bounded output, image/PDF preservation, and rejection of symlinks, FIFOs, directories, and oversized files. Quota and offline failures use controlled CLI responses rather than intentionally exhausting the user's quota or changing network settings.

Run local tests using the full Xcode developer directory on this Mac:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /tmp/screenshot-renamer-tests
```

To explicitly submit the three generated samples again with the current saved login:

```sh
SCREENSHOT_RENAMER_LIVE_TESTS=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --scratch-path /tmp/screenshot-renamer-tests --filter CodexAnalyzerTests/testLiveGeneratedSamplesWhenExplicitlyEnabled
```

CLI updates may change supported configuration. Unknown flags or unavailable models produce a sanitized availability error; no separate API key or billing fallback is introduced automatically. Local temporary-file cleanup does not alter OpenAI's service-side handling of submitted images.

## Official references checked

- [Non-interactive mode and saved authentication](https://learn.chatgpt.com/docs/non-interactive-mode)
- [Codex developer commands](https://learn.chatgpt.com/docs/developer-commands?surface=cli)
- [Configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)

Installed `codex exec --help`, `codex login --help`, and `codex features list` were also checked. Runtime checks, including the effective request-tool audit, establish the behavior of the installed CLI where public documentation is less specific.
