#!/bin/sh
# Builds build/DevStats.app (ad-hoc signed). Copy it to /Applications to keep it.
set -eu
cd "$(dirname "$0")"

swift build -c release --product DevStats
app=build/DevStats.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/DevStats" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
codesign --force --sign - "$app"
echo "Built $app"
