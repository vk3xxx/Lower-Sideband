#!/bin/zsh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-all}"

cd "$ROOT"

run_protocol_tests() {
    swift test --filter rnode
    swift test --filter RNode
}

build_apps() {
    xcodebuild -project MacSideband.xcodeproj -scheme SidebandMac -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath .build/rnode-mac-derived \
        CODE_SIGNING_ALLOWED=NO build
    xcodebuild -project MacSideband.xcodeproj -scheme SidebandIOS -configuration Debug \
        -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/rnode-ios-derived \
        CODE_SIGNING_ALLOWED=NO build
}

case "$MODE" in
    protocol) run_protocol_tests ;;
    apps) build_apps ;;
    all)
        run_protocol_tests
        build_apps
        ;;
    *)
        print -u2 "Usage: $0 [protocol|apps|all]"
        exit 64
        ;;
esac
