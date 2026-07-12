#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
UPSTREAM="$ROOT/ThirdParty/mdict-cpp"
WORK="$ROOT/.build/obsidian-note-smoke"
OBJECTS="$WORK/objects"
STRUCTURED_JSON="$WORK/structured-entries.json"
mkdir -p "$OBJECTS" "$WORK/module-cache"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    elif [[ -d "$HOME/Downloads/Xcode.app/Contents/Developer" ]]; then
        export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
    fi
fi

CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"
SWIFTC="$(xcrun --find swiftc)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

for source in miniz.c miniz_tinfl.c miniz_tdef.c miniz_zip.c; do
    "$CC" -O0 -isysroot "$SDKROOT" -I"$UPSTREAM/deps/miniz" \
        -c "$UPSTREAM/deps/miniz/$source" -o "$OBJECTS/${source%.c}.o"
done
"$CC" -O0 -isysroot "$SDKROOT" -c "$UPSTREAM/src/ripemd128.c" \
    -o "$OBJECTS/ripemd128.o"

for source in mdict.cc binutils.cc adler32.cc; do
    "$CXX" -std=c++17 -O0 -isysroot "$SDKROOT" \
        -I"$UPSTREAM/src" -I"$UPSTREAM/src/include" \
        -I"$UPSTREAM/deps" -I"$UPSTREAM/deps/turbobase64" \
        -c "$UPSTREAM/src/$source" -o "$OBJECTS/${source%.cc}.o"
done

"$CXX" -std=c++17 -O0 -fobjc-arc -isysroot "$SDKROOT" \
    -I"$ROOT/App" -I"$ROOT/MDictCore" \
    -I"$UPSTREAM/src" -I"$UPSTREAM/src/include" \
    -I"$UPSTREAM/deps" -I"$UPSTREAM/deps/turbobase64" \
    -I"$SDKROOT/usr/include/libxml2" \
    "$ROOT/MDictCore/SQLiteDictionaryCore.cpp" \
    "$ROOT/App/OxfordEntryFormatter.mm" \
    "$ROOT/Tests/OxfordStructuredEntrySmoke.mm" \
    "$OBJECTS/mdict.o" "$OBJECTS/binutils.o" "$OBJECTS/adler32.o" \
    "$OBJECTS/ripemd128.o" "$OBJECTS/miniz.o" \
    "$OBJECTS/miniz_tinfl.o" "$OBJECTS/miniz_tdef.o" "$OBJECTS/miniz_zip.o" \
    -lsqlite3 -lxml2 -framework AppKit -framework Foundation \
    -o "$WORK/oxford-structured-entry-smoke"

"$WORK/oxford-structured-entry-smoke" "$ROOT/config/local.json" "$STRUCTURED_JSON"

"$SWIFTC" -sdk "$SDKROOT" -module-cache-path "$WORK/module-cache" \
    "$ROOT/App/ObsidianNoteStore.swift" \
    "$ROOT/Tests/ObsidianNoteStoreSmoke.swift" \
    -o "$WORK/obsidian-note-store-smoke"
"$WORK/obsidian-note-store-smoke" "$STRUCTURED_JSON" "$WORK"
