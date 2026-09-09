#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/To SVG.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache
swiftc Sources/main.swift -o "$APP/Contents/MacOS/ToSVG" -framework Cocoa -framework PDFKit -module-cache-path "$PWD/build/module-cache" -O
xcrun actool assets/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 13.0 --app-icon AppIcon --output-partial-info-plist "$PWD/build/icon-info.plist"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
