# Phase 2: the `hive-core` helper

**Goal:** a small Windows executable, `hive-core.exe`, that runs HiveCore without any UI. It answers the same
`/api/...` paths the Mac app's pages use, over its standard input and output. The shell (phase 3) starts it and
forwards the pages' requests to it.

**Start from:** phase 1 merged into `windows-port`.

**Output:** a PR "Windows port: hive-core helper".

## Why stdin/stdout

The README promises "no server and no open port". On the Mac, pages reach `HiveAPI` through a `hive://` scheme
handler inside the process. On Windows the API runs in a separate process. Using a pipe instead of a local TCP port
keeps the promise: no other program on the PC can reach the API.

## 1. Target

Add an executable target `HiveCoreHelper` (product name `hive-core`) that depends on `HiveCore`. It must build on
macOS too, which makes it easy to test the protocol on a Mac.

It needs what `Services` in `Sources/HiveApp/HiveApp.swift` sets up today, without SwiftUI:
- `Board(paths:processes:pageVersion:replies:)` with `ProcessSources.system()` from phase 1
- `UsageCounter`, `SkillsReader`, `SkillsJobs`, `SystemReport`, `ClassroomStore`, `ConnectorsReader`
- `LimitsService(paths:keys:http:)` with `KeyStores.system()` and `URLSessionHTTP()`
- `ReplySender(paths:)`
- `HiveAPI(...)` with `pages:` pointing at the bundled `web` folder (next to the exe, in a `web` folder)
- start `board.start()`, `usage.start()` and `limits.start()` as `Services` does

Move the shared wiring into `HiveCore` (for example a `HiveServices` type) so `HiveApp` and the helper build it
the same way. The Mac app's behaviour must not change.

`ActionHandler` on Windows is a new `WindowsActions` type in the helper:
- `open(hostSessionId:)`: `ShellExecuteW` on `claude://code/continue?session=<id>&source=desktop_action`, only if
  phase 0 found that the Claude desktop app registers `claude://`. Otherwise return false; the page already handles
  a false answer.
- `reveal(folder:)`: `explorer.exe /select,"<path>"`.
- `openAntigravity(sessionId:cwd:)`: phase 4 makes this work. Return `(false, "Not available on Windows yet.")` for
  now.

## 2. Protocol

One JSON object per line, UTF-8, `\n`-terminated, in both directions.

Request, from the shell on stdin:

```json
{"id": 17, "method": "GET", "path": "/api/board", "body": null}
{"id": 18, "method": "POST", "path": "/api/classroom", "body": "<base64 of the request body>"}
```

Response, from the helper on stdout:

```json
{"id": 17, "status": 200, "contentType": "application/json; charset=utf-8", "body": "<base64>"}
```

Rules:
- `id` is chosen by the shell, and the helper copies it back. Requests can be answered out of order, so handle
  each request in its own `Task` and serialise only the writes to stdout, through an actor.
- `path` includes the query string, exactly as the page requested it (`/api/session/abc?tail=200`).
- `body` is base64 or `null`. Bodies larger than 1 MB are refused with status 413, matching the Mac handler's
  limit.
- Static files (`/`, `/index.html`, `/room.js`, …) go through `HiveAPI.handle` too, which already serves pages.
- **Nothing else may be written to stdout.** Logs go to stderr, which the shell can save to a log file. Never log
  keys, request bodies or response bodies.
- When stdin closes (the shell quit or crashed), stop the refresh loops and exit with status 0 within a second.
- A malformed line is answered with `{"id": null, "status": 400, ...}` and the helper keeps running.

Put the framing (encode, decode, the line reader) in a small type with unit tests: round trip, out-of-order
answers, a malformed line, an oversized body, and stdin closing.

## 3. Developer options

Mirror the Mac app's options so the helper can be checked from a terminal:

| Option | Does |
|---|---|
| `hive-core --dump /api/board /api/limits …` | Refreshes once, prints each answer, exits (like `HiveApp --dump`). |
| `hive-core --post <path> <json>` | One POST after one refresh, prints status and body. |
| `hive-core --version` | Prints the version, read from the same place as the Mac app's version. |

## 4. Check it

On the Windows PC, with Claude Code sessions running:

```powershell
swift build -c release --product hive-core
.build\release\hive-core.exe --dump /api/board | Select-Object -First 1
.build\release\hive-core.exe --dump /api/limits /api/connectors
```

Then test the pipe protocol by hand, by sending one request line:

```powershell
'{"id":1,"method":"GET","path":"/api/board","body":null}' | .build\release\hive-core.exe
```

Check:
- `/api/board` lists the real sessions with the right groups (needs you, working, idle) and headlines.
- `/api/limits` shows the Codex card if Codex is used, and Claude as "not set up".
- `/api/connectors` lists the PC's MCP connectors without commands, args, env, headers or full URLs. Search the
  output for any secret-looking value from the fixture configs; the existing connector tests cover this, so run
  them on Windows too.
- Memory and CPU of `hive-core.exe` itself stay low while idle (note the numbers in the PR).

## Done when

- [ ] `hive-core.exe --dump /api/board` shows the PC's real sessions correctly.
- [ ] The stdio protocol has unit tests that pass on Windows and macOS.
- [ ] The helper exits cleanly when stdin closes.
- [ ] `HiveApp` on macOS still builds and behaves the same after the shared wiring moved into HiveCore.
