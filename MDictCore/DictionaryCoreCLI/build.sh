#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
UPSTREAM="$ROOT/ThirdParty/mdict-cpp"
OUTPUT="$ROOT/.build/mdict-core"
OBJECTS="$ROOT/.build/core-objects"

if [ ! -f "$UPSTREAM/src/mdict.cc" ]; then
  echo "Missing reviewed parser checkout at $UPSTREAM" >&2
  exit 1
fi

mkdir -p "$OBJECTS"
CC=${CC:-clang}
CXX=${CXX:-clang++}

for source in miniz.c miniz_tinfl.c miniz_tdef.c miniz_zip.c; do
  "$CC" -O2 -DNDEBUG -I"$UPSTREAM/deps/miniz" -c \
    "$UPSTREAM/deps/miniz/$source" -o "$OBJECTS/${source%.c}.o"
done
"$CC" -O2 -DNDEBUG -c "$UPSTREAM/src/ripemd128.c" \
  -o "$OBJECTS/ripemd128.o"

for source in mdict.cc binutils.cc adler32.cc; do
  "$CXX" -std=c++17 -O2 -DNDEBUG \
    -I"$UPSTREAM/src" -I"$UPSTREAM/src/include" \
    -I"$UPSTREAM/deps" -I"$UPSTREAM/deps/turbobase64" \
    -c "$UPSTREAM/src/$source" -o "$OBJECTS/${source%.cc}.o"
done

"$CXX" -std=c++17 -O2 -DNDEBUG \
  -I"$ROOT/MDictCore" -I"$UPSTREAM/src" -I"$UPSTREAM/src/include" \
  -I"$UPSTREAM/deps" -I"$UPSTREAM/deps/turbobase64" \
  "$ROOT/MDictCore/SQLiteDictionaryCore.cpp" \
  "$ROOT/MDictCore/DictionaryCoreCLI/main.cpp" \
  "$OBJECTS/mdict.o" "$OBJECTS/binutils.o" "$OBJECTS/adler32.o" \
  "$OBJECTS/ripemd128.o" "$OBJECTS/miniz.o" \
  "$OBJECTS/miniz_tinfl.o" "$OBJECTS/miniz_tdef.o" \
  "$OBJECTS/miniz_zip.o" -lsqlite3 -framework CoreFoundation -o "$OUTPUT"

echo "$OUTPUT"

