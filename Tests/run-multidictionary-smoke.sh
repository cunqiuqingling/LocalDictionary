#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
UPSTREAM="$ROOT/ThirdParty/vendor/mdict-cpp"
MINIZ="$ROOT/ThirdParty/vendor/miniz"
LIBTOMCRYPT="$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128"
WORK="$ROOT/.build/multidictionary-smoke"
OBJECTS="$WORK/objects"
FIXTURE="$WORK/real-multi-source.json"
NOTES="$WORK/notes"
mkdir -p "$OBJECTS" "$WORK/module-cache" "$NOTES"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"
SWIFTC="$(xcrun --find swiftc)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

for source in miniz.c miniz_tinfl.c miniz_tdef.c; do
    "$CC" -O0 -isysroot "$SDKROOT" -I"$MINIZ" \
        -c "$MINIZ/$source" -o "$OBJECTS/${source%.c}.o"
done
"$CC" -O0 -isysroot "$SDKROOT" -I"$LIBTOMCRYPT/include" \
    -c "$LIBTOMCRYPT/src/rmd128.c" -o "$OBJECTS/rmd128.o"
"$CC" -O0 -isysroot "$SDKROOT" -I"$ROOT/MDictCore" \
    -I"$LIBTOMCRYPT/include" -c "$ROOT/MDictCore/RIPEMD128Adapter.c" \
    -o "$OBJECTS/ripemd128-adapter.o"
for source in mdict.cc binutils.cc adler32.cc; do
    "$CXX" -std=c++17 -O0 -isysroot "$SDKROOT" \
        -I"$UPSTREAM/src" -I"$UPSTREAM/src/include" \
        -I"$ROOT/MDictCore" -I"$ROOT/ThirdParty/vendor" \
        -c "$UPSTREAM/src/$source" -o "$OBJECTS/${source%.cc}.o"
done

"$CXX" -std=c++17 -O0 -fobjc-arc -isysroot "$SDKROOT" \
    -I"$ROOT/App" -I"$ROOT/MDictCore" \
    -I"$UPSTREAM/src" -I"$UPSTREAM/src/include" \
    -I"$ROOT/ThirdParty/vendor" \
    -I"$SDKROOT/usr/include/libxml2" \
    "$ROOT/MDictCore/FDBoundSQLiteReadOnlyVFS.cpp" \
    "$ROOT/MDictCore/SQLiteDictionaryCore.cpp" \
    "$ROOT/App/DictionaryCoreBridge.mm" \
    "$ROOT/App/DictionarySemanticModel.mm" \
    "$ROOT/App/OxfordEntryFormatter.mm" \
    "$ROOT/App/SupplementalEntryFormatters.mm" \
    "$ROOT/Tests/MultiDictionaryFormatterSmoke.mm" \
    "$OBJECTS/mdict.o" "$OBJECTS/binutils.o" "$OBJECTS/adler32.o" \
    "$OBJECTS/rmd128.o" "$OBJECTS/ripemd128-adapter.o" "$OBJECTS/miniz.o" \
    "$OBJECTS/miniz_tinfl.o" "$OBJECTS/miniz_tdef.o" \
    -lsqlite3 -lxml2 -framework AppKit -framework Foundation \
    -o "$WORK/multidictionary-formatter-smoke"

"$WORK/multidictionary-formatter-smoke" "$ROOT/config/local.json" "$FIXTURE"

"$SWIFTC" -sdk "$SDKROOT" -module-cache-path "$WORK/module-cache" \
    "$ROOT/App/ObsidianNoteStore.swift" \
    "$ROOT/Tests/MultiSourceObsidianSmoke.swift" \
    -o "$WORK/multisource-obsidian-smoke"
"$WORK/multisource-obsidian-smoke" "$FIXTURE" "$NOTES"
