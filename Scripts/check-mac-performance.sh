#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  print -u2 "usage: $0 <pid> [seconds]"
  exit 64
fi

pid="$1"
duration="${2:-60}"
if ! kill -0 "$pid" 2>/dev/null; then
  print -u2 "Lower Sideband process $pid is not running"
  exit 69
fi

report="${TMPDIR:-/tmp}/lower-sideband-performance-${pid}-$(date -u +%Y%m%dT%H%M%SZ).csv"
print 'utc,cpu_percent,resident_kib,threads' > "$report"

typeset -F cpu_total=0
typeset -i samples=0 max_rss=0
for ((second = 0; second < duration; second++)); do
  row="$(ps -p "$pid" -o %cpu=,rss= | xargs)"
  [[ -n "$row" ]] || break
  cpu="${row%% *}"
  rss="${row##* }"
  threads="$(ps -M -p "$pid" | awk 'NR > 1 { count += 1 } END { print count + 0 }')"
  print "$(date -u +%FT%TZ),$cpu,$rss,$threads" >> "$report"
  cpu_total=$((cpu_total + cpu))
  (( rss > max_rss )) && max_rss=$rss
  ((samples += 1))
  sleep 1
done

if (( samples == 0 )); then
  print -u2 "No samples were collected"
  exit 70
fi

average_cpu=$((cpu_total / samples))
print "report=$report"
printf 'samples=%d average_cpu=%.2f%% peak_resident=%.1fMiB\n' \
  "$samples" "$average_cpu" "$((max_rss / 1024.0))"
