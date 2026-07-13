#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-generic/platform=iOS Simulator}"

case "$DESTINATION" in
    *"iOS Simulator"*)
        SDK_DIRECTORY="Debug-iphonesimulator"
        DERIVED_DATA="$ROOT/.build/ios-simulator-derived"
        ;;
    *"platform=iOS"*)
        SDK_DIRECTORY="Debug-iphoneos"
        DERIVED_DATA="$ROOT/.build/ios-device-derived"
        ;;
    *)
        echo "Unsupported destination: $DESTINATION" >&2
        echo "Use 'generic/platform=iOS Simulator' or 'generic/platform=iOS'." >&2
        exit 2
        ;;
esac

cd "$ROOT"

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate >/dev/null
else
    echo "xcodegen not found; using the committed Xcode project."
fi

rm -rf "$DERIVED_DATA"

xcodebuild \
    -project MacSideband.xcodeproj \
    -scheme SidebandIOS \
    -configuration Debug \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

APP="$DERIVED_DATA/Build/Products/$SDK_DIRECTORY/Sideband.app"
PLIST="$APP/Info.plist"
CORE_PLIST="$APP/Frameworks/SidebandCore.framework/Info.plist"
APP_PRIVACY="$APP/PrivacyInfo.xcprivacy"
CORE_PRIVACY="$APP/Frameworks/SidebandCore.framework/PrivacyInfo.xcprivacy"

if [[ ! -d "$APP" ]]; then
    echo "Expected application bundle was not produced: $APP" >&2
    exit 1
fi

plutil -lint "$PLIST" >/dev/null
plutil -lint "$CORE_PLIST" >/dev/null

for privacy_manifest in "$APP_PRIVACY" "$CORE_PRIVACY"; do
    if [[ ! -f "$privacy_manifest" ]]; then
        echo "Privacy manifest was not bundled: $privacy_manifest" >&2
        exit 1
    fi
    plutil -lint "$privacy_manifest" >/dev/null
    privacy_contents="$(plutil -convert json -o - "$privacy_manifest")"
    if ! grep -q 'NSPrivacyAccessedAPICategoryUserDefaults' <<<"$privacy_contents" || \
       ! grep -q 'NSPrivacyAccessedAPICategoryFileTimestamp' <<<"$privacy_contents"; then
        echo "Privacy manifest is missing a required-reason API category: $privacy_manifest" >&2
        exit 1
    fi
done

assert_plist_value() {
    local key="$1"
    local expected="$2"
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST")"
    if [[ "$actual" != "$expected" ]]; then
        echo "Info.plist $key is '$actual'; expected '$expected'." >&2
        exit 1
    fi
}

assert_plist_value CFBundleIdentifier com.supes.MacSideband
assert_plist_value CFBundleShortVersionString 0.2.0
assert_plist_value CFBundleVersion 10
assert_plist_value NSBonjourServices:0 _reticulum._tcp
assert_plist_value NSBonjourServices:1 _rns._tcp
assert_plist_value NSBonjourServices:2 _sideband._tcp
assert_plist_value BGTaskSchedulerPermittedIdentifiers:0 com.supes.MacSideband.refresh

assert_core_plist_value() {
    local key="$1"
    local expected="$2"
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$CORE_PLIST")"
    if [[ "$actual" != "$expected" ]]; then
        echo "SidebandCore Info.plist $key is '$actual'; expected '$expected'." >&2
        exit 1
    fi
}

assert_core_plist_value CFBundleShortVersionString 0.2.0
assert_core_plist_value CFBundleVersion 10

for required_key in \
    NSLocalNetworkUsageDescription \
    NSLocationWhenInUseUsageDescription \
    CFBundleURLTypes \
    UIBackgroundModes; do
    if ! /usr/libexec/PlistBuddy -c "Print :$required_key" "$PLIST" >/dev/null 2>&1; then
        echo "Info.plist is missing $required_key." >&2
        exit 1
    fi
done

if find "$APP" -type f \( \
    -iname '*.py' -o \
    -iname '*.pyc' -o \
    -iname '*python*' -o \
    -iname '*Sideband-Upstream*' -o \
    -iname '*Reticulum-Upstream*' -o \
    -iname '*LXMF-Upstream*' \
\) -print -quit | grep -q .; then
    echo "Python or upstream reference artifacts were bundled into the app." >&2
    exit 1
fi

while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q 'Mach-O'; then
        if otool -L "$candidate" | grep -Eiq 'python|libpy'; then
            echo "Python-linked Mach-O file found: $candidate" >&2
            exit 1
        fi
    fi
done < <(find "$APP" -type f -print0)

echo "Validated native iOS application bundle: $APP"
