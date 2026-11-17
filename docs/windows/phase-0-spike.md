# Phase 0: spike, find out what breaks

**Goal:** facts instead of guesses. When this phase ends, we know exactly what fails to build on Windows, and where
Claude Code, Codex and Antigravity really keep their files and run their processes on a Windows PC.

**Needs:** a Windows 11 x64 PC with Claude Code installed and signed in. Codex and Antigravity too, if the owner
uses them there.

**Output:** `docs/windows/phase-0-findings.md`, committed on the `windows-port` branch. No product code changes.

## 1. Set up the toolchain

1. Install Visual Studio 2022 Build Tools with **Desktop development with C++** and a current **Windows 11 SDK**.
2. Install Swift for Windows. Follow https://www.swift.org/install/windows/ for the current command
   (`winget install --id Swift.Toolchain` at the time of writing). Use the newest Swift 6.x release, since the
   package uses `swift-tools-version: 6.0`.
3. Open a new **x64 Native Tools** command prompt or PowerShell and check:

   ```powershell
   swift --version
   ```

4. Install Git, and clone the repository on a short path to avoid path-length problems (for example
   `C:\src\agent-hive`).

Record the exact Swift, Visual Studio and SDK versions in the findings file.

## 2. Try to build HiveCore

`HiveApp` imports SwiftUI, AppKit and WebKit and can't build on Windows. Build only the library and its tests:

```powershell
swift build --target HiveCore 2>&1 | Tee-Object build-hivecore.txt
swift build --build-tests 2>&1 | Tee-Object build-tests.txt
```

If SwiftPM refuses because of the `HiveApp` target or the macOS platform line, make a **local, uncommitted** copy
of `Package.swift` that drops `HiveApp`, just for the spike. Don't commit it; phase 1 does this properly.

For every error, record:
- file and line
- the API involved (`Security`, `SQLite3`, `kill`, `getuid`, `rename`, `/bin/ps`, and so on)
- a one-line suggested fix

Group them by file. The overview's table "Mac-only pieces in HiveCore" lists what we expect; note anything that
isn't on it.

If HiveCore builds, run the tests and record which fail and why:

```powershell
swift test 2>&1 | Tee-Object test-results.txt
```

## 3. Map the agents' real files

With Claude Code running at least two sessions (one in Windows Terminal, one in the Claude desktop app if
installed), find and record each path below. Use `dir /a`, `Get-ChildItem -Force`, and `Get-ChildItem -Recurse`
on the folders. **Record paths and file names only**; don't copy file contents into the findings beyond the field
names listed.

| Item | What to record |
|---|---|
| `%USERPROFILE%\.claude\sessions\` | Does it exist? File naming (`<pid>.json`?). The field names in one file (not the values). |
| `%USERPROFILE%\.claude\projects\` | How a project folder is named for a path like `C:\src\demo` (exact encoding of the drive, `:` and `\`). |
| `%USERPROFILE%\.claude.json` | Exists? Top-level keys only (`mcpServers`, `projects`, …). |
| `%USERPROFILE%\.claude\settings.json` | Exists? |
| Claude Code background task output | Start a long command in Claude Code with `run_in_background`, then search `%TEMP%`, `%LOCALAPPDATA%` and `%USERPROFILE%\.claude` for a new `*.output` file. Record the folder pattern. |
| Claude desktop app | Install folder, process name(s), and whether `%APPDATA%\Claude\claude_desktop_config.json` exists. Does it register the `claude://` URL scheme? (`reg query HKCR\claude`) |
| Codex | `%USERPROFILE%\.codex` and/or `%LOCALAPPDATA%\OpenAI\CodexAppHome`; whether `CODEX_HOME` is set; the `sessions\YYYY\MM\DD\rollout-*.jsonl` layout; `config.toml` location. `codex doctor` output (paths only). |
| Antigravity | `%USERPROFILE%\.gemini\antigravity\` contents (file names: `conversation_summaries.db`, `brain\`, `daemon\hub_*.json`); MCP config files; install folder; `DevToolsActivePort` location; process names, including the language server. |
| Cursor | `%USERPROFILE%\.cursor\mcp.json` exists? |
| `claude` command | `where claude` and `Get-Command claude`: is it `claude.exe`, `claude.cmd` (npm) or both? Its folder. |

## 4. Map the processes

Agent Hive matches sessions to processes and shows CPU and memory. List the processes for each running agent:

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.Name -match 'claude|node|codex|antigravity|language_server|agy' } |
  Select-Object ProcessId, ParentProcessId, Name, CreationDate, CommandLine |
  Format-List
```

Record, with user names and project paths replaced by placeholders such as `<user>` and `<project>`:
- each executable name, and the shape of its command line (which arguments identify a Claude Code session, a
  `--resume <id>`, the Antigravity hub, and so on)
- which parent/child relationships matter: for example, is the session's `<pid>.json` pid the `node.exe` or a
  wrapper?

Then check whether a normal, non-elevated process can read another process's command line. Run this as the normal
user:

```powershell
(Get-CimInstance Win32_Process -Filter "Name='claude.exe'").CommandLine
```

## 5. Claude status line on Windows

Claude plan limits only reach Agent Hive through a status line command. Test whether it runs on this PC:

1. Back up `%USERPROFILE%\.claude\settings.json`.
2. Save this as `%USERPROFILE%\hive-statusline-test.ps1`:

   ```powershell
   $inputJson = [Console]::In.ReadToEnd()
   Set-Content -Path "$env:TEMP\hive-statusline-test.json" -Value $inputJson
   Write-Output "hive test"
   ```

3. Set the status line in `settings.json`, using forward slashes:

   ```json
   "statusLine": {"type": "command", "command": "powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/<user>/hive-statusline-test.ps1"}
   ```

4. Start Claude Code in Windows Terminal and send one message. Check whether `%TEMP%\hive-statusline-test.json`
   appears, and whether it contains a `rate_limits` key. Record only the key names, not the values.
5. Restore the backup and delete the test files.

Record the Claude Code version and the result: runs and has `rate_limits`, runs without them, or doesn't run.

## 6. Write the findings

Create `docs/windows/phase-0-findings.md` with these sections:

1. **Versions:** Windows, Swift, Visual Studio, SDK, Claude Code, Codex, Antigravity.
2. **Build errors:** grouped by file, each with the API involved and a suggested fix.
3. **Test results:** if HiveCore built.
4. **File locations:** a corrected copy of the overview's table. Each row says **confirmed**, **not present** or
   **unknown**.
5. **Processes:** executable names and command-line shapes, with placeholders.
6. **Command-line access:** whether it works without elevation.
7. **Status line:** the result.
8. **Surprises:** anything that changes the plan.

Commit it on `windows-port` and open a draft PR titled "Windows port: phase 0 findings".

## Done when

- [ ] `phase-0-findings.md` exists and every "check"/"guess" from the overview's file table is resolved.
- [ ] Every HiveCore build error is listed with a suggested fix (or HiveCore builds and test results are listed).
- [ ] No real personal paths, names or transcript text are in the file.
- [ ] `settings.json` on the test PC is restored.
