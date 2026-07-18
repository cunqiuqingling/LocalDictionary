#!/bin/zsh
# run-d1b3a2a-resource-limits-smoke.sh
# Compile and run D1b-3A-2A ResourceLimits smoke tests in both Debug and Release.
set -euo pipefail

ROOT="${0:A:h:h}"
TEST_SRC="$ROOT/Tests/D1b3A2AResourceLimitsSmoke.cpp"

LTC="$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128"
MINIZ="$ROOT/ThirdParty/vendor/miniz"
MDICT="$ROOT/ThirdParty/vendor/mdict-cpp"
VENDOR="$ROOT/ThirdParty/vendor"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"

# ---------- Debug build ----------
print "=== D1b-3A-2A ResourceLimits Smoke (Debug) ==="
DEBUG_DIR="$ROOT/.build/d1b3a2a-smoke-debug"
mkdir -p "$DEBUG_DIR/objects"

CFLAGS_DBG=(-std=c17 -Wall -Wextra -Werror -O1 -g -isysroot "$SDKROOT"
            -fsanitize=address,undefined -fno-omit-frame-pointer)
CXXFLAGS_DBG=(-std=c++17 -Wall -Wextra -Werror -O1 -g
              -DMDICT_RESOURCE_TEST_OBSERVER -isysroot "$SDKROOT"
              -fsanitize=address,undefined -fno-omit-frame-pointer)

for src in miniz.c miniz_tinfl.c miniz_tdef.c; do
  "$CC" "${CFLAGS_DBG[@]}" -I"$MINIZ" -c "$MINIZ/$src" \
    -o "$DEBUG_DIR/objects/${src%.c}.o" || exit 1
done
"$CC" "${CFLAGS_DBG[@]}" -I"$LTC/include" \
  -c "$LTC/src/rmd128.c" -o "$DEBUG_DIR/objects/rmd128.o"
"$CC" "${CFLAGS_DBG[@]}" -I"$ROOT/MDictCore" -I"$LTC/include" \
  -c "$ROOT/MDictCore/RIPEMD128Adapter.c" -o "$DEBUG_DIR/objects/ripemd128-adapter.o"

for src in mdict.cc binutils.cc adler32.cc; do
  "$CXX" "${CXXFLAGS_DBG[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" \
    -I"$MDICT/src/include" -I"$VENDOR" \
    -c "$MDICT/src/$src" -o "$DEBUG_DIR/objects/${src%.cc}.o" || exit 1
done

"$CXX" "${CXXFLAGS_DBG[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" \
  -I"$MDICT/src/include" -I"$VENDOR" \
  "$TEST_SRC" \
  "$DEBUG_DIR/objects/mdict.o" "$DEBUG_DIR/objects/binutils.o" \
  "$DEBUG_DIR/objects/adler32.o" "$DEBUG_DIR/objects/rmd128.o" \
  "$DEBUG_DIR/objects/ripemd128-adapter.o" "$DEBUG_DIR/objects/miniz.o" \
  "$DEBUG_DIR/objects/miniz_tinfl.o" "$DEBUG_DIR/objects/miniz_tdef.o" \
  -o "$DEBUG_DIR/smoke"

"$DEBUG_DIR/smoke"
print "=== D1b-3A-2A Debug smoke passed ==="

# ---------- Release build ----------
print ""
print "=== D1b-3A-2A ResourceLimits Smoke (Release) ==="
RELEASE_DIR="$ROOT/.build/d1b3a2a-smoke-release"
mkdir -p "$RELEASE_DIR/objects"

CFLAGS_REL=(-std=c17 -Wall -Wextra -Werror -O2 -DNDEBUG -isysroot "$SDKROOT")
CXXFLAGS_REL=(-std=c++17 -Wall -Wextra -Werror -O2 -DNDEBUG
              -DMDICT_RESOURCE_TEST_OBSERVER -isysroot "$SDKROOT")

for src in miniz.c miniz_tinfl.c miniz_tdef.c; do
  "$CC" "${CFLAGS_REL[@]}" -I"$MINIZ" -c "$MINIZ/$src" \
    -o "$RELEASE_DIR/objects/${src%.c}.o" || exit 1
done
"$CC" "${CFLAGS_REL[@]}" -I"$LTC/include" \
  -c "$LTC/src/rmd128.c" -o "$RELEASE_DIR/objects/rmd128.o"
"$CC" "${CFLAGS_REL[@]}" -I"$ROOT/MDictCore" -I"$LTC/include" \
  -c "$ROOT/MDictCore/RIPEMD128Adapter.c" -o "$RELEASE_DIR/objects/ripemd128-adapter.o"

for src in mdict.cc binutils.cc adler32.cc; do
  "$CXX" "${CXXFLAGS_REL[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" \
    -I"$MDICT/src/include" -I"$VENDOR" \
    -c "$MDICT/src/$src" -o "$RELEASE_DIR/objects/${src%.cc}.o" || exit 1
done

"$CXX" "${CXXFLAGS_REL[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" \
  -I"$MDICT/src/include" -I"$VENDOR" \
  "$TEST_SRC" \
  "$RELEASE_DIR/objects/mdict.o" "$RELEASE_DIR/objects/binutils.o" \
  "$RELEASE_DIR/objects/adler32.o" "$RELEASE_DIR/objects/rmd128.o" \
  "$RELEASE_DIR/objects/ripemd128-adapter.o" "$RELEASE_DIR/objects/miniz.o" \
  "$RELEASE_DIR/objects/miniz_tinfl.o" "$RELEASE_DIR/objects/miniz_tdef.o" \
  -o "$RELEASE_DIR/smoke"

"$RELEASE_DIR/smoke"
print "=== D1b-3A-2A Release smoke passed ==="
