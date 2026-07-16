#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VENDOR="$ROOT/ThirdParty/vendor"
MDICT="$VENDOR/mdict-cpp"
MINIZ="$VENDOR/miniz"
LIBTOMCRYPT="$VENDOR/libtomcrypt-ripemd128"
OUTPUT="$ROOT/.build/mdict-validate"
OBJECTS="$ROOT/.build/objects"

mkdir -p "$OBJECTS"

CC=${CC:-clang}
CXX=${CXX:-clang++}

if [ ! -f "$MDICT/src/mdict.cc" ]; then
  echo "Missing reviewed mdict-cpp vendor subset." >&2
  exit 1
fi

for source in miniz.c miniz_tinfl.c miniz_tdef.c; do
  "$CC" -O2 -DNDEBUG -I"$MINIZ" -c \
    "$MINIZ/$source" -o "$OBJECTS/${source%.c}.o"
done

"$CC" -O2 -DNDEBUG -I"$LIBTOMCRYPT/include" \
  -c "$LIBTOMCRYPT/src/rmd128.c" \
  -o "$OBJECTS/ripemd128.o"
"$CC" -O2 -DNDEBUG -I"$ROOT/MDictCore" -I"$LIBTOMCRYPT/include" \
  -c "$ROOT/MDictCore/RIPEMD128Adapter.c" \
  -o "$OBJECTS/ripemd128-adapter.o"

for source in mdict.cc binutils.cc adler32.cc; do
  "$CXX" -std=c++17 -O2 -DNDEBUG \
    -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" \
    -I"$VENDOR" -c "$MDICT/src/$source" \
    -o "$OBJECTS/${source%.cc}.o"
done

"$CXX" -std=c++17 -O2 -DNDEBUG \
  -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" \
  -I"$VENDOR" \
  "$ROOT/MDictCore/ValidationCLI/main.cpp" \
  "$OBJECTS/mdict.o" "$OBJECTS/binutils.o" "$OBJECTS/adler32.o" \
  "$OBJECTS/ripemd128.o" "$OBJECTS/ripemd128-adapter.o" \
  "$OBJECTS/miniz.o" "$OBJECTS/miniz_tinfl.o" \
  "$OBJECTS/miniz_tdef.o" \
  -framework CoreFoundation -o "$OUTPUT"

echo "$OUTPUT"
