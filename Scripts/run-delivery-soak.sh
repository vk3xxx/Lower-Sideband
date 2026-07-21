#!/bin/zsh
set -euo pipefail

usage() {
    print -u2 "Usage: $0 <simulator-udid> <mac-destination> <simulator-destination> [automatic|local|public] [count]"
    print -u2 "Optional endpoint: SIDEBAND_SOAK_HOST and SIDEBAND_SOAK_PORT"
    exit 64
}
[[ $# -ge 3 ]] || usage
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="$1"; MAC_DEST="$2"; SIM_DEST="$3"; MODE="${4:-automatic}"; COUNT="${5:-100}"
[[ "$MAC_DEST" == [0-9a-fA-F]## && ${#MAC_DEST} -eq 32 ]] || usage
[[ "$SIM_DEST" == [0-9a-fA-F]## && ${#SIM_DEST} -eq 32 ]] || usage
[[ "$COUNT" == <1-> ]] || usage

DERIVED="$ROOT/.build/interop-derived"
xcodebuild -project "$ROOT/MacSideband.xcodeproj" -scheme SidebandMac -configuration Debug -destination 'platform=macOS' -derivedDataPath "$DERIVED/mac" build >/dev/null
xcodebuild -project "$ROOT/MacSideband.xcodeproj" -scheme SidebandIOS -configuration Debug -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED/ios" build >/dev/null
MAC_APP="$DERIVED/mac/Build/Products/Debug/Lower Sideband.app"
IOS_APP="$DERIVED/ios/Build/Products/Debug-iphonesimulator/Sideband.app"
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$IOS_APP"

STAMP=$(date +%s)
MAC_REPORT="interop-mac-$STAMP.json"; SIM_REPORT="interop-sim-$STAMP.json"
COMMON=(SIDEBAND_SOAK_NETWORK_MODE="$MODE" SIDEBAND_SOAK_COUNT="$COUNT" SIDEBAND_SOAK_HOST="${SIDEBAND_SOAK_HOST:-}" SIDEBAND_SOAK_PORT="${SIDEBAND_SOAK_PORT:-4242}")
env "${COMMON[@]}" SIDEBAND_SOAK_DESTINATION="$SIM_DEST" SIDEBAND_SOAK_OUTBOUND_PREFIX="SOAK-MAC-$STAMP" SIDEBAND_SOAK_INBOUND_PREFIX="SOAK-SIM-$STAMP" SIDEBAND_SOAK_REPORT="$MAC_REPORT" "$MAC_APP/Contents/MacOS/Lower Sideband" >"$ROOT/.build/interop-mac.log" 2>&1 &
MAC_PID=$!
trap 'kill "$MAC_PID" 2>/dev/null || true; xcrun simctl terminate "$UDID" com.supes.MacSideband >/dev/null 2>&1 || true' EXIT

SIMCTL_CHILD_SIDEBAND_SOAK_NETWORK_MODE="$MODE" \
SIMCTL_CHILD_SIDEBAND_SOAK_COUNT="$COUNT" \
SIMCTL_CHILD_SIDEBAND_SOAK_HOST="${SIDEBAND_SOAK_HOST:-}" \
SIMCTL_CHILD_SIDEBAND_SOAK_PORT="${SIDEBAND_SOAK_PORT:-4242}" \
SIMCTL_CHILD_SIDEBAND_SOAK_DESTINATION="$MAC_DEST" \
SIMCTL_CHILD_SIDEBAND_SOAK_OUTBOUND_PREFIX="SOAK-SIM-$STAMP" \
SIMCTL_CHILD_SIDEBAND_SOAK_INBOUND_PREFIX="SOAK-MAC-$STAMP" \
SIMCTL_CHILD_SIDEBAND_SOAK_REPORT="$SIM_REPORT" \
xcrun simctl launch --terminate-running "$UDID" com.supes.MacSideband >/dev/null

SIM_DATA=$(xcrun simctl get_app_container "$UDID" com.supes.MacSideband data)
MAC_PATH="$HOME/Library/Application Support/SidebandSwift/$MAC_REPORT"
SIM_PATH="$SIM_DATA/Library/Application Support/SidebandSwift/$SIM_REPORT"
deadline=$((SECONDS + 720))
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
