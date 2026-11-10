#!/usr/bin/env bash
# Build the app with SwiftPM and wrap it in build/Agent Hive.app, ad-hoc signed.
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail

config=${1:-debug}
case "$config" in debug|release) ;; *) echo "usage: $0 [debug|release]" >&2; exit 2 ;; esac

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

swift build -c "$config" --product HiveApp
bin=$(swift build -c "$config" --show-bin-path)

app="build/Agent Hive.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/HiveApp" "$app/Contents/MacOS/HiveApp"
cp Sources/HiveApp/Info.plist "$app/Contents/Info.plist"
# The web pages, served to the window by the app's scheme handler.
cp -R Sources/HiveApp/Resources/web "$app/Contents/Resources/web"

codesign --force --sign - --timestamp=none "$app"
echo "$root/$app"
