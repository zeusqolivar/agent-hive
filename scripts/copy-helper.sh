#!/bin/sh
# Copies hive-core.exe into the Tauri project under the name `bundle.externalBin` expects.
#
# Run from the repository root after `swift build --product hive-core`. Phase 5 calls this from the release
# workflow, so the Windows build never relies on a copy committed by hand.
set -eu

TRIPLE="x86_64-pc-windows-msvc"
PROFILE="${1:-debug}"
TARGET="$PWD/windows/src-tauri/binaries/hive-core-$TRIPLE.exe"

case "$PROFILE" in
    release) SOURCE="$PWD/.build/out/Products/Release-windows-x86_64/hive-core.exe" ;;
    *)       SOURCE="$PWD/.build/out/Products/Debug-windows-x86_64/hive-core.exe" ;;
esac

if [ ! -f "$SOURCE" ]; then
    echo "No $SOURCE — run: swift build --product hive-core${PROFILE:+ -c $PROFILE}" >&2
    exit 1
fi

mkdir -p "$(dirname "$TARGET")"
cp "$SOURCE" "$TARGET"
echo "Copied $SOURCE -> $TARGET"
