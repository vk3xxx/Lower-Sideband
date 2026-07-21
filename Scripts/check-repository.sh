#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

fail() {
    echo "Repository check failed: $*" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || fail "git is required"

git diff --check

marketing_versions=$(awk '/MARKETING_VERSION:/ { print $2 }' project.yml | sort -u)
build_versions=$(awk '/CURRENT_PROJECT_VERSION:/ { print $2 }' project.yml | sort -u)

[ "$(printf '%s\n' "$marketing_versions" | sed '/^$/d' | wc -l | tr -d ' ')" = "1" ] || \
    fail "project.yml contains inconsistent marketing versions"
[ "$(printf '%s\n' "$build_versions" | sed '/^$/d' | wc -l | tr -d ' ')" = "1" ] || \
    fail "project.yml contains inconsistent build versions"
[ "$(grep -c 'MARKETING_VERSION:' project.yml)" = "4" ] || \
    fail "all four targets must declare MARKETING_VERSION"
[ "$(grep -c 'CURRENT_PROJECT_VERSION:' project.yml)" = "4" ] || \
    fail "all four targets must declare CURRENT_PROJECT_VERSION"
[ "$(grep -c 'DEVELOPMENT_TEAM: DLV44BUBE7' project.yml)" = "1" ] || \
    fail "project.yml must use the configured personal development team"

for required in \
    README.md CHANGELOG.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md \
    PRIVACY.md SUPPORT.md PORTING.md \
    docs/ARCHITECTURE.md docs/BUILDING.md docs/NETWORKING.md \
    docs/RNODE.md docs/TESTING.md docs/ROADMAP.md; do
    [ -s "$required" ] || fail "missing required documentation: $required"
done

if grep -ERq '^[[:space:]]+(push|pull_request):' .github/workflows --include='*.yml' --include='*.yaml'; then
    fail "GitHub Actions must remain manual-only"
fi

if find Sources Support -type f \( -name '*.py' -o -name '*.pyc' \) -print -quit | grep -q .; then
    fail "Python artifacts are present in application source or support files"
fi

if git ls-files | grep -Eq '^MacSideband [0-9]+\.xcodeproj/'; then
    fail "a numbered Xcode project copy is tracked"
fi

echo "Repository metadata is consistent: version $marketing_versions ($build_versions)."
