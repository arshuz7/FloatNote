#!/bin/bash
# Builds FloatNote.app in this folder.
#   ./build.sh               build for this Mac
#   ./build.sh --universal   build for Apple Silicon + Intel
# Set VERSION=1.2.3 to stamp the app version.
# Needs the Xcode Command Line Tools:  xcode-select --install
set -euo pipefail
cd "$(dirname "$0")"

APP="FloatNote.app"
BIN="$APP/Contents/MacOS/FloatNote"
FLAGS=(-O -framework Cocoa -framework Carbon)

rm -rf "$APP" .build
mkdir -p "$APP/Contents/MacOS" .build

if [[ "${1:-}" == "--universal" ]]; then
    echo "Compiling (universal)…"
    swiftc "${FLAGS[@]}" -target arm64-apple-macos11  Sources/main.swift -o .build/FloatNote-arm64
    swiftc "${FLAGS[@]}" -target x86_64-apple-macos11 Sources/main.swift -o .build/FloatNote-x86_64
    lipo -create .build/FloatNote-arm64 .build/FloatNote-x86_64 -output "$BIN"
else
    echo "Compiling…"
    swiftc "${FLAGS[@]}" Sources/main.swift -o "$BIN"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${VERSION:-}" ]]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it:              open $APP"
echo "Install it (opt.):   mv $APP /Applications/"
