#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${1:-fixtures}"
MESSAGE_COUNT="${SIDEBAND_UPSTREAM_MESSAGE_COUNT:-25}"
ATTACHMENT_INTERVAL="${SIDEBAND_UPSTREAM_ATTACHMENT_INTERVAL:-5}"
ATTACHMENT_BYTES="${SIDEBAND_UPSTREAM_ATTACHMENT_BYTES:-1048576}"
RECONNECT_INTERVAL="${SIDEBAND_UPSTREAM_RECONNECT_INTERVAL:-7}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_DIR="$ROOT/.build/upstream-matrix/$STAMP"
REPORT="$REPORT_DIR/result.json"

case "$PROFILE" in
    fixtures|live|all) ;;
    *)
        print -u2 "Usage: $0 [fixtures|live|all]"
        exit 64
        ;;
esac

mkdir -p "$REPORT_DIR"

typeset -A EXPECTED_TAGS=(
    Reticulum-Upstream 1.4.2
    LXMF-Upstream 1.1.0
    Sideband-Upstream 2.0.1
)

for repository expected in ${(kv)EXPECTED_TAGS}; do
    actual="$(git -C "$ROOT/$repository" describe --tags --exact-match 2>/dev/null || true)"
    if [[ "$actual" != "$expected" ]]; then
        print -u2 "$repository must be checked out at $expected (found ${actual:-untagged})."
        exit 1
    fi
done

PYTHONPATH="$ROOT/Reticulum-Upstream:$ROOT/LXMF-Upstream"
export PYTHONPATH
versions="$(
    python3 - <<'PY'
import json
import LXMF
import RNS
print(json.dumps({"reticulum": RNS.__version__, "lxmf": LXMF.__version__}, sort_keys=True))
PY
)"
[[ "$versions" == '{"lxmf": "1.1.0", "reticulum": "1.4.2"}' ]] || {
    print -u2 "Imported Python references do not match the pinned matrix: $versions"
    exit 1
}

fixture_status="not-run"
live_status="not-run"
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

if [[ "$PROFILE" == fixtures || "$PROFILE" == all ]]; then
    (
        cd "$ROOT"
        PYTHONPATH="$ROOT/Sideband-Upstream:$PYTHONPATH" python3 Scripts/verify-python-telemetry.py
        swift test --no-parallel
    ) >"$REPORT_DIR/fixtures.log" 2>&1
    fixture_status="passed"
fi

if [[ "$PROFILE" == live || "$PROFILE" == all ]]; then
    (
        cd "$ROOT"
        Scripts/run-local-python-interop.sh \
            "$MESSAGE_COUNT" \
            "$ATTACHMENT_INTERVAL" \
            "$ATTACHMENT_BYTES" \
            "$RECONNECT_INTERVAL"
    ) >"$REPORT_DIR/live.log" 2>&1
    live_status="passed"
fi

completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export PROFILE MESSAGE_COUNT ATTACHMENT_INTERVAL ATTACHMENT_BYTES RECONNECT_INTERVAL
export REPORT fixture_status live_status started_at completed_at
python3 - <<'PY'
import json
import os
from pathlib import Path

report = {
    "schema": 1,
    "profile": os.environ["PROFILE"],
    "started_at": os.environ["started_at"],
    "completed_at": os.environ["completed_at"],
    "references": {
        "reticulum": "1.4.2",
        "lxmf": "1.1.0",
        "sideband": "2.0.1",
    },
    "fixtures": os.environ["fixture_status"],
    "live": os.environ["live_status"],
    "live_parameters": {
        "messages_each_direction": int(os.environ["MESSAGE_COUNT"]),
        "attachment_interval": int(os.environ["ATTACHMENT_INTERVAL"]),
        "attachment_bytes": int(os.environ["ATTACHMENT_BYTES"]),
        "reconnect_interval": int(os.environ["RECONNECT_INTERVAL"]),
    },
}
Path(os.environ["REPORT"]).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
PY

print "Upstream interoperability matrix passed."
print "Profile: $PROFILE"
print "References: Reticulum 1.4.2 · LXMF 1.1.0 · Sideband 2.0.1"
print "Report: $REPORT"
