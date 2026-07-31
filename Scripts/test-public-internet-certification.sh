#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$(mktemp -t lower-sideband-certification).json"
trap 'rm -f "$OUTPUT"' EXIT

SIDEBAND_CERT_MIN_MESSAGES=5 \
SIDEBAND_CERT_MIN_ROUTES=2 \
SIDEBAND_CERTIFICATE_PATH="$OUTPUT" \
"$ROOT/Scripts/validate-public-internet-certification.swift" \
  "$ROOT/Tests/Fixtures/public-internet-route-a.json" \
  "$ROOT/Tests/Fixtures/public-internet-route-b.json"

grep -q '"result" : "pass"' "$OUTPUT"
grep -q '"forcedReconnects" : 2' "$OUTPUT"
grep -q 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$OUTPUT"
print "Public-Internet certification fixture test passed."
