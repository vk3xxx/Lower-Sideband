#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-fast}"
[[ "$MODE" == fast || "$MODE" == all ]] || {
    print -u2 "Usage: $0 [fast|all]"
    exit 64
}
cd "$ROOT"

Scripts/check-repository.sh
Scripts/validate-apple-quality.swift
swift test --no-parallel

if [[ "$MODE" == all ]]; then
    xcodebuild -project MacSideband.xcodeproj -scheme SidebandMac \
      -configuration Release -destination 'platform=macOS' \
      -derivedDataPath .build/quality-macos CODE_SIGNING_ALLOWED=NO build
    xcodebuild -project MacSideband.xcodeproj -scheme SidebandIOS \
      -configuration Release -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath .build/quality-ios CODE_SIGNING_ALLOWED=NO build
    Scripts/validate-ios-app.sh 'generic/platform=iOS Simulator'
fi

print "Production quality gates passed ($MODE)."
