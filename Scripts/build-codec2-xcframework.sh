#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/Vendor/Codec2.xcframework}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lower-sideband-codec2.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

for command in git cmake xcodebuild python3; do
    command -v "$command" >/dev/null 2>&1 || { echo "Missing required tool: $command" >&2; exit 1; }
done

git clone --quiet --depth 1 --branch 1.2.0 https://github.com/drowe67/codec2.git "$WORK/source"
cmake -S "$WORK/source" -B "$WORK/native" -G "Unix Makefiles" -DUNITTEST=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build "$WORK/native" --target generate_codebook --parallel

CODEBOOK_GENERATOR="$WORK/native/src/generate_codebook"
export CODEBOOK_GENERATOR
python3 - "$WORK/source/src/CMakeLists.txt" <<'PY'
import os, pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
replacement = '''if(CMAKE_CROSSCOMPILING)
    add_executable(generate_codebook IMPORTED)
    set_target_properties(generate_codebook PROPERTIES
        IMPORTED_LOCATION "$ENV{CODEBOOK_GENERATOR}")
else(CMAKE_CROSSCOMPILING)'''
text, count = re.subn(r'if\(CMAKE_CROSSCOMPILING\).*?else\(CMAKE_CROSSCOMPILING\)', replacement, text, count=1, flags=re.S)
if count != 1:
    raise SystemExit("Codec2 cross-build block was not recognised")
path.write_text(text)
PY

build_codec2() {
    name="$1"; sdk="$2"; architectures="$3"; system_name="${4:-}"
    build="$WORK/$name"
    system_argument=""
    if [ -n "$system_name" ]; then system_argument="-DCMAKE_SYSTEM_NAME=$system_name"; fi
    cmake -S "$WORK/source" -B "$build" -G Xcode \
        -DBUILD_SHARED_LIBS=OFF -DUNITTEST=OFF $system_argument \
        "-DCMAKE_OSX_SYSROOT=$sdk" "-DCMAKE_OSX_ARCHITECTURES=$architectures" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$( [ "$sdk" = macosx ] && echo 14.0 || echo 17.0 )" \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build "$build" --config Release --target codec2 --parallel
}

build_codec2 ios-device iphoneos arm64 iOS
build_codec2 ios-simulator iphonesimulator "arm64;x86_64" iOS
build_codec2 macos macosx "arm64;x86_64"

mkdir -p "$WORK/headers/codec2" "$(dirname "$OUTPUT")"
cp "$WORK/source/src/codec2.h" "$WORK/headers/codec2.h"
cp "$WORK/ios-device/codec2/version.h" "$WORK/headers/codec2/version.h"
printf '%s\n' 'module CCodec2 [system] {' '    header "codec2.h"' '    export *' '}' > "$WORK/headers/module.modulemap"

if [ -e "$OUTPUT" ]; then rm -rf "$OUTPUT"; fi
xcodebuild -create-xcframework \
    -library "$WORK/ios-device/src/Release-iphoneos/libcodec2.a" -headers "$WORK/headers" \
    -library "$WORK/ios-simulator/src/Release-iphonesimulator/libcodec2.a" -headers "$WORK/headers" \
    -library "$WORK/macos/src/Release/libcodec2.a" -headers "$WORK/headers" \
    -output "$OUTPUT"
cp "$WORK/source/COPYING" "$ROOT/Vendor/CODEC2-LICENSE.txt"
echo "Created $OUTPUT from Codec2 1.2.0"
