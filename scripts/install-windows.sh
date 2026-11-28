#!/bin/sh
# Puts the Windows build somewhere a person can launch it: %LOCALAPPDATA%\Programs\Agent Hive, with a Start
# Menu shortcut. A development shortcut until phase 5's NSIS installer, which replaces this.
#
#   scripts/install-windows.sh            the debug build (fastest to make)
#   scripts/install-windows.sh release    the release build
#
# The shell, the helper and the pages go together: hive-core serves `web` from beside itself, so a copied exe
# without that folder shows an empty window.
set -eu

PROFILE="${1:-debug}"
case "$PROFILE" in
    release) PRODUCTS="$PWD/.build/out/Products/Release-windows-x86_64"; TAURI="$PWD/windows/src-tauri/target/release" ;;
    *)       PRODUCTS="$PWD/.build/out/Products/Debug-windows-x86_64";   TAURI="$PWD/windows/src-tauri/target/debug" ;;
esac

SHELL_EXE="$TAURI/agent-hive-shell.exe"
HELPER_EXE="$PRODUCTS/hive-core.exe"
PAGES="$PWD/Sources/HiveApp/Resources/web"
TARGET="$LOCALAPPDATA/Programs/Agent Hive"

for needed in "$SHELL_EXE" "$HELPER_EXE" "$PAGES"; do
    [ -e "$needed" ] || { echo "Missing $needed — build it first:" >&2; \
        echo "  swift build --product hive-core $([ "$PROFILE" = release ] && echo '-c release')" >&2; \
        echo "  cd windows && cargo build $([ "$PROFILE" = release ] && echo '--release')" >&2; exit 1; }
done

mkdir -p "$TARGET"
cp -f "$SHELL_EXE" "$TARGET/Agent Hive.exe"
cp -f "$HELPER_EXE" "$TARGET/hive-core.exe"
rm -rf "$TARGET/web"
cp -R "$PAGES" "$TARGET/web"
echo "Installed into $TARGET"

# The Start Menu shortcut, so it launches like any other app.
powershell -NoProfile -ExecutionPolicy Bypass -Command "
  \$link = Join-Path \$env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Agent Hive.lnk'
  \$shell = New-Object -ComObject WScript.Shell
  \$shortcut = \$shell.CreateShortcut(\$link)
  \$shortcut.TargetPath = '$TARGET/Agent Hive.exe'
  \$shortcut.WorkingDirectory = '$TARGET'
  \$shortcut.IconLocation = '$PWD/windows/src-tauri/icons/icon.ico'
  \$shortcut.Description = 'Agent Hive: every AI coding agent session on this PC'
  \$shortcut.Save()
  Write-Output \"Start Menu: \$link\"
"
