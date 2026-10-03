#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP="$ROOT/Build/ISC.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/ISC" "$APP/Contents/MacOS/ISC"
cp "$ROOT/Vendor/ISC/libisc.dylib" "$APP/Contents/Frameworks/libisc.dylib"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP/Contents/Frameworks/libisc.dylib"
codesign --force --sign - "$APP/Contents/MacOS/ISC"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
