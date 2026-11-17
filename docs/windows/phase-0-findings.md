# Phase 0: what breaks on Windows

Findings from a spike on a Windows 11 PC, 2026-11-17. Everything below was measured, not assumed. Paths use
`<user>` instead of the real account name, and no fixture, transcript or process list from the PC is copied here.

Result in one line: **HiveCore builds on Windows** after a small set of Foundation-only changes, and the test
suite runs. The Windows-only work that is left is behaviour (processes, keys, status line), not compilation.

## 1. Versions

| What | Version |
|---|---|
| Windows | 11 Pro, 10.0.26300 (x64) |
| Swift | 6.4.2 (`swift-6.4.2-RELEASE`), target `x86_64-unknown-windows-msvc`, `+assertions` |
| Toolchain install | `winget install --id Swift.Toolchain` → user scope, `%LOCALAPPDATA%\Programs\Swift` (no admin) |
| Visual Studio | Build Tools 2022, 17.14.37906.3 (`Microsoft.VisualStudio.Workload.VCTools`) |
| MSVC | 14.44.35207 |
| Windows SDK | 10.0.26100.0 |
| Claude Code (CLI on `PATH`) | 2.1.289 |
| Claude Code (bundled with the desktop app) | 2.1.325 |
| Claude desktop app | MSIX (Store) 5.11492.5.0 |
| Antigravity | app `version` file says 44.9.1; its language server reports `--override_ide_version 2.32.1` |
| Codex | not installed |
| Cursor | not installed |

The toolchain does not put itself on `PATH`. Every command needs the MSVC environment first, so the spike used a
two-line wrapper: `call vcvars64.bat`, then prepend
`%LOCALAPPDATA%\Programs\Swift\Toolchains\6.4.2+Asserts\usr\bin` and `%LOCALAPPDATA%\Programs\Swift\Runtimes\6.4.2\usr\bin`
to `PATH` and set `SDKROOT` to
`%LOCALAPPDATA%\Programs\Swift\Platforms\6.4.2\Windows.platform\Developer\SDKs\Windows.sdk`.
`swift build` and `swift test` then work from that shell as on macOS. CI must do the same, or use the
`compnerd/gha-setup-swift` action, which sets it up already.

`swift build --target HiveCore` accepts the current `Package.swift` unchanged, including
`platforms: [.macOS(.v15)]` and the `HiveApp` target. `swift test` does not: it builds every target, so the Mac app's
SwiftUI sources fail on Windows. For the spike, a local uncommitted `Package.swift` dropped the `HiveApp` product and
target; phase 1 does this properly.

## 2. Build errors

The compiler stops at the first failing import per compiles, so this list was collected by fixing each error and
building again. The order is the order they appear. Each fix was applied and the next build confirmed it.

| # | File:line | API | Suggested fix |
|---|---|---|---|
| 1 | `Antigravity/AntigravityReader.swift:2`, `System/ReadonlyDatabase.swift:2`, `System/OpenClawReader.swift:2` | `import SQLite3` — no such module | Add the `CSQLite` C target with the amalgamation (3.54.1) and `#if canImport(SQLite3) … #else import CSQLite`. Verified: the build advances. |
| 2 | `Limits/KeyStore.swift:2` | `import Security` — no such module | Put the import and `KeychainKeyStore` behind `#if canImport(Security)`. Verified. |
| 3 | `Limits/KeyStore.swift:23` (and `:20`) | `OSStatus` is not in scope on Windows, so `KeyStoreError` also loses `Equatable` | Guard the `.keychain(OSStatus)` case too, and add `.system(Int)` for Windows error codes. |
| 4 | `Limits/HTTP.swift:11, 23, 37, 38, 39`, `Antigravity/AntigravityOpener.swift:123, 124` | `'URLSession' is unavailable: This type has moved to the FoundationNetworking module`, likewise `URLRequest`, `URLSessionConfiguration`, `URLSessionTaskDelegate` | **Not in the plan.** Add `#if canImport(FoundationNetworking) import FoundationNetworking #endif` to every file that touches the network. Verified: all five errors go away. |
| 5 | `Antigravity/AntigravityOpener.swift:123` | `static property 'session' is not concurrency-safe because non-'Sendable' type 'URLSession'` | On Windows the type is `AnyObject`, not `Sendable`. `nonisolated(unsafe) static let session`. Verified. |
| 6 | `Board/Board.swift:134, 135` | `cannot find 'utsname' / 'uname' in scope` | Windows has no `uname`. Use `ProcessInfo.processInfo.environment["COMPUTERNAME"]`. Verified. |
| 7 | `Board/MacSummary.swift:43` | `getloadavg` is not available | Windows has no load average; return 0, or compute busy time from `GetSystemTimes`. |
| 8 | `Support/Subprocess.swift:37`, `Sessions/SessionReader.swift:67`, `Skills/SkillsJobs.swift:149` | `kill` is not available | `process.terminate()` where a `Process` exists; `pidAlive` gets an `OpenProcess` + `GetExitCodeProcess` implementation. |
| 9 | `Skills/SkillsJobs.swift:77` | `reference to captured var 'steps' in concurrently-executing code` | Not a Windows problem: Swift 6.4 rejects it. Copy the value into a `let` before the `Thread` closure. Check which Swift version the Mac CI uses. |
| 10 | `HivePaths.swift:104` | `getuid` is not available | `HivePaths.windows(home:)` with `uid = 0`, behind `#if os(Windows)`. Verified. |

That is 10 error groups across 12 files. The patch that made the build succeed was about 120 lines, most of them the
new `HivePaths.windows(home:appData:localAppData:temp:environment:)` initialiser. It lives in a scratch copy
(`C:\src\spike`), not in the repository: phase 1 redoes it with tests and doc comments.

`HivePaths.windows` as validated by the spike fills every property from the table in section 4, including
`CODEX_HOME`, `%TEMP%\claude` for `tasksRoot`, `%APPDATA%\Agent Hive` for `supportFolder`, and
`%APPDATA%\Antigravity\DevToolsActivePort`.

Also worth knowing: SwiftPM warns `unable to create symbolic link at .build\debug: I/O error (code: 512)` on every
build. Creating the symlink needs Developer Mode or elevation. The build succeeds and `.build\<triple>\debug` holds the
products, but anything that assumes `.build/debug` exists will not find it.

## 3. Test results

With the fixes above and the `HiveApp` target removed, `swift test` builds and runs:

> `Test run with 220 tests in 35 suites failed after 5.4 seconds with 26 issues.`

220 of 222 tests run; the two Keychain round-trip tests are behind `#if canImport(Security)` (they also needed
`KeychainKeyStore`, which does not exist on Windows). 22 tests fail, in four groups:

| Cause | Tests | Detail |
|---|---|---|
| `/bin/ps` | `realPsListsThisProcess`, `pidAlive`, `alivePidMissingFromTheProcessListStillCounts`, `listsEveryAgentInOrder`, `boardRowsMatchServer`, `listMatchesServer`, `viewsMatchServer`, `connectorsRoute`, `liveReportMatchesServer`, `liveRowWithGroupAndHeadline`, `reportMatchesServer`, `otherAgents` | `PSProcessSource` runs `/bin/ps`, which does not exist. These pass once `WindowsProcessSource` replaces it; they are the phase 1 acceptance test. |
| Shell-script status line | `scriptSavesLimitsAndRunsThePreviousCommand`, `scriptWithoutPreviousCommandPrintsNothing`, `installWithoutSettingsFileAndRemove` | The tests run `statusline.sh` with `sh`. Need the PowerShell equivalent, and a Windows branch in the installer's tests. |
| `Bundle.module` fixture copies | `missingOrMalformedFilesAreSkipped`, `frontMatter`, `findsLiveClaudeSessionsOnly`, `icnsHoldsEverySize` | `Fixture.prepare` copies `root.appending(path: name)` and gets "file doesn't exist", and the `.icns` fixture is Mac-only. Phase 1 needs a Windows fixture home and a platform-neutral copy. |
| Symlinks | `symlinkedSettingsStayALink` | Creating symlinks needs Developer Mode or elevation; on Windows the test should skip or use a junction. |

Two of the failures (`frontMatter`, `findsLiveClaudeSessionsOnly`) still failed after the spike's own test-side fixes, so
the count above is what a phase 1 that does this properly should expect to start from. The point stands: **nothing in
the suite fails for a reason that touches the Windows port's design.**

## 4. File locations

Confirmed on the PC. "Confirmed" means the path exists and was read; "not present" means the tool is not installed.

| What | Path on Windows | Status |
|---|---|---|
| Claude Code sessions | `%USERPROFILE%\.claude\sessions\` | **confirmed.** One `<pid>.json` per session, plus a `<pid>.<64 hex>.key` file next to it. |
| Session record fields | `<pid>.json` | **confirmed.** Top-level keys: `pid`, `sessionId`, `cwd`, `startedAt`, `procStart`, `version`, `peerProtocol`, `peerFeatures`, `kind`, `entrypoint`, `hostSessionId`, `pidDomain`, `asksForConvertedSkills`, `messagingSocketPath`, `name`, `nameSince`, `updatedAt`, `status`, `statusUpdatedAt`, `bridgeSessionId`. The `<pid>` in the file name is the `claude.exe` pid (checked against the process table). |
| Projects | `%USERPROFILE%\.claude\projects\` | **confirmed.** `C:\Users\me\proj` becomes `C--Users-me-proj`: the drive colon **and** each backslash become `-`. `D:/Projects` is `D--Projects`; a path with hyphens keeps them. |
| Claude Code config | `%USERPROFILE%\.claude.json` | **confirmed.** Top-level keys include `mcpServers`, `projects`, `oauthAccount`, `installMethod`. |
| Claude Code settings | `%USERPROFILE%\.claude\settings.json` | **confirmed.** No `statusLine` key by default. |
| Background task output | `%TEMP%\claude\<16 hex>\<session uuid>\tasks\<id>.output` | **confirmed** (a `scratchpad` folder sits beside `tasks`). `%TEMP%` here is `%LOCALAPPDATA%\Temp`. Not `claude-<uid>` as on the Mac: there is no uid, so `tasksRoot` becomes `%TEMP%\claude`. |
| Claude desktop app | MSIX package `Claude_5.11492.5.0_x64__<hash>` in `C:\Program Files\WindowsApps\`, executable `…\app\Claude.exe`, process name `claude.exe` | **confirmed.** Its `claude://` scheme does **not** work: `URL Protocol` is registered under `HKCR\claude` and `HKCU\Software\Classes\claude`, but there is no `shell\open\command`, and `AssocQueryString(claude, EXECUTABLE)` returns `0x80070483` (no association). |
| Claude desktop MCP config | `%APPDATA%\Claude\claude_desktop_config.json` | **confirmed** (the file exists; the app keeps its data under `%LOCALAPPDATA%\Claude-Data\claude_<id>`). |
| Codex | `%USERPROFILE%\.codex`, `%LOCALAPPDATA%\OpenAI\CodexAppHome` | **not present**, and `CODEX_HOME` is unset. Keep the reader, but this PC cannot confirm the layout. |
| Antigravity data | `%USERPROFILE%\.gemini\antigravity\` | **confirmed.** `conversation_summaries.db`, `brain\<id>\`, `daemon\hub_<pid>.json`, `mcp\`, `annotations\`, `conversations\`, `log\`. A hub file's keys: `pid`, `httpsPort`, `httpPort`, `lsVersion`, `csrfToken`. |
| Antigravity MCP configs | `%USERPROFILE%\.gemini\antigravity\mcp_config.json` | **not present** on this PC, but `%USERPROFILE%\.gemini\antigravity-ide\mcp_config.json` and `%USERPROFILE%\.gemini\config\mcp_config.json` are. Keep all three rows; the first is simply missing here. |
| Antigravity app | `%LOCALAPPDATA%\Programs\antigravity\` (lower-case `antigravity`), exe `Antigravity.exe` | **confirmed.** Note `%LOCALAPPDATA%\Programs\Antigravity IDE` also exists; the running one is the lower-case folder. |
| Antigravity DevTools port | `%APPDATA%\Antigravity\DevToolsActivePort` | **confirmed.** First line is the port, second the `/devtools/browser/<uuid>` path. The guess in the overview was right. |
| Cursor MCP | `%USERPROFILE%\.cursor\mcp.json` | **not present.** |
| OpenClaw | `%USERPROFILE%\.openclaw`, `%APPDATA%\npm\node_modules\openclaw` | **not present**; there is no `%APPDATA%\npm` at all. |
| `claude` command | `%USERPROFILE%\.local\bin\claude.exe` | **confirmed.** Native installer, not npm: no `claude.cmd`, no `%APPDATA%\npm`. Tool lookup must not assume `.cmd`, but should still try it for other people's PCs. |

## 5. Processes

`Get-CimInstance Win32_Process` on this PC, with paths reduced to placeholders:

| Agent | Executable | Command line shape |
|---|---|---|
| Claude Code session | `claude.exe` | `C:\Users\<user>\AppData\Local\Claude-Data\claude_<id>\claude-code\<version>\<hash>\claude.exe --output-format stream-json --verbose --input-format …` |
| Claude Code CLI | `claude.exe` | `C:\Users\<user>\.local\bin\claude.exe` — same name, different path, **different version** (see section 8) |
| Claude desktop app | `Claude.exe` (reported as `claude.exe`) | `"C:\Program Files\WindowsApps\Claude_<version>_x64__<hash>\app\Claude.exe"`, children `--type=renderer`, `--type=gpu-process`, `--type=crashpad-handler`, `--type=utility --utility-sub-type=node.mojom.NodeService` |
| Antigravity | `Antigravity.exe` | `"C:\Users\<user>\AppData\Local\Programs\antigravity\Antigravity.exe" --updated`, children `--type=renderer`, `--type=gpu-process`, `--type=utility` |
| Antigravity language server | `language_server.exe` | `…\antigravity\resources\bin\language_server.exe --standalone --override_ide_name antigravity --subclient_type hub --override_ide_version <v> --https_server_port 0 --csrf_token <token> --app_data_dir antigravity --host_bridge_url=http://127.0.0.1:<port> --host_bridge_token <token>` |
| Other `node.exe` | `node.exe` | Unrelated tools run node too (e.g. a Stream Deck helper). Any pattern that matches bare `node.exe` will false-positive. Both `claude.exe` paths above are better identifiers. |

Parent/child: the desktop app's main `Claude.exe` spawns several chromium-style `claude.exe` help carriers and a
`claude.exe` session process; session `<pid>.json` matches the **session** process, not the app. Antigravity's
`language_server.exe` is a child of `Antigravity.exe`, and the `daemon\hub_<pid>.json` pid is the language server's.

## 6. Command-line access without elevation

Works. Running as the normal user, `(Get-CimInstance Win32_Process -Filter "Name='claude.exe'").CommandLine` returned
full command lines for every same-user process, and the equivalent `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` +
`NtQueryInformationProcess(ProcessCommandLineInformation)` path is the same permission. Expect denial for elevated or
protected processes only, as the overview predicted; `WindowsProcessSource` should fall back to the exe name exactly as
planned.

## 7. Status line

**Runs on Windows.** With `statusLine` set to
`powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/<user>/hive-statusline-test.ps1` (forward slashes) in
`%USERPROFILE%\.claude\settings.json`, Claude Code 2.1.289 started in a terminal ran the command, and its output
appeared in the rendered status line. `settings.json` was restored byte for byte afterwards and the test files deleted.

The JSON the script received had these top-level keys: `context_window`, `cost`, `cwd`, `effort`,
`exceeds_200k_tokens`, `fast_mode`, `model`, `output_style`, `session_id`, `thinking`, `transcript_path`, `version`,
`workspace`. **No `rate_limits`**, because that terminal session was not signed in: `claude auth status --json` reported
`loggedIn: false, authMethod: none`. The status line's own execution is therefore confirmed; presence of
`rate_limits` could not be confirmed on this PC without a signed-in terminal session, and it is the one item to retest
on a signed-in PC before phase 4's Claude card is decided.

## 8. Surprises

1. **`FoundationNetworking`.** The plan does not mention it: on Windows `URLSession`, `URLRequest`,
   `URLSessionConfiguration` and `URLSessionTaskDelegate` live in a separate module. Two files need the conditional
   import, and `URLSession` is not `Sendable` there. This is the largest unplanned compile difference.
2. **HiveCore compiles with Foundation-only fixes.** No `WinSDK`, no `WindowsProcessSource` and no C shim are needed
   to *build*; they are needed for the app to *work*. The CSQLite target is the only new C code.
3. **`claude://` is not registered as a handler** on this PC, even though the desktop app is installed and the
   protocol key exists. Phase 2's `WindowsActions.open(hostSessionId:)` must return false, and phase 4 should hide
   **Open in Claude** using a `capabilities` field rather than claiming to support it.
4. **Two Claude Code versions in one PC.** `claude.exe` on `PATH` (2.1.289, `~\.local\bin`) is not signed in, while the
   desktop app's managed copy (2.1.325, under `%LOCALAPPDATA%\Claude-Data\…`) runs the live sessions. `ReplySender`
   checks `claude auth status --json` before replying, so on this PC it would refuse even though the sessions exist.
   Phase 4 should resolve `claude` next to the session's own executable first, or let the user point at one.
5. **`getppid` and `uname` are missing too**, not just `kill`, `getuid`, `getloadavg` and the Keychain. Any test or
   reader that asks the OS who it is needs a Windows branch.
6. **Swift 6.4 rejects `SkillsJobs.swift:77`** (captured `var` in `Thread.detachNewThread`). That error is not
   Windows-specific; it is the toolchain being newer than the Mac's. Worth aligning the Mac and CI toolchains before
   phase 1, so "it builds on Windows" and "it builds on macOS" mean the same Swift.
7. **No Codex, Cursor or OpenClaw on this PC.** Their readers cannot be validated here; phase 1 should ship them
   untested-on-Windows with the documented paths, and say so.
8. **SwiftPM's `.build\debug` symlink** fails without Developer Mode. Harmless for `swift build`, worth knowing before
   debugging a CI script that expects it.

## Done when

- [x] `phase-0-findings.md` exists and every "check"/"guess" in the overview's file table is resolved.
- [x] Every HiveCore build error is listed with a suggested fix, and the fixes were applied far enough that HiveCore
      builds and the tests run (results in section 3).
- [x] No real personal paths, names or transcript text in this file.
- [x] `settings.json` on the test PC is restored.
