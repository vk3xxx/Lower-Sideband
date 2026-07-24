#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COUNT="${1:-5}"
ATTACHMENT_INTERVAL="${2:-0}"
ATTACHMENT_BYTES="${3:-1048576}"
RECONNECT_INTERVAL="${4:-0}"
[[ "$COUNT" == <1-> ]] || {
    print -u2 "Usage: $0 [message-count] [attachment-interval] [attachment-bytes]"
    exit 64
}

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_ID="LSB-LOCAL-PYTHON-$STAMP"
RUN_DIR="$ROOT/.build/local-python-interop/$RUN_ID"
PEER_CONFIG="$RUN_DIR/peer"
PEER_STORAGE="$RUN_DIR/peer-storage"
DERIVED="${TMPDIR:-/tmp}/LowerSidebandLocalInteropDerived"
PORT="${SIDEBAND_LOCAL_INTEROP_PORT:-44242}"
SWIFT_PREFIX="$RUN_ID-SWIFT"
PYTHON_PREFIX="$RUN_ID-PYTHON"
SWIFT_IDENTITY_HEX="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
PYTHONPATH="$ROOT/Reticulum-Upstream:$ROOT/LXMF-Upstream"

mkdir -p "$PEER_CONFIG" "$PEER_STORAGE" "$RUN_DIR"

xcodebuild \
    -project "$ROOT/MacSideband.xcodeproj" \
    -scheme SidebandMac \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO \
    build >"$RUN_DIR/xcodebuild.log"

APP_EXECUTABLE="$DERIVED/Build/Products/Debug/Lower Sideband.app/Contents/MacOS/Lower Sideband"
APP_BUNDLE="$DERIVED/Build/Products/Debug/Lower Sideband.app"
xattr -cr "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

print -r -- "[reticulum]
enable_transport = No
share_instance = No
instance_name = lsb-local-peer-$STAMP

[logging]
loglevel = 6

[interfaces]
  [[Reference TCP Server]]
    type = TCPServerInterface
    enabled = Yes
    listen_ip = 127.0.0.1
    listen_port = $PORT
    mode = full
" >"$PEER_CONFIG/config"

PEER_PID=""
SWIFT_PID=""
cleanup() {
    if [[ -n "$SWIFT_PID" ]]; then
        kill "$SWIFT_PID" 2>/dev/null || true
        pkill -f "$APP_BUNDLE/Contents/MacOS/Lower Sideband" 2>/dev/null || true
    fi
    [[ -z "$PEER_PID" ]] || kill "$PEER_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

env PYTHONUNBUFFERED=1 PYTHONPATH="$PYTHONPATH" python3 "$ROOT/Scripts/local-python-lxmf-peer.py" \
    --config "$PEER_CONFIG" \
    --storage "$PEER_STORAGE" \
    --report "$RUN_DIR/python-report.json" \
    --inbound-prefix "$SWIFT_PREFIX" \
    --outbound-prefix "$PYTHON_PREFIX" \
    --count "$COUNT" \
    --timeout 600 \
    >"$RUN_DIR/python-peer.log" 2>&1 &
PEER_PID=$!

deadline=$((SECONDS + 30))
while ! grep -q '^PYTHON_PEER_READY ' "$RUN_DIR/python-peer.log" 2>/dev/null; do
    if ! kill -0 "$PEER_PID" 2>/dev/null; then
        print -u2 "Local Python LXMF peer exited during startup."
        tail -120 "$RUN_DIR/python-peer.log" >&2
        exit 1
    fi
    if (( SECONDS >= deadline )); then
        print -u2 "Local Python LXMF peer did not become ready."
        tail -120 "$RUN_DIR/python-peer.log" >&2
        exit 1
    fi
    sleep 0.1
done

PEER_DESTINATION="$(
    sed -n 's/^PYTHON_PEER_READY .*"destination": "\([0-9a-f]*\)".*/\1/p' \
        "$RUN_DIR/python-peer.log" | tail -1
)"
[[ ${#PEER_DESTINATION} -eq 32 ]] || {
    print -u2 "Could not determine the Python peer destination."
    exit 1
}

SWIFT_REPORT="$RUN_DIR/swift-report.json"
APP_ENV=(
    --env "SIDEBAND_SOAK_RUN_ID=$RUN_ID"
    --env "SIDEBAND_SOAK_IDENTITY_ACCOUNT=$RUN_ID"
    --env "SIDEBAND_SOAK_IDENTITY_HEX=$SWIFT_IDENTITY_HEX"
    --env "SIDEBAND_SOAK_NETWORK_MODE=local"
    --env "SIDEBAND_SOAK_HOST=127.0.0.1"
    --env "SIDEBAND_SOAK_PORT=$PORT"
    --env "SIDEBAND_SOAK_COUNT=$COUNT"
    --env "SIDEBAND_SOAK_DESTINATION=$PEER_DESTINATION"
    --env "SIDEBAND_SOAK_OUTBOUND_PREFIX=$SWIFT_PREFIX"
    --env "SIDEBAND_SOAK_INBOUND_PREFIX=$PYTHON_PREFIX"
    --env "SIDEBAND_SOAK_REPORT=swift-report.json"
    --env "SIDEBAND_SOAK_REPORT_PATH=$SWIFT_REPORT"
    --env "SIDEBAND_SOAK_ATTACHMENT_INTERVAL=$ATTACHMENT_INTERVAL"
    --env "SIDEBAND_SOAK_ATTACHMENT_BYTES=$ATTACHMENT_BYTES"
    --env "SIDEBAND_SOAK_ATTACHMENTS_ARE_ECHOED=1"
    --env "SIDEBAND_SOAK_RECONNECT_INTERVAL=$RECONNECT_INTERVAL"
    --env "SIDEBAND_SOAK_JITTER_MIN_MS=1"
    --env "SIDEBAND_SOAK_JITTER_MAX_MS=5"
    --env "SIDEBAND_SOAK_DEADLINE_SECONDS=600"
    --env "SIDEBAND_SOAK_PEER_TIMEOUT_SECONDS=60"
    --env "NSUnbufferedIO=YES"
)
open -n -F -W \
    -o "$RUN_DIR/swift.log" \
    --stderr "$RUN_DIR/swift.err" \
    "${APP_ENV[@]}" \
    "$APP_BUNDLE" &
SWIFT_PID=$!

print "Local interop run: $RUN_ID"
print "Python destination: $PEER_DESTINATION"
print "Messages each direction: $COUNT"
print "Attachments: every $ATTACHMENT_INTERVAL message(s)"
print "Artifacts: $RUN_DIR"

deadline=$((SECONDS + 660))
while (( SECONDS < deadline )); do
    swift_phase="$(
        sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$SWIFT_REPORT" 2>/dev/null | head -1 || true
    )"
    python_phase="$(
        sed -n 's/.*"phase"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            "$RUN_DIR/python-report.json" 2>/dev/null | head -1 || true
    )"
    if [[ "$swift_phase" == complete && "$python_phase" == complete ]]; then
        print "PASS: upstream Python RNS/LXMF and native Swift delivered $COUNT/$COUNT messages with proofs."
        print "$SWIFT_REPORT"
        print "$RUN_DIR/python-report.json"
        exit 0
    fi
    if [[ "$swift_phase" == *timeout || "$python_phase" == timeout || "$python_phase" == failed ]]; then
        print -u2 "FAIL: Swift phase=$swift_phase Python phase=$python_phase"
        tail -160 "$RUN_DIR/swift.log" >&2
        tail -160 "$RUN_DIR/python-peer.log" >&2
        exit 1
    fi
    if ! kill -0 "$SWIFT_PID" 2>/dev/null && [[ "$swift_phase" != complete ]]; then
        print -u2 "Swift client exited before producing a complete report."
        tail -160 "$RUN_DIR/swift.log" >&2
        exit 1
    fi
    if ! kill -0 "$PEER_PID" 2>/dev/null && [[ "$python_phase" != complete ]]; then
        print -u2 "Python reference peer exited before producing a complete report."
        tail -160 "$RUN_DIR/python-peer.log" >&2
        exit 1
    fi
    sleep 0.25
done

print -u2 "Local Python/Swift interoperability test timed out."
tail -160 "$RUN_DIR/swift.log" >&2
tail -160 "$RUN_DIR/python-peer.log" >&2
exit 1
