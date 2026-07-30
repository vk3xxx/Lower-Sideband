#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 /path/to/Application.app" >&2
    exit 64
fi

app_path="$1"
if [[ ! -d "$app_path" ]]; then
    echo "Application bundle not found: $app_path" >&2
    exit 66
fi

if [[ -d "$app_path/Contents/Frameworks" ]]; then
    frameworks_path="$app_path/Contents/Frameworks"
else
    frameworks_path="$app_path/Frameworks"
fi

missing=0
checked=0

while IFS= read -r -d '' candidate; do
    if ! file -b "$candidate" | grep -q 'Mach-O'; then
        continue
    fi

    while IFS= read -r dependency; do
        framework_name="$(sed -E 's#^@rpath/([^/]+\.framework)/.*#\1#' <<<"$dependency")"
        if [[ "$framework_name" == "$dependency" ]]; then
            continue
        fi

        checked=$((checked + 1))
        if [[ ! -d "$frameworks_path/$framework_name" ]]; then
            echo "Missing runtime dependency: $framework_name (referenced by $candidate)" >&2
            missing=$((missing + 1))
        fi
    done < <(otool -L "$candidate" | awk 'NR > 1 {print $1}' | grep '^@rpath/' || true)
done < <(find "$app_path" -type f -print0)

if [[ $missing -ne 0 ]]; then
    echo "Runtime dependency audit failed with $missing missing framework(s)." >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Runtime dependency audit passed: $checked embedded framework reference(s) verified."
