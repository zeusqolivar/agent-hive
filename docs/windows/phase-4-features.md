# Phase 4: Windows features

**Goal:** what the Mac app does natively, on Windows:
- a Settings window
- API keys for usage services
- the Claude status line for plan limits
- replying to sessions
- Open in Antigravity
- Open in Claude

**Start from:** phase 3 merged into `windows-port`.

**Output:** a PR "Windows port: settings and native features".

## 1. Settings window (`settings.html`)

The Mac Settings (`Sources/HiveApp/SettingsView.swift`) is SwiftUI. On Windows it's a page in the `web` folder,
opened by the `open_settings` command in its own window: 560×520, not resizable, titled "Agent Hive Settings". Use
the same CSS variables as `index.html`.

Sections, matching the Mac app's tabs:

1. **General**
   - **Start Agent Hive when you sign in:** `get_autostart`/`set_autostart`.
   - **Open the window at sign-in:** off means start in the tray only. Stored in `shell.json`.
   - **Keep running in the tray when the window is closed:** on by default. Stored in `shell.json`.
   - **Keep PC awake:** the four modes. Under it, the same note the Mac app shows, adapted: "Stops your PC from
     going to sleep on its own so agents keep running. The screen can still turn off."
2. **Usage services**
   - One row per service: DeepSeek, OpenRouter, OpenAI (Admin key), Anthropic (Admin key). Each shows "Key saved"
     with **Remove**, or a password field with **Save key**.
   - Below the rows: "Keys are kept in Windows Credential Manager and sent only to their own service, every 15
     minutes and when you click Refresh in the Usage view."
   - **Claude plan limits:** a **Set up** or **Remove** button for the status line (section 3), with a line on what
     it does.

### Key endpoints

Add these to `HiveAPI`, in its POST allowlist, so the pages can manage keys:

| Request | Answer |
|---|---|
| `GET /api/keys` | `{"services": [{"id": "deepseek", "title": "DeepSeek", "keyKind": "API key", "saved": true}, …]}`. Never the keys. |
| `POST /api/keys` with `{"service": "deepseek", "key": "…"}` | Saves to the system `KeyStore` and starts a check. 200, or 400 with a message that doesn't include the key. |
| `POST /api/keys` with `{"service": "deepseek", "key": null}` | Removes it. |

Rules:
- Accept only known service ids from `UsageProviders.all`.
- Trim whitespace. Refuse an empty key, and refuse keys over 500 characters.
- Never echo the key, log it, or write it to a file.
- Clear the password field after saving.
- The Mac app keeps its native Settings and doesn't need to use these endpoints, but they must work there too
  (`KeychainKeyStore`). Add tests with the fake key store.

## 2. Settings and tray wiring

- The panel's **Add keys** button opens Settings on Usage services.
- **Set up** opens it on the Claude section, or calls `POST /api/limits/claude {"action": "install"}` directly, as
  the Mac panel does.
- After a key is saved or removed, the panel and the Usage view show the new state on their next refresh.

## 3. Claude status line on Windows

Do this section only if phase 0 found that Claude Code runs status line commands on Windows. If it doesn't, the
Claude card should say "Claude Code doesn't run status line commands on this PC yet, so its limits can't be read",
and the Set up button should be hidden. Stop here in that case.

`StatusLineInstaller` (`Sources/HiveCore/Limits/StatusLineInstaller.swift`) writes `statusline.sh` and sets
`statusLine` in `~/.claude/settings.json`, saving the previous value for **Remove**. On Windows:

1. Write `%APPDATA%\Agent Hive\statusline.ps1`. It does the same as the Mac script:
   - read all of stdin
   - parse it with `ConvertFrom-Json`
   - if it has `rate_limits`, write `{"savedAt": <unix seconds>, "rate_limits": …}` to `claude-limits.json` next to
     the script, atomically: write a temp file, then `Move-Item -Force`
   - if there was a previous status line command, run it with the same stdin and print its output unchanged;
     otherwise print nothing

   The JSON written must match what `ClaudeLimits.read` expects; check against the Mac script and its tests.
2. Set `statusLine.command` to
   `powershell -NoProfile -ExecutionPolicy Bypass -File "C:/Users/<user>/AppData/Roaming/Agent Hive/statusline.ps1"`.
   Use forward slashes: backslashes in this field have been reported to be unescaped twice. Use whatever form
   phase 0 confirmed works.
3. **Remove** restores the saved previous value exactly, or deletes the key if there was none, and deletes the
   script. This is the same contract as on the Mac, so reuse the installer's logic and change only the script and
   command.
4. Running the previous command: it's a command line string. Run it with `cmd.exe /d /s /c "<command>"`, pipe the
   saved stdin to it, and pass its output through.
5. Tests: install and remove against a temp `settings.json`, with and without an existing `statusLine`. Check that
   other keys are kept and that an untouched file is restored byte for byte. The script's JSON output is checked by
   running it on CI's Windows job with a sample input.

## 4. Replies

`ReplySender` runs `claude --resume <id> -p --output-format json` in the session's folder, with the reply text on
stdin, after checking `claude auth status --json`.

- `ProcessReplyRunner.find("claude")` uses phase 1's tool lookup and finds `claude.exe` or `claude.cmd`.
- A `.cmd` must run through `cmd.exe /d /s /c`. Build the arguments without string concatenation of user input.
  The session id is checked against `^[A-Za-z0-9_-]+$` before use (it already is on the API path). The text goes
  on stdin only.
- `commandEnvironment()`: drop variables starting with `CLAUDE` as today, and build `PATH` with `;`.
- The 30-minute timeout and the "one reply at a time per session" rule stay.
- Check by hand: reply to a session that isn't running, and see Claude's answer appear in its timeline.

## 5. Open in Antigravity

`AntigravityOpener` uses `open -a Antigravity [folder]` and `osascript`, then reads the hub's port to focus the
conversation. On Windows:

- Add a Windows `AppLauncher` that starts `Antigravity.exe` (path from the findings) with the folder as its
  argument, through `ShellExecuteW` or `Process`.
- Bring its window forward. Find the window by process id with `EnumWindows`, then call `SetForegroundWindow`.
  Windows only allows that in some conditions; if it's refused, `FlashWindowEx` is acceptable.
- The DevTools port file location comes from the findings. The rest of the opener (talking to the hub over
  `https://127.0.0.1:<port>`) is platform-neutral.
- If Antigravity isn't installed, answer with the same message the Mac app gives.

## 6. Open in Claude

If phase 0 found that the Claude desktop app registers `claude://` on Windows, `WindowsActions.open(hostSessionId:)`
(phase 2) already works; check it by hand. If it doesn't, the page should hide **Open in Claude** on Windows: add a
`capabilities` field to `/api/board` (for example `{"openInClaude": false}`) rather than checking the platform in
JavaScript.

## 7. README

Add a **Windows** column or section to the README's "What it reads" table, using the paths from the findings, and
a short "Windows" note under Known limitations covering anything that differs (for example Claude limits, if the
status line doesn't run).

## Done when

- [ ] Settings works: keys save to Credential Manager (check in Control Panel > Credential Manager > Windows
      Credentials, target `AgentHive/usage/<service>`), are never shown again, and the Usage view updates.
- [ ] The Claude status line installs and removes cleanly, or the card explains why it isn't available.
- [ ] Replying to a stopped session works.
- [ ] Open in Antigravity and Open in Claude work, or are hidden with a reason.
- [ ] macOS: all tests pass, and the Mac app's Settings and replies behave as before.
