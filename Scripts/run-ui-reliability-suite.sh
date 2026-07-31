#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="${SIDEBAND_UI_RESULTS_DIR:-$ROOT/.build/ui-reliability}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
MODE="${1:-all}"
mkdir -p "$RESULTS"

run_suite() {
  local scheme="$1"
  local destination="$2"
  local name="$3"
  xcodebuild test \
    -project "$ROOT/MacSideband.xcodeproj" \
    -scheme "$scheme" \
    -destination "$destination" \
    -resultBundlePath "$RESULTS/$STAMP-$name.xcresult"
}

if [[ "$MODE" == "all" || "$MODE" == "iphone" ]]; then
  run_suite SidebandIOS "${SIDEBAND_UI_IPHONE_DESTINATION:-platform=iOS Simulator,name=iPhone 17 Pro,OS=latest}" iphone
fi
if [[ "$MODE" == "all" || "$MODE" == "ipad" ]]; then
  run_suite SidebandIOS "${SIDEBAND_UI_IPAD_DESTINATION:-platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=latest}" ipad
fi
if [[ "$MODE" == "all" || "$MODE" == "mac" ]]; then
  run_suite SidebandMac "platform=macOS" mac
fi

echo "UI reliability artifacts: $RESULTS"
