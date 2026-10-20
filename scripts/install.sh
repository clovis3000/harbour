#!/usr/bin/env bash
# Build release, install Harbour.app to ~/Applications and the CLI to ~/.local/bin, relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
app="$HOME/Applications/Harbour.app"

pkill -x Harbour 2>/dev/null || true
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/HarbourApp "$app/Contents/MacOS/Harbour"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"

# A copy, not a symlink into .build: a clean build mustn't break agents' `harbour port`.
mkdir -p "$HOME/.local/bin"
cp .build/release/harbour "$HOME/.local/bin/harbour"

open "$app"
echo "installed $app and ~/.local/bin/harbour"
