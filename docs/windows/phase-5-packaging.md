# Phase 5: packaging and release

**Goal:** people can download Agent Hive for Windows from the GitHub release, install it without admin rights, and
update it. The Mac download keeps working as it does today.

**Start from:** phase 4 merged into `windows-port`.

**Output:** a PR "Windows port: installer and release", and, once the owner approves, a release that has both the
Mac zip and the Windows installer.

## 1. One version number

Today the version lives in `Sources/HiveApp/Info.plist` (`CFBundleShortVersionString` and the build number
`CFBundleVersion`). Windows adds `windows/src-tauri/tauri.conf.json` (`version`) and `hive-core --version`.

- Add `scripts/set-version.sh <x.y.z>` (and a PowerShell twin, or make the shell script work in Git Bash). It
  updates all three places and bumps the build number.
- Have `hive-core --version` read a generated `Version.swift`, written by the same script, so it can't drift.
- CI fails if the three versions differ.

## 2. Icons

- `scripts/make_icon.swift` draws the app icon and writes `AppIcon.icns` and `docs/icon.png`. Extend it, or add a
  flag, to also write a 1024×1024 PNG.
- Run `cargo tauri icon <that png>` to make `windows/src-tauri/icons/` (`icon.ico` and the PNG sizes).
- The tray icon variants from phase 3 stay separate, since they're drawn for 16–32 px.
- Commit the generated icons, and say in `scripts/make_icon.swift` how to regenerate them.

## 3. Installer

Use Tauri's **NSIS** bundle:
- per-user install (`installMode: "currentUser"`, no admin prompt) into `%LOCALAPPDATA%\Programs\Agent Hive`
- Start menu shortcut, uninstaller, optional "Start Agent Hive when I sign in" checkbox (it sets the same autostart
  entry as Settings)
- WebView2 bootstrapper set to "download if missing", although Windows 11 has it built in

Also produce a **portable zip** (the exe, `hive-core.exe` and the `web` folder) for people who don't want an
installer.

The uninstaller removes the app and its autostart entry, but leaves `%APPDATA%\Agent Hive` and the Credential
Manager keys, and says so. Add a "Remove my Agent Hive data" option that deletes them and removes the Claude status
line through the same code as **Remove**.

## 4. Code signing

Unsigned installers trigger SmartScreen ("Windows protected your PC"), and a helper that lists processes may also
be flagged by antivirus.

- Preferred: **Azure Trusted Signing** (low cost, works in GitHub Actions), or an OV/EV code signing certificate.
  This needs the owner: an account, identity verification and payment. **Ask the owner before setting anything up,
  and never put certificates or passwords in the repository.**
- Sign `Agent Hive.exe`, `hive-core.exe` and the installer, with a timestamp server.
- Until signing is set up, release unsigned. Document in the README how to get past SmartScreen: **More info >
  Run anyway**. Publish the SHA-256 of each file in the release notes, as the Mac release does.

## 5. Release workflow

Add `.github/workflows/release.yml`, triggered by a `v*` tag:

1. **Windows job** (`windows-latest`):
   1. Set up Swift and Rust.
   2. `swift build -c release --product hive-core`.
   3. Copy it into `windows/src-tauri/binaries/` with the target-triple name.
   4. `cargo tauri build` (NSIS).
   5. Make the portable zip.
   6. Sign, when secrets are present.
   7. Compute SHA-256.
   8. Upload `Agent-Hive-<version>-x64-setup.exe` and `Agent-Hive-<version>-x64.zip` as release assets.
2. **macOS job** (`macos-latest`), optional:
   1. Run `scripts/bundle.sh release`.
   2. Zip it as `Agent-Hive-<version>-arm64.zip`, the way the Mac releases are made today.
   3. Upload it.

   If this is added, check that the zip matches what the owner currently builds by hand. Otherwise leave the Mac
   release manual.
3. Create the release as a **draft**. The owner reviews and publishes it.

Release notes keep the existing format: **New**, **Fixed**, **Privacy**, then **Install** with a line per platform,
then the SHA-256 lines.

## 6. winget (after signing)

Once releases are signed, add a winget manifest, `AgentHive.AgentHive`, pointing at the release installer. Submit
it to `microsoft/winget-pkgs` only with the owner's go-ahead. Then the README can say:

```powershell
winget install AgentHive.AgentHive
```

## 7. README

- Split **Install** into **macOS** and **Windows** (Windows 11, x64): download, run the installer, the SmartScreen
  note while unsigned, and start at login.
- **Build from source** gets a Windows part: Swift for Windows, Visual Studio Build Tools, Rust, then
  `swift build -c release --product hive-core` and `cargo tauri build` in `windows/`.
- Update the status line at the top and the screenshot captions if the Windows look differs.

## 8. Final check on a clean machine

Use **Windows Sandbox** or a fresh VM with no developer tools:

- [ ] The installer runs without admin rights and the app starts.
- [ ] With Claude Code installed and a session running, the session appears within a few seconds.
- [ ] Tray panel, keep-awake, start at login, settings, a saved key, and Remove my data all work.
- [ ] Uninstall removes the app and its autostart entry.
- [ ] The portable zip runs from a folder in Downloads.

## Done when

- [ ] A tagged build produces the Windows installer and zip, with SHA-256s, in a draft release.
- [ ] The README has Windows install and build instructions.
- [ ] The clean-machine check above passes.
- [ ] Signing is either working or explicitly deferred by the owner, with the SmartScreen note in the README.
