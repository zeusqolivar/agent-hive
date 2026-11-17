# Porting Agent Hive to Windows

Status: plan, 2026-11-17. Nothing here is built yet.

## Goal

A Windows 11 app that does what the Mac app does for the agents running **on that PC**:

- the session board, Classroom, Terminal, Activity, Usage, Skills, Connectors and System views
- a tray icon with a usage panel
- keep-awake
- start at login
- API keys for usage services
- replying to sessions that aren't running

Agent Hive reads local files, so the Windows app shows the PC's agents, not the Mac's. Seeing one machine's agents
from another is a separate feature (see [Later](#later)).

## What carries over and what doesn't

The code splits into three parts:

| Part | Size | On Windows |
|---|---|---|
| Pages: `Sources/HiveApp/Resources/web` (HTML, CSS, JavaScript) | ~180 KB | Reused unchanged. They only call `/api/...` paths. |
| `Sources/HiveCore`: readers, board, usage, limits, connectors, API | ~6,600 lines of Swift, 48 files import only Foundation | Builds with Swift on Windows after a small platform layer (below). The 222 tests come along. |
| `Sources/HiveApp`: SwiftUI window, menu bar panel, Settings, WKWebView, `hive://` handler | ~1,000 lines | Replaced by a Windows shell. |

### Mac-only pieces in HiveCore, and their Windows replacements

| Today (file) | Mac API | Windows replacement |
|---|---|---|
| `Processes/ProcessTable.swift` (`PSProcessSource`) | `/bin/ps -Ao pid,ppid,etime,rss,pcpu,command` | `CreateToolhelp32Snapshot` for pid and parent; `NtQueryInformationProcess(ProcessCommandLineInformation)` for the command line; `GetProcessTimes` deltas for CPU %; `GetProcessMemoryInfo` for memory. All from Swift's `WinSDK` module, behind the existing `ProcessSource` protocol. |
| `Sessions/SessionReader.swift` | `kill(pid, 0)` to check a pid is alive | `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` + `GetExitCodeProcess == STILL_ACTIVE` |
| `Limits/KeyStore.swift` (`KeychainKeyStore`) | Keychain (`Security`) | Windows Credential Manager (`CredWriteW`/`CredReadW`/`CredDeleteW`), target `AgentHive/usage/<service>`. Encrypted per user by Windows. Same `KeyStore` protocol. |
| `System/ReadonlyDatabase.swift`, `Antigravity/AntigravityReader.swift`, `System/OpenClawReader.swift` | system `SQLite3` module | A `CSQLite` package target with the SQLite amalgamation, used only on Windows (`#if os(Windows)`); macOS keeps the system library. |
| `Classroom/ClassroomStore.swift` and other atomic writes | `rename(2)` over an existing file | `MoveFileExW(MOVEFILE_REPLACE_EXISTING \| MOVEFILE_WRITE_THROUGH)`, or `FileManager.replaceItemAt`. `rename` fails on Windows when the target exists. |
| `Support/Subprocess.swift`, `Skills/SkillsJobs.swift`, `Reply/ReplySender.swift` | `kill(SIGKILL)`; tool lookup in `~/.local/bin`, `/opt/homebrew/bin`; `:`-separated `PATH` | `Process.terminate()`; lookup in `PATH` split on `;`, trying `.exe`, `.cmd`, `.bat` (npm installs `claude.cmd`), plus `%USERPROFILE%\.local\bin` and `%APPDATA%\npm`. |
| `Antigravity/AntigravityOpener.swift` | `open -a Antigravity`, `osascript` | `ShellExecuteW` on `Antigravity.exe` with the folder; bring its window forward with `SetForegroundWindow`. |
| `System/SystemReport.swift`, `Board/MacSummary.swift` | process patterns with Mac paths (`claude.app/Contents/MacOS`, `/Applications/Antigravity.app/...`) | A second pattern list for Windows executables (`claude.exe`, `Claude.exe`, `Antigravity.exe`, `language_server_windows_x64.exe`, `node.exe ... @anthropic-ai/claude-code`). To confirm on a real PC. |
| `HivePaths.swift` | Mac folders | `HivePaths.windows(home:)`; see [File locations](#file-locations). |
| Claude status line (`statusline.sh`, `StatusLineInstaller`) | `sh` script using `/usr/bin/plutil` | `statusline.ps1` using `ConvertFrom-Json`, set as `powershell -NoProfile -ExecutionPolicy Bypass -File "<path>"` with forward slashes in `settings.json`. See [Risks](#risks). |

Everything else in HiveCore (transcripts, subagents, usage counting, connectors, providers, the HTTP client, JSON)
is plain Foundation.

### File locations

| What | macOS | Windows | Confidence |
|---|---|---|---|
| Claude Code sessions, projects, settings, plugins | `~/.claude/...` | `%USERPROFILE%\.claude\...` | Confirmed (Claude Code docs) |
| Claude Code main config | `~/.claude.json` | `%USERPROFILE%\.claude.json` | Likely; check |
| Project folder names | `-Users-me-proj` | Drive letter and backslashes encoded (for example `C--Users-me-proj`) | Check, and update any code that turns folder names back into paths |
| Background task output | `/private/tmp/claude-<uid>/...` | Under `%TEMP%` | Unknown; find on a real PC |
| Claude desktop app MCP config | `~/Library/Application Support/Claude/claude_desktop_config.json` | `%APPDATA%\Claude\claude_desktop_config.json` | Confirmed (MCP docs) |
| Codex | `~/.codex` (`sessions/YYYY/MM/DD/rollout-*.jsonl`, `config.toml`) | `%USERPROFILE%\.codex`; the Store app may use `%LOCALAPPDATA%\OpenAI\CodexAppHome`. Honour `CODEX_HOME`. | Confirmed for the CLI; the app path is reported, not documented |
| Antigravity data and MCP configs | `~/.gemini/antigravity`, `~/.gemini/antigravity-ide` | `%USERPROFILE%\.gemini\...` | Likely; check |
| Antigravity app | `/Applications/Antigravity.app` | `%LOCALAPPDATA%\Programs\Antigravity` | Guess; check |
| Antigravity DevTools port | `~/Library/Application Support/Antigravity/DevToolsActivePort` | `%APPDATA%\Antigravity\DevToolsActivePort` | Guess; check |
| Cursor MCP | `~/.cursor/mcp.json` | `%USERPROFILE%\.cursor\mcp.json` | Likely |
| OpenClaw | `~/.openclaw`, Homebrew package | `%USERPROFILE%\.openclaw`, `%APPDATA%\npm\node_modules\openclaw` | Guess |
| Agent Hive's own files | `~/Library/Application Support/Agent Hive` | `%APPDATA%\Agent Hive` | Our choice |

Phase 0 replaces every "check" and "guess" here with what a real PC shows.

## Approaches

| | A. Swift core + Tauri shell (recommended) | B. All Swift, native Windows UI | C. Rewrite in TypeScript or Rust |
|---|---|---|---|
| How | HiveCore runs as a small headless helper (`hive-core.exe`). A Tauri app shows the existing pages in WebView2, and owns the tray, keep-awake, login item and installer. | swift-winrt/WinUI bindings for windows, WebView2 through COM, Win32 for the tray. | Port HiveCore's ~6,600 lines and tests to the shell's language. |
| Reuses | All pages, all of HiveCore, all tests | All pages, all of HiveCore | Pages only |
| Risk | Low: each half uses mature tools | High: the Swift WinRT bindings are young, and WebView2 and tray icons from Swift need hand-written interop | Medium: two implementations to keep in step, or the Mac app moves too |
| Installer size | ~10–15 MB | ~30–40 MB (Swift runtime) | ~10 MB (Tauri) or 100+ MB (Electron) |

**Recommendation: A.** The parts that took the longest to get right stay one shared codebase: the session and
"needs you" rules, transcript parsing, limits, connectors and their privacy filtering. The Windows-only work is a
thin shell, and Tauri already provides the tray, autostart, custom protocols, a bundled helper binary and MSI/NSIS
installers.

### How A fits together

```
 ┌───────────────────────── Tauri app (Rust, ~1–2k lines) ─────────────────────────┐
 │  WebView2 window: the existing pages, loaded from hive://app/                    │
 │  Tray icon + popup: panel.html (a web version of the Mac menu bar panel)          │
 │  Keep-awake: SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)          │
 │  Start at login: Tauri autostart plugin (HKCU\...\Run)                            │
 │  hive://app/api/*  ──►  forwards the request to hive-core over stdin/stdout       │
 └──────────────────────────────────────┬──────────────────────────────────────────┘
                                        │ one JSON line per request and per answer
 ┌──────────────────────────────────────▼──────────────────────────────────────────┐
 │  hive-core.exe (Swift): HiveCore + a 100-line stdio loop around                 │
 │  HiveAPI.handle(method:path:body:), with the board, usage and limits refreshing │
 │  in the background exactly as Services does on the Mac                           │
 └─────────────────────────────────────────────────────────────────────────────────┘
```

- **No open port:** requests travel over the helper's stdin and stdout, as the README promises for the Mac app.
- **Settings and the menu bar panel** are SwiftUI on the Mac. On Windows they become two pages, `settings.html`
  and `panel.html`, fed by the same `/api/limits`, `/api/board` and a few small endpoints. The Mac app could later
  use the same pages.
- **Keys:** a key typed into the Windows settings page goes straight to the helper, which saves it in Credential
  Manager. It's never sent back to any page, logged or written to a file.

## Phases

Step-by-step guides for each phase, written for the agent or developer doing the work, are in
[docs/windows/](windows/README.md).

Estimates assume one developer and a Windows PC to test on. Phase 0 will firm them up.

| Phase | Work | Done when | Estimate |
|---|---|---|---|
| 0. Spike | Install Swift for Windows and Visual Studio Build Tools. Build HiveCore; list every compile error. Run Claude Code, Codex and Antigravity on the PC and record their real folders and process names. | A list of failures and a corrected [File locations](#file-locations) table | 1–2 days |
| 1. Portable core | Add the platform layer: `HivePaths.windows`, `WindowsProcessSource`, `CredentialManagerKeyStore`, the `CSQLite` target, atomic replace, tool lookup, Windows process patterns. Keep each Windows path behind `#if os(Windows)` or an injected protocol, so macOS behaviour doesn't change. Add Windows fixtures for process lists and paths. | `swift test` passes on macOS and Windows; GitHub Actions runs both | 4–6 days |
| 2. Helper | `hive-core` executable target: the stdio request loop, background refresh, a clean exit when stdin closes, and a `--dump` option like the Mac app's. | `hive-core --dump /api/board` prints the PC's real sessions | 1–2 days |
| 3. Shell | Tauri app: window, `hive://` protocol forwarding, tray icon with `panel.html`, keep-awake modes (off, while working, always, 1 hour), autostart, single instance, a dark and light theme that follows Windows. | The app runs from source and every view works with real data | 5–7 days |
| 4. Windows features | `settings.html` (keys, status line, keep-awake, login); the PowerShell status line installer and remover; replying with `claude.cmd --resume`; Open in Antigravity. | Each feature checked by hand on the PC | 3–4 days |
| 5. Packaging | NSIS installer and portable zip from GitHub Actions; app icon (`.ico` from `scripts/make_icon.swift`); Authenticode signing, without which SmartScreen warns on first run; a winget manifest. README sections for Windows. | A release with a Windows download next to the Mac one | 2–3 days |

Total: roughly 3–4 weeks of focused work.

## Risks

- **Claude plan limits on Windows.** Claude Code passes limits only to status line commands, and several Windows
  reports describe status lines not running or not rendering on native Windows, depending on the version. Agent
  Hive's script only saves the data, so a failure to render is harmless, but a failure to run means no Claude limits.
  Test on the current Claude Code version. If it doesn't run, show the card as unavailable with the reason, as for
  Antigravity.
- **Process command lines.** Reading another process's command line needs `PROCESS_QUERY_LIMITED_INFORMATION`.
  Elevated processes may refuse, so those sessions show without their command. The board must cope with that.
- **Antivirus and SmartScreen.** An unsigned helper that lists processes and reads other apps' folders may be
  flagged. Signing (phase 5) is needed for a smooth install.
- **Path assumptions.** Code that builds paths with `/` or splits on `:` (drive letters contain `:`) needs a sweep.
  Use `URL` and `FileManager` throughout.
- **Swift on Windows build setup.** It needs Visual Studio Build Tools and the Windows SDK. Pin the toolchain version
  in CI.

## Not in the first version

- The Classroom editor's file export and import dialogs use the browser's download and file picker. These work in
  WebView2, so nothing is needed unless testing shows otherwise.
- ARM64 Windows. x64 first; Tauri and Swift both support ARM64 later.

## Later

- **See another machine's agents.** For example, the Mac's agents on the PC. This needs an opt-in, authenticated
  read-only feed from one Agent Hive to another (over Tailscale or the local network, with a pairing code). It's a
  separate design: it would send session data off the machine, which today never happens.
- **One shell for both platforms.** If the Tauri shell works well, the Mac app could use it too, leaving one UI
  codebase. Not needed for the port.

## Sources

- Claude Code status line settings: https://code.claude.com/docs/en/statusline
- Codex on Windows (Codex home `%USERPROFILE%\.codex`, `CODEX_HOME`): https://developers.openai.com/codex/app/windows
- Reported Codex Store app location: https://arte.itlibra.com/en/articles/codex-windows-storage-migration
- Codex rollout file layout: https://codex.danielvaughan.com/2026/04/11/codex-cli-session-lifecycle-resume-fork-rollouts
- Windows status line issues: https://claudeissues.com/issue/93635-status-line-configured-in-settings-json-is-never-executed-rendered-on-native-win
  and https://claudeissues.com/issue/68452-bug-windows-paths-with-backslashes-in-settings-json-statusline-command-are-doubl
- Swift WinRT bindings (approach B): https://github.com/thebrowsercompany/swift-winrt and
  https://github.com/thebrowsercompany/swift-windowsappsdk
