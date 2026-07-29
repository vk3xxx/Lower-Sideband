#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if (( $# < 1 )); then
    print -u2 "Usage: $0 <completed-soak-report.json> [completed-soak-report.json ...]"
    print -u2 "Reports must come from Internet-only DeliverySoakRunner runs on independent routes."
    exit 64
fi

for report in "$@"; do
    [[ -f "$report" ]] || { print -u2 "Missing report: $report"; exit 66; }
done

exec "$ROOT/Scripts/validate-public-internet-certification.swift" "$@"
