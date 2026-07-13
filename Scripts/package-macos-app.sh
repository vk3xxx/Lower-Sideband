#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP="$ROOT/dist/Sideband.app"

cd "$ROOT"
swift build -c release
install -d "$APP/Contents/MacOS"
install -m 644 "$ROOT/Support/Sideband-Info.plist" "$APP/Contents/Info.plist"
install -m 755 "$ROOT/.build/release/SidebandMac" "$APP/Contents/MacOS/SidebandMac"

echo "$APP"
