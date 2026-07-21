#!/bin/zsh
set -euo pipefail

# Read-only reachability and dual-stack health probe. It never changes DNS or
# gateway configuration. Lines are: label|host|port.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT="${1:-$ROOT/Infrastructure/gateways.txt}"
TIMEOUT="${SIDEBAND_GATEWAY_TIMEOUT:-5}"
[[ -f "$INPUT" ]] || { print -u2 "Missing gateway list: $INPUT"; exit 64; }

failures=0
while IFS='|' read -r label host port; do
    [[ -z "$label" || "$label" == \#* ]] && continue
    started=$(date +%s)
    if nc -z -G "$TIMEOUT" "$host" "$port" >/dev/null 2>&1; then
        elapsed=$(( $(date +%s) - started ))
        print "PASS $label $host:$port ${elapsed}s"
    else
        print "FAIL $label $host:$port"
        failures=$((failures + 1))
    fi
done < "$INPUT"
(( failures == 0 )) || exit 1
