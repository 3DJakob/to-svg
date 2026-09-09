#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/To SVG.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache
swiftc Sources/main.swift -o "$APP/Contents/MacOS/ToSVG" -framework Cocoa -framework PDFKit -module-cache-path "$PWD/build/module-cache" -O
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
