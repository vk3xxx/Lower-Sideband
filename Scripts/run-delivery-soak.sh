#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "Usage: $0 <simulator-udid> <mac-destination> <simulator-destination> [automatic|local|public] [count]"
    print -u2 "Optional: SIDEBAND_SOAK_HOST/PORT, SIDEBAND_SOAK_INTERNET_HOST/PORT, identity hex values,"
    print -u2 "attachment/telemetry/voice/reconnect intervals, queue recovery, jitter and deadline."
    exit 64
}
[[ $# -ge 3 ]] || usage
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="$1"; MAC_DEST="$2"; SIM_DEST="$3"; MODE="${4:-automatic}"; COUNT="${5:-100}"
[[ "$MAC_DEST" =~ '^[0-9a-fA-F]{32}$' ]] || usage
[[ "$SIM_DEST" =~ '^[0-9a-fA-F]{32}$' ]] || usage
[[ "$COUNT" == <1-> ]] || usage

STAMP=$(date +%s)
# Build outside the iCloud-backed workspace. File-provider metadata on copied
# build products is rejected by codesign even though the source itself is
# valid, and made otherwise healthy acceptance runs fail before launch.
DERIVED="${SIDEBAND_SOAK_DERIVED_DATA:-${TMPDIR:-/tmp}/lower-sideband-interop-$STAMP}"
# The local evidence collector must read the report written by the macOS app.
# Disable signing only for this disposable debug product so App Sandbox does
# not put the report in a privacy-protected container. Distribution builds are
# unaffected and continue to use the production entitlements and signing.
COPYFILE_DISABLE=1 xcodebuild -project "$ROOT/MacSideband.xcodeproj" -scheme SidebandMac -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED/mac" build CODE_SIGNING_ALLOWED=NO >/dev/null
COPYFILE_DISABLE=1 xcodebuild -project "$ROOT/MacSideband.xcodeproj" -scheme SidebandIOS -configuration Debug -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED/ios" build >/dev/null
MAC_APP="$DERIVED/mac/Build/Products/Debug/Lower Sideband.app"
IOS_APP="$DERIVED/ios/Build/Products/Debug-iphonesimulator/Sideband.app"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$IOS_APP"

MAC_REPORT="interop-mac-$STAMP.json"; SIM_REPORT="interop-sim-$STAMP.json"
COMMON=(
  SIDEBAND_SOAK_NETWORK_MODE="$MODE"
  SIDEBAND_SOAK_COUNT="$COUNT"
  SIDEBAND_SOAK_HOST="${SIDEBAND_SOAK_HOST:-}"
  SIDEBAND_SOAK_PORT="${SIDEBAND_SOAK_PORT:-4242}"
  SIDEBAND_SOAK_INTERNET_HOST="${SIDEBAND_SOAK_INTERNET_HOST:-sydney.reticulum.au}"
  SIDEBAND_SOAK_INTERNET_PORT="${SIDEBAND_SOAK_INTERNET_PORT:-4242}"
  SIDEBAND_SOAK_ATTACHMENT_INTERVAL="${SIDEBAND_SOAK_ATTACHMENT_INTERVAL:-0}"
  SIDEBAND_SOAK_ATTACHMENT_BYTES="${SIDEBAND_SOAK_ATTACHMENT_BYTES:-1048576}"
  SIDEBAND_SOAK_TELEMETRY_INTERVAL="${SIDEBAND_SOAK_TELEMETRY_INTERVAL:-0}"
  SIDEBAND_SOAK_VOICE_INTERVAL="${SIDEBAND_SOAK_VOICE_INTERVAL:-0}"
  SIDEBAND_SOAK_RECONNECT_INTERVAL="${SIDEBAND_SOAK_RECONNECT_INTERVAL:-0}"
  SIDEBAND_SOAK_QUEUE_RECOVERY="${SIDEBAND_SOAK_QUEUE_RECOVERY:-0}"
  SIDEBAND_SOAK_JITTER_MIN_MS="${SIDEBAND_SOAK_JITTER_MIN_MS:-5}"
  SIDEBAND_SOAK_JITTER_MAX_MS="${SIDEBAND_SOAK_JITTER_MAX_MS:-45}"
  SIDEBAND_SOAK_DEADLINE_SECONDS="${SIDEBAND_SOAK_DEADLINE_SECONDS:-900}"
)
env "${COMMON[@]}" \
  NSUnbufferedIO=YES \
  SIDEBAND_SOAK_IDENTITY_HEX="${SIDEBAND_SOAK_MAC_IDENTITY_HEX:-}" \
  SIDEBAND_SOAK_DESTINATION="$SIM_DEST" \
  SIDEBAND_SOAK_OUTBOUND_PREFIX="SOAK-MAC-$STAMP" \
  SIDEBAND_SOAK_INBOUND_PREFIX="SOAK-SIM-$STAMP" \
  SIDEBAND_SOAK_REPORT="$MAC_REPORT" \
  "$MAC_APP/Contents/MacOS/Lower Sideband" >"$ROOT/.build/interop-mac.log" 2>&1 &
MAC_PID=$!
trap 'kill "$MAC_PID" 2>/dev/null || true; xcrun simctl terminate "$UDID" com.supes.MacSideband >/dev/null 2>&1 || true' EXIT

SIMCTL_CHILD_SIDEBAND_SOAK_NETWORK_MODE="$MODE" \
SIMCTL_CHILD_SIDEBAND_SOAK_COUNT="$COUNT" \
SIMCTL_CHILD_SIDEBAND_SOAK_HOST="${SIDEBAND_SOAK_HOST:-}" \
SIMCTL_CHILD_SIDEBAND_SOAK_PORT="${SIDEBAND_SOAK_PORT:-4242}" \
SIMCTL_CHILD_SIDEBAND_SOAK_INTERNET_HOST="${SIDEBAND_SOAK_INTERNET_HOST:-sydney.reticulum.au}" \
SIMCTL_CHILD_SIDEBAND_SOAK_INTERNET_PORT="${SIDEBAND_SOAK_INTERNET_PORT:-4242}" \
SIMCTL_CHILD_SIDEBAND_SOAK_ATTACHMENT_INTERVAL="${SIDEBAND_SOAK_ATTACHMENT_INTERVAL:-0}" \
SIMCTL_CHILD_SIDEBAND_SOAK_ATTACHMENT_BYTES="${SIDEBAND_SOAK_ATTACHMENT_BYTES:-1048576}" \
SIMCTL_CHILD_SIDEBAND_SOAK_TELEMETRY_INTERVAL="${SIDEBAND_SOAK_TELEMETRY_INTERVAL:-0}" \
SIMCTL_CHILD_SIDEBAND_SOAK_VOICE_INTERVAL="${SIDEBAND_SOAK_VOICE_INTERVAL:-0}" \
SIMCTL_CHILD_SIDEBAND_SOAK_RECONNECT_INTERVAL="${SIDEBAND_SOAK_RECONNECT_INTERVAL:-0}" \
SIMCTL_CHILD_SIDEBAND_SOAK_QUEUE_RECOVERY="${SIDEBAND_SOAK_QUEUE_RECOVERY:-0}" \
SIMCTL_CHILD_SIDEBAND_SOAK_JITTER_MIN_MS="${SIDEBAND_SOAK_JITTER_MIN_MS:-5}" \
SIMCTL_CHILD_SIDEBAND_SOAK_JITTER_MAX_MS="${SIDEBAND_SOAK_JITTER_MAX_MS:-45}" \
SIMCTL_CHILD_SIDEBAND_SOAK_DEADLINE_SECONDS="${SIDEBAND_SOAK_DEADLINE_SECONDS:-900}" \
SIMCTL_CHILD_SIDEBAND_SOAK_IDENTITY_HEX="${SIDEBAND_SOAK_SIM_IDENTITY_HEX:-}" \
SIMCTL_CHILD_SIDEBAND_SOAK_DESTINATION="$MAC_DEST" \
SIMCTL_CHILD_SIDEBAND_SOAK_OUTBOUND_PREFIX="SOAK-SIM-$STAMP" \
SIMCTL_CHILD_SIDEBAND_SOAK_INBOUND_PREFIX="SOAK-MAC-$STAMP" \
SIMCTL_CHILD_SIDEBAND_SOAK_REPORT="$SIM_REPORT" \
xcrun simctl launch --terminate-running-process "$UDID" com.supes.MacSideband >/dev/null

SIM_DATA=$(xcrun simctl get_app_container "$UDID" com.supes.MacSideband data)
MAC_PATH="$HOME/Library/Application Support/SidebandSwift/$MAC_REPORT"
SIM_PATH="$SIM_DATA/Library/Application Support/SidebandSwift/$SIM_REPORT"
deadline=$((SECONDS + ${SIDEBAND_SOAK_DEADLINE_SECONDS:-900} + 120))
while (( SECONDS < deadline )); do
    mac_complete=0; sim_complete=0
    [[ -f "$MAC_PATH" ]] && grep -q '"phase"[[:space:]]*:[[:space:]]*"complete"' "$MAC_PATH" && mac_complete=1
    [[ -f "$SIM_PATH" ]] && grep -q '"phase"[[:space:]]*:[[:space:]]*"complete"' "$SIM_PATH" && sim_complete=1
    if (( mac_complete && sim_complete )); then
        cp "$MAC_PATH" "$ROOT/.build/$MAC_REPORT"; cp "$SIM_PATH" "$ROOT/.build/$SIM_REPORT"
        print "PASS: $COUNT messages delivered with proofs in both directions ($MODE)."
        print "$ROOT/.build/$MAC_REPORT"
        print "$ROOT/.build/$SIM_REPORT"
        exit 0
    fi
    sleep 2
done
print -u2 "Delivery soak timed out. Inspect $MAC_PATH and $SIM_PATH"
exit 1
