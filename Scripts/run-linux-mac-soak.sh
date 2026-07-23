#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "Usage: $0 <signed-mac-app> <linux-lxmf-destination> [count]"
    print -u2 "Example: $0 '/Applications/Lower Sideband.app' e83856f0405047785a7609bf5f97b4a6 2500"
    exit 64
}

[[ $# -ge 2 ]] || usage
APP="$1"; DEST="${2:l}"; COUNT="${3:-2500}"
PLIST="$APP/Contents/Info.plist"
[[ -f "$PLIST" ]] || PLIST="$APP/Info.plist"
[[ -f "$PLIST" ]] || usage
EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null || true)"
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
[[ -x "$EXECUTABLE" ]] || EXECUTABLE="$APP/$EXECUTABLE_NAME"
[[ -x "$EXECUTABLE" ]] || usage
[[ "$DEST" =~ '^[0-9a-f]{32}$' ]] || usage
[[ "$COUNT" == <2500-> ]] || usage

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN_ID="${SIDEBAND_SOAK_RUN_ID:-LSB-INTERNET-$(date -u +%Y%m%dT%H%M%SZ)}"
RELEASE_UTC="${SIDEBAND_SOAK_RELEASE_UTC:-}"
REPORT="linux-mac-soak-$RUN_ID.json"
LOG="$ROOT/.build/linux-mac-soak-$RUN_ID.log"
mkdir -p "$ROOT/.build"

print "Run ID: $RUN_ID"
print "Mac outbound prefix: $RUN_ID-MAC"
print "Linux outbound prefix: $RUN_ID-LINUX"
print "Messages each direction: $COUNT"
print "Attachments: every 500th message; alternating 1 MiB binary and BMP image"
print "Topology: internet-only automatic public gateway selection; reconnect every 250 messages"
[[ -z "$RELEASE_UTC" ]] || print "Shared release UTC: $RELEASE_UTC"

env \
    SIDEBAND_SOAK_RUN_ID="$RUN_ID" \
    SIDEBAND_SOAK_RELEASE_UTC="$RELEASE_UTC" \
    SIDEBAND_SOAK_NETWORK_MODE=internet \
    SIDEBAND_SOAK_COUNT="$COUNT" \
    SIDEBAND_SOAK_DESTINATION="$DEST" \
    SIDEBAND_SOAK_OUTBOUND_PREFIX="$RUN_ID-MAC" \
    SIDEBAND_SOAK_INBOUND_PREFIX="$RUN_ID-LINUX" \
    SIDEBAND_SOAK_REPORT="$REPORT" \
    SIDEBAND_SOAK_ATTACHMENT_INTERVAL=500 \
    SIDEBAND_SOAK_ATTACHMENT_BYTES=1048576 \
    SIDEBAND_SOAK_RECONNECT_INTERVAL=250 \
    SIDEBAND_SOAK_JITTER_MIN_MS=25 \
    SIDEBAND_SOAK_JITTER_MAX_MS=350 \
    SIDEBAND_SOAK_DEADLINE_SECONDS=28800 \
    SIDEBAND_SOAK_PEER_TIMEOUT_SECONDS=900 \
    SIDEBAND_SOAK_PRESERVE=1 \
    "$EXECUTABLE" >"$LOG" 2>&1 &
PID=$!
print "Mac soak PID: $PID"
print "Mac log: $LOG"

SANDBOX_REPORT="$HOME/Library/Containers/com.supes.MacSideband/Data/Library/Application Support/SidebandSwift/$REPORT"
PLAIN_REPORT="$HOME/Library/Application Support/SidebandSwift/$REPORT"
while kill -0 "$PID" 2>/dev/null; do
    final_payload="$(sed -n 's/^SIDEBAND_SOAK_FINAL_JSON //p' "$LOG" | tail -n 1)"
    if [[ -n "$final_payload" ]]; then
        print -r -- "$final_payload" | base64 -D >"$ROOT/.build/$REPORT"
        phase="$(sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/.build/$REPORT" | head -n 1)"
        if [[ "$phase" == complete ]]; then
            print "PASS: $ROOT/.build/$REPORT"
            exit 0
        fi
        print -u2 "FAIL ($phase): $ROOT/.build/$REPORT"
        exit 1
    fi
    for candidate in "$SANDBOX_REPORT" "$PLAIN_REPORT"; do
        if [[ -f "$candidate" ]]; then
            cp "$candidate" "$ROOT/.build/$REPORT"
            phase="$(sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$candidate" | head -n 1)"
            if [[ "$phase" == complete ]]; then
                print "PASS: $ROOT/.build/$REPORT"
                exit 0
            fi
            if [[ "$phase" == *timeout || "$phase" == invalid-destination ]]; then
                print -u2 "FAIL ($phase): $ROOT/.build/$REPORT"
                exit 1
            fi
        fi
    done
    sleep 5
done
print -u2 "Mac soak process ended before a complete report was produced. Inspect $LOG."
exit 1
