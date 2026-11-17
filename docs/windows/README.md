# Windows port: phase guides

These guides are written for an agent or developer doing the work. The design and the reasons for it are in
[../windows-port.md](../windows-port.md); read it first.

| Phase | Guide | Needs a Windows PC | Output |
|---|---|---|---|
| 0 | [Spike: find out what breaks](phase-0-spike.md) | Yes | `docs/windows/phase-0-findings.md` |
| 1 | [Make HiveCore build and pass tests on Windows](phase-1-portable-core.md) | Yes, plus a Mac to keep macOS green | HiveCore and its tests on both systems, CI for both |
| 2 | [The `hive-core` helper](phase-2-helper.md) | Yes | `hive-core.exe` answering the API over stdin/stdout |
| 3 | [The Tauri shell](phase-3-shell.md) | Yes | A Windows app showing every view with real data |
| 4 | [Windows features: settings, status line, replies, actions](phase-4-features.md) | Yes | Feature parity with the Mac app |
| 5 | [Packaging and release](phase-5-packaging.md) | Yes (plus CI) | An installer on the GitHub release |

Do the phases in order; each one starts from the previous one's result.

## Rules for every phase

- **Branch.** Work on a branch named `windows-port` (or `windows-port-phase-N`), never on `main`. Open a pull
  request at the end of each phase; don't merge it yourself.
- **macOS must not change.** The Mac app is released and used daily. Every Windows change goes behind
  `#if os(Windows)`, a new type behind an existing protocol, or a new target. After each phase, on a Mac, run:

  ```bash
  swift test
  scripts/bundle.sh release
  ```

  Both must pass, and the Mac app must behave as before.
- **Privacy is the product's promise.** Agent Hive reads local files and never reads other tools' logins or tokens.
  Keep it that way on Windows:
  - Don't open Claude's, Codex's or Antigravity's credential files.
  - Don't read browser cookies.
  - Don't send anything over the network except to the usage services a user added a key for.
  - Fixtures must be made up: no real names, paths, transcripts or process lists from anyone's PC.
- **Style.** Match the existing code: small types behind protocols, doc comments that say what and why in plain
  words, and tests next to the behaviour. User-facing text is plain, sentence case, and says what to do.
- **Commits.** Clear messages that say what changed and why. **No AI-attribution lines**: no `Co-Authored-By`
  trailers, no "Generated with …", in commits, PR descriptions or code comments.
- **Verify, don't assume.** Several Windows facts in the overview are marked "check" or "guess". Phase 0 settles
  them; later phases use `phase-0-findings.md`, not the overview, when the two disagree.

## Where things are today

| Path | What |
|---|---|
| `Package.swift` | SwiftPM: `HiveCore` library, `HiveApp` executable, `HiveCoreTests` |
| `Sources/HiveCore/HivePaths.swift` | Every folder and file the app reads |
| `Sources/HiveCore/API/HiveAPI.swift` | `HiveAPI.handle(method:path:body:) async -> Response` answers every `/api/...` path and serves the pages; `ActionHandler` and `ReplyHandler` protocols |
| `Sources/HiveCore/Processes/ProcessTable.swift` | `ProcessSource` protocol, `PSProcessSource` (`/bin/ps`) |
| `Sources/HiveCore/Limits/KeyStore.swift` | `KeyStore` protocol, `KeychainKeyStore` |
| `Sources/HiveCore/Limits/StatusLine*.swift`, `PlanLimits.swift` | Claude status line installer and limits reader |
| `Sources/HiveApp/HiveApp.swift` | `Services` (wires the readers and starts the refresh loops), the SwiftUI scenes |
| `Sources/HiveApp/SchemeHandler.swift` | Serves `hive://app/...` to WKWebView through `HiveAPI` |
| `Sources/HiveApp/MenuBar.swift`, `SettingsView.swift`, `AppModel.swift` | Menu bar panel, Settings, app state (keep-awake, login item, keys) |
| `Sources/HiveApp/Resources/web/` | The pages: `index.html`, `room*.js`, and the others |
| `Tests/HiveCoreTests/` | Unit and contract tests; `Fixtures/home` is a made-up home folder |
