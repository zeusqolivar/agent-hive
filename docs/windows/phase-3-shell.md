# Phase 3: the Tauri shell

**Goal:** a Windows app that shows Agent Hive's existing pages in a window, has a tray icon with a usage panel, keeps
the PC awake when asked, and starts at login. All data comes from `hive-core.exe` (phase 2).

**Start from:** phase 2 merged into `windows-port`.

**Output:** a PR "Windows port: Tauri shell". The app runs from source (`cargo tauri dev`) with real data. The
installer comes in phase 5.

## 0. Before writing code

- Use **Tauri 2** and its current docs (https://v2.tauri.app). Several details below (URL scheme on Windows, plugin
  names) are as of late 2026; check them against the docs and note any differences in the PR.
- Prerequisites on the PC: Rust (stable, MSVC toolchain), the Tauri CLI (`cargo install tauri-cli --version "^2"`),
  and WebView2, which ships with Windows 11.

## 1. Project

Create the shell in `windows/` at the repository root:

```
windows/
  src-tauri/
    Cargo.toml
    tauri.conf.json
    capabilities/default.json
    src/main.rs
    src/helper.rs       # starts hive-core and forwards requests
    src/keep_awake.rs   # SetThreadExecutionState on its own thread
    src/tray.rs         # tray icon, panel window, right-click menu
    src/settings.rs     # the shell's own settings file
    binaries/           # hive-core-x86_64-pc-windows-msvc.exe, copied in by a build script
    icons/
```

- The pages stay in `Sources/HiveApp/Resources/web/`; don't copy them by hand. Bundle that folder as a Tauri
  resource and pass its path to the helper. A small build script copies `hive-core.exe` (from
  `swift build -c release --product hive-core`) into `binaries/` with the target-triple suffix Tauri expects for
  `bundle.externalBin`.
- Plugins:
  - `tauri-plugin-single-instance`: a second launch focuses the first one
  - `tauri-plugin-autostart`: start at login
  - `tauri-plugin-positioner`: put the panel next to the tray icon
  - `tauri-plugin-opener`: open external links in the default browser

## 2. Helper process (`helper.rs`)

- Start the bundled `hive-core.exe` with stdin and stdout piped, stderr written to
  `%APPDATA%\Agent Hive\logs\hive-core.log` (rotate at 1 MB), and `CREATE_NO_WINDOW` so no console window
  flashes.
- One writer for stdin, behind a mutex. One reader thread that parses response lines and resolves pending requests
  from a `HashMap<u64, oneshot::Sender<Response>>`. Requests time out after 30 seconds with a 504.
- If the helper exits unexpectedly, fail the pending requests with 502, restart it with backoff (1 s, 2 s, 5 s, then
  every 30 s), and let the pages show their normal "can't reach the data" state. Log the exit code.
- On app quit, close stdin and wait up to 2 seconds for the helper to exit, then kill it.

## 3. Serving the pages

- Register a custom protocol named `hive` with `register_asynchronous_uri_scheme_protocol`. For each request:
  1. take the method, the path with its query string, and the body
  2. send them to the helper as one request line (phase 2's protocol)
  3. answer with its status, content type and body, plus `Cache-Control: no-store`
- On Windows, WebView2 serves custom protocols from an `http://hive.localhost/` origin by default; check the current
  Tauri behaviour. The pages use relative URLs (`/api/board`), so they work on either origin.
- Main window: open the custom protocol's root URL. Size 1200×800, minimum 620×480, title "Agent Hive".
- **Navigation:** allow only the `hive` origin. Any other URL (links in transcripts, GitHub, PR links) opens in the
  default browser through the opener plugin, and the navigation is cancelled. That's what `WebView.swift` does on
  the Mac.
- **Check in WebView2** that these work, since the pages depend on them:
  - `confirm()` and `alert()`, used before risky actions
  - `navigator.clipboard.writeText`, used by "Copy & open in Claude". If it fails on the origin, add a `copy`
    command and a small script injected at document start that routes `navigator.clipboard.writeText` to it, as the
    Mac app does in `WebView.swift`.
  - `localStorage`, where the pages keep view settings
  - downloading and choosing a file, for the Classroom editor's Export and Import
- `--open "#/classroom"` on the command line opens the window on that view, like the Mac app.
- **Closing the window** hides it and keeps the app in the tray, as the Mac app keeps its menu bar icon. Show a
  one-time notification the first time this happens, saying the app is still in the tray. A setting in phase 4
  turns this off.

## 4. Tray icon and panel (`tray.rs`, `panel.html`)

The Mac app's menu bar panel (`Sources/HiveApp/MenuBar.swift`) is SwiftUI. On Windows it becomes a page.

1. **Data.** Add `GET /api/panel` to `HiveAPI`, so both platforms can use it. It returns the panel's data:

   ```json
   {
     "needsYou": 1, "working": 5,
     "waiting": [{"id": "…", "name": "…", "headline": "…"}],
     "busy":    [{"id": "…", "name": "…", "headline": "…"}],
     "usage": [ /* UsageGlance rows as JSON: id, title, body {kind: meters|amount|note, …}, stale, problem, action */ ]
   }
   ```

   - `waiting` holds the first 5 sessions that need you, and `busy` the first 3 that are working, as in
     `AppModel.follow`.
   - Make `UsageGlance` (`Sources/HiveCore/Limits/UsageGlance.swift`) `JSONRepresentable` for the `usage` field.
   - Add a test with fixture cards.
2. **`panel.html`**, in the same `web` folder, matching the Mac panel's layout. Use `docs/menubar.png` as the
   reference:
   - **Header:** app icon, "Agent Hive", and "1 needs you, 5 working".
   - **Usage first:**
     - each plan has a summary line ("78% of your weekly limit used.") and one row per window: name and "Resets
       Friday 12:12 PM" on the left, a thin bar in the middle (blue, orange from 75%, red from 90%), and "34% used"
       on the right
     - API-key rows show the amount on the right and the caption below the name
     - notes and the Set up / Add keys buttons
     - a refresh button that calls `POST /api/limits/refresh`
   - **Needs you, then Working:** clicking a row opens the main window on `#/agents/<id>` and hides the panel.
   - **Keep PC awake:** a select with Off, While working, Always, For 1 hour.
   - **Footer:** Open Agent Hive, Settings, Quit.
   - Use the same CSS variables as `index.html` so light and dark themes match Windows.
3. **Panel window:** borderless, not resizable, skipped in the taskbar, always on top, 400 px wide with height
   fitted to the content. Place it next to the tray icon with the positioner plugin, and hide it when it loses
   focus.
4. **Tray icon:**
   - **Left-click** toggles the panel.
   - **Right-click** opens a native menu: Open Agent Hive, Keep PC awake (submenu with the four modes), Settings,
     Quit.
   - **Tooltip:** "Agent Hive: 1 session needs you", or "Agent Hive" when nothing does. Add "keeping the PC awake"
     while that's on.
   - **Icon:** a plain variant, a variant with a dot when something needs you, and light and dark versions for the
     taskbar theme. Draw them with `scripts/make_icon.swift` or as small PNGs.
5. **Polling:** the shell asks the helper for `/api/panel` every 2 seconds while the app runs. This drives the
   tooltip, the dot and "while working" keep-awake. Use the panel request, not `/api/board`; it's smaller.

## 5. Keep-awake (`keep_awake.rs`)

- `SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)` keeps the PC from sleeping on its own, and
  `ES_CONTINUOUS` alone releases it. The flag belongs to the calling thread, so own it from one dedicated thread
  that receives on/off messages.
- Don't use `ES_DISPLAY_REQUIRED`: the screen may still turn off, as on the Mac.
- Modes match `KeepAwakePolicy` (`Sources/HiveCore/KeepAwake/KeepAwakePolicy.swift`):
  - **Off**
  - **While working:** on while any session is working or needs you
  - **Always**
  - **For 1 hour:** switches itself off afterwards and shows "(N min left)" in the menu and panel
- Port the policy's rules to Rust with the same tests, or expose them from the helper. Porting is simpler: it's
  about 20 lines.
- Save the mode and the one-hour end time in the shell's settings file (`%APPDATA%\Agent Hive\shell.json`), and
  restore them at launch. An expired one-hour mode starts as Off.

## 6. Commands for the pages

Set `withGlobalTauri: true`. In `capabilities/default.json`, allow these commands only for the main, panel and
settings windows, and only from the `hive` origin:

| Command | Does |
|---|---|
| `open_main(route?)` | Shows and focuses the main window, optionally at `#/…` |
| `hide_panel()` | Hides the panel |
| `get_keep_awake()` / `set_keep_awake(mode)` | Reads and sets the mode; returns `{mode, active, minutesLeft}` |
| `get_autostart()` / `set_autostart(on)` | Start at login |
| `open_settings()` | Opens the settings window (its page comes in phase 4) |
| `quit()` | Quits the app and stops the helper |

The pages must keep working on the Mac, where `window.__TAURI__` doesn't exist. Guard every call with
`if (window.__TAURI__)`. `panel.html` is only used on Windows.

## 7. Check it

On the PC, with Claude Code sessions running:

```powershell
cd windows
cargo tauri dev
```

- Every tab shows real data: Agents, Classroom, Terminal, Activity, Usage, Skills, Connectors, System.
- Clicking a session opens its details. External links open in the browser.
- The tray panel shows usage and sessions. Its rows open the right session. The panel hides when you click
  elsewhere.
- Keep-awake: check each mode with `powercfg /requests`. Agent Hive should be listed under SYSTEM while it's on,
  and not listed while it's off.
- Start at login: turn it on, sign out and back in, and check the app starts in the tray without opening the
  window.
- Kill `hive-core.exe` in Task Manager. The app recovers within a few seconds, and the log shows the restart.
- Second launch: it focuses the running app instead of starting another.
- Light and dark: switch Windows' theme, and check the pages, the panel and the tray icon.

Take screenshots of the main window, the panel in both themes, and the tray menu. Attach them to the PR.

## Done when

- [ ] All views work with real data in the Windows window.
- [ ] The tray panel works and matches the Mac panel's layout.
- [ ] Keep-awake modes work and are confirmed with `powercfg /requests`.
- [ ] Start at login works.
- [ ] The helper restarts after a crash.
- [ ] The pages and the Mac app are unchanged on macOS (run the Mac app and check the views).
