# Phase 1: make HiveCore build and pass tests on Windows

**Goal:** `swift test` passes on Windows **and** macOS, from the same commit, with CI running both. macOS behaviour
doesn't change at all.

**Start from:** `docs/windows/phase-0-findings.md`. Where it disagrees with this guide or the overview, the findings
win.

**Output:** a PR "Windows port: portable HiveCore" on `windows-port`.

## 1. Package layout

1. In `Package.swift`, keep `HiveApp` for macOS only. SwiftPM has no per-platform target switch, so either:
   - **(preferred)** move the Mac app into its own package or folder later, and for now guard `HiveApp`'s sources
     with `#if os(macOS)` and give it an empty `main` on other systems; or
   - declare the products conditionally in `Package.swift` with `#if os(macOS)`, since `Package.swift` is Swift.

   Pick the one that keeps `swift build` and `scripts/bundle.sh` working unchanged on the Mac. Document the choice
   at the top of `Package.swift`.
2. Add `platforms` only for macOS as today. Windows needs no entry.
3. Add a C target `CSQLite` with the SQLite amalgamation (`sqlite3.c`, `sqlite3.h`, public domain, from
   https://sqlite.org/download.html). Pin the version in a comment, and depend on it from `HiveCore` with
   `.target(name: "CSQLite", condition: .when(platforms: [.windows]))`. In the three files that `import SQLite3`,
   write:

   ```swift
   #if canImport(SQLite3)
   import SQLite3
   #else
   import CSQLite
   #endif
   ```

4. Add a C target `CWinProcess`, Windows only, for the one call Swift's `WinSDK` doesn't expose: reading another
   process's command line with `NtQueryInformationProcess(..., ProcessCommandLineInformation /* 60 */, ...)` from
   `ntdll`. Give it a tiny API, for example:

   ```c
   // Returns the UTF-16 length written (without the terminator), or -1. Never reads more than `capacity`.
   int hive_process_command_line(unsigned long pid, wchar_t *buffer, int capacity);
   ```

   Link `ntdll` with `linkerSettings: [.linkedLibrary("ntdll")]`.

## 2. Paths

`HivePaths` builds every path from a home folder. Add a Windows initialiser and keep the Mac one untouched.

1. `HivePaths.current`: on Windows use `FileManager.default.homeDirectoryForCurrentUser` (that's
   `%USERPROFILE%`). `getuid()` doesn't exist there, so set `uid` to 0 and stop using it on Windows.
2. Add `static func windows(home: URL, appData: URL, localAppData: URL, temp: URL, environment: [String: String]) -> HivePaths`
   so tests can pass fixture folders. Fill each property from the findings' file table:
   - `.claude`, `.claude.json`, `.codex` (honour `CODEX_HOME` when set; also the Store app's
     `CodexAppHome` if phase 0 found it), `.gemini\antigravity`, `.cursor\mcp.json`, `.openclaw`
   - `claudeDesktopConfig` → `%APPDATA%\Claude\claude_desktop_config.json`
   - `supportFolder` → `%APPDATA%\Agent Hive`
   - `tasksRoot` → the background-output folder from the findings (or leave the reader empty if unknown)
   - `antigravityApp`, `antigravityDevToolsPorts`, `openclawPackage` from the findings
3. Sweep HiveCore for path code that assumes `/`:
   - string concatenation with `"/"`
   - splitting `PATH` on `:` (Windows uses `;`, and drive letters contain `:`)
   - `hasPrefix("/")` checks for absolute paths
   - shortening paths with `~`

   Replace them with `URL` and `FileManager` calls. Shortening a path for display should turn
   `C:\Users\<user>\proj` into `~\proj`.
4. Project folder names: if any code decodes `~/.claude/projects/<folder>` back into a path, add the Windows
   encoding from the findings and a test for it.

Add tests in `HivePathsTests` for the Windows initialiser with a fixture home. They must run on both systems, since
`HivePaths.windows` is plain URL building.

## 3. Processes

`ProcessSource.snapshot() -> [Int32: ProcRecord]` (`Processes/ProcessTable.swift`) feeds the board. `ProcRecord`
holds `pid`, `ppid`, `uptime` (seconds), `rssMB`, `cpu` (percent) and `cmd`.

1. Add `WindowsProcessSource: ProcessSource`, compiled only on Windows:
   - `CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS)`, with `Process32FirstW`/`Process32NextW` for pid, parent pid
     and exe name.
   - For each pid, `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ)`, falling back to
     `PROCESS_QUERY_LIMITED_INFORMATION` alone. Then:
     - `GetProcessTimes`: `uptime` from creation time; `cpu` = (kernel + user time) / wall time since creation ×
       100, which matches `ps`'s lifetime average closely enough.
     - `K32GetProcessMemoryInfo`: `rssMB` from `WorkingSetSize`.
     - `hive_process_command_line` for `cmd`. If it fails (access denied, elevated process), use the exe name.
   - Close every handle (`defer { CloseHandle(h) }`).
   - Keep it fast: the board calls it every 2 seconds. Measure it on the test PC with 300+ processes; it should take
     under 50 ms.
2. Split the logic so most of it is testable on any system: a pure function that turns raw rows
   (`pid, ppid, creationTime, kernelTime, userTime, workingSet, commandLine, now`) into `ProcRecord`s, with tests.
   Only the Win32 calls stay untested.
3. Replace `kill(pid, 0)` in `Sessions/SessionReader.swift` with a `pidAlive` helper. On Windows it uses
   `OpenProcess` + `GetExitCodeProcess == STILL_ACTIVE`. Treat access denied as alive, just as `EPERM` is today.
4. Process patterns: `System/SystemReport.swift` and `Board/MacSummary.swift` match command lines with Mac paths.
   Add Windows patterns from the findings (for example `claude.exe`, `node.exe … @anthropic-ai\claude-code`,
   `Antigravity.exe`, the language server's exe). Choose the list by platform. Do the same where
   `AntigravityReader` decides whether a hub file's pid belongs to Antigravity.
5. Wire it up: wherever `PSProcessSource()` is created (`Services` in `HiveApp`, `AntigravityOpener`), use a factory
   such as `ProcessSources.system()` that returns the right one for the platform.

## 4. Keys: Windows Credential Manager

`KeyStore` (`Limits/KeyStore.swift`) has `key(for:)`, `hasKey(for:)`, `save(_:for:)` and `remove(service:)`.

1. Move `KeychainKeyStore` behind `#if canImport(Security)`, and add `CredentialManagerKeyStore: KeyStore` for
   Windows:
   - target name `AgentHive/usage/<service>` (`deepseek`, `openrouter`, `openai`, `anthropic`)
   - `CRED_TYPE_GENERIC`, `CRED_PERSIST_LOCAL_MACHINE` (per user, never roamed)
   - `CredWriteW` to save, `CredReadW` to read (free the result with `CredFree`), and `CredDeleteW` to remove.
     Treat `ERROR_NOT_FOUND` as "no key" or "already gone".
   - The key is the credential blob, as UTF-8. Never log it, and never put it in an error.
2. Add a `KeyStoreError.system(Int)` case for Windows error codes, keeping `.keychain(OSStatus)` for macOS. Check
   that the error messages in `LimitsService` still never include a key.
3. Add `KeyStores.system()` that returns the right store.
4. The existing `KeyStoreTests` use a fake store; keep them platform-neutral. Add one Windows-only test that saves,
   reads and removes a key under a throwaway target (`AgentHive/test/<uuid>`), and always cleans up.

## 5. Files and subprocesses

1. **Atomic writes.**
   - `ClassroomStore.save` writes a temp file and `rename(2)`s it into place. On Windows `rename` fails when the
     target exists. Add one helper, `AtomicFile.replace(_ target: URL, with temp: URL)`:
     - macOS: `rename`, as today
     - Windows: `MoveFileExW(temp, target, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)`
   - `UsageHistory` and `StatusLineInstaller` use `Data.write(to:options: .atomic)`. Check on Windows that
     overwriting an existing file this way works, including `~/.claude/settings.json` while Claude Code has it open.
     If it fails, switch them to the same helper.
2. **Killing subprocesses.** In `Support/Subprocess.swift`, `kill(pid, SIGKILL)` becomes `process.terminate()` on
   Windows.
3. **Finding tools** (`ReplySender.commandEnvironment`, `SkillsJobs`):
   - split `PATH` on `;`
   - try `.exe`, `.cmd` and `.bat` (npm installs `claude.cmd`)
   - add `%USERPROFILE%\.local\bin` and `%APPDATA%\npm`
   - leave out `/opt/homebrew/bin`

   Running a `.cmd` needs `cmd.exe /d /s /c "<path>" args…`. Quote the arguments safely and pass user text on stdin
   only, never on the command line (the reply code already sends text on stdin).

## 6. Tests and CI

1. Run the whole suite on Windows. Fix tests that hard-code `/` paths by building expected paths with `URL`. Mark
   tests that are truly Mac-only (for example the Keychain or `/bin/ps` parsing) with `.enabled(if: …)` or
   `#if os(macOS)`, and say why in one line.
2. Add Windows fixtures under `Tests/HiveCoreTests/Fixtures/windows-home/`, mirroring `Fixtures/home` with the
   Windows layout from the findings. All made up.
3. Add `.github/workflows/ci.yml` with two jobs:
   - `macos-latest`: `swift test`
   - `windows-latest`: install Swift with the `compnerd/gha-setup-swift` action (pin a version and a Swift
     release), then `swift test`. Building HiveCore and its tests is enough here; the shell comes later.

## Done when

- [ ] `swift test` passes on Windows and on macOS, and CI runs both on every push to `windows-port`.
- [ ] `scripts/bundle.sh release` still builds the Mac app, and the Mac app behaves as before (open it and check
      the Agents view, the menu bar panel and Settings > Usage services).
- [ ] No Windows code path reads another tool's credentials.
- [ ] `WindowsProcessSource.snapshot()` takes under 50 ms on the test PC (note the number in the PR).
