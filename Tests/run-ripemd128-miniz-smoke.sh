#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-ripemd-miniz.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"
LTC="$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128"
MINIZ="$ROOT/ThirdParty/vendor/miniz"
MDICT="$ROOT/ThirdParty/vendor/mdict-cpp"
VENDOR="$ROOT/ThirdParty/vendor"

mkdir -p "$WORK"

COMMON_FLAGS=(-std=c17 -Wall -Wextra -Werror -O1 -g -isysroot "$SDKROOT")
SANITIZERS=(-fsanitize=address,undefined -fno-omit-frame-pointer)

"$CC" "${COMMON_FLAGS[@]}" "${SANITIZERS[@]}" \
    -I"$ROOT/MDictCore" -I"$LTC/include" \
    "$LTC/src/rmd128.c" "$ROOT/MDictCore/RIPEMD128Adapter.c" \
    "$ROOT/Tests/RIPEMD128Smoke.c" -o "$WORK/ripemd128-smoke"
"$WORK/ripemd128-smoke"

"$CC" "${COMMON_FLAGS[@]}" "${SANITIZERS[@]}" -I"$MINIZ" \
    "$MINIZ/miniz.c" "$MINIZ/miniz_tinfl.c" "$MINIZ/miniz_tdef.c" \
    "$ROOT/Tests/MinizDecompressionSmoke.c" -o "$WORK/miniz-smoke"
"$WORK/miniz-smoke"

OBJECTS="$WORK/mdict-objects"
mkdir -p "$OBJECTS"
for source in miniz.c miniz_tinfl.c miniz_tdef.c; do
  "$CC" "${COMMON_FLAGS[@]}" "${SANITIZERS[@]}" -I"$MINIZ" \
      -c "$MINIZ/$source" -o "$OBJECTS/${source%.c}.o" || exit 1
done
"$CC" "${COMMON_FLAGS[@]}" "${SANITIZERS[@]}" -I"$LTC/include" \
    -c "$LTC/src/rmd128.c" -o "$OBJECTS/rmd128.o"
"$CC" "${COMMON_FLAGS[@]}" "${SANITIZERS[@]}" \
    -I"$ROOT/MDictCore" -I"$LTC/include" \
    -c "$ROOT/MDictCore/RIPEMD128Adapter.c" \
    -o "$OBJECTS/ripemd128-adapter.o"
for source in mdict.cc binutils.cc adler32.cc; do
  "$CXX" -std=c++17 -O1 -g -isysroot "$SDKROOT" "${SANITIZERS[@]}" \
      -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" \
      -I"$VENDOR" -c "$MDICT/src/$source" \
      -o "$OBJECTS/${source%.cc}.o" || exit 1
done
"$CXX" -std=c++17 -Wall -Wextra -Werror -O1 -g -isysroot "$SDKROOT" \
    "${SANITIZERS[@]}" \
    -I"$ROOT/MDictCore" "$ROOT/Tests/MDictDecryptBoundarySmoke.cpp" \
    "$OBJECTS/mdict.o" "$OBJECTS/binutils.o" "$OBJECTS/adler32.o" \
    "$OBJECTS/rmd128.o" "$OBJECTS/ripemd128-adapter.o" \
    "$OBJECTS/miniz.o" "$OBJECTS/miniz_tinfl.o" \
    "$OBJECTS/miniz_tdef.o" -o "$WORK/mdict-decrypt-boundary-smoke"
"$WORK/mdict-decrypt-boundary-smoke"
