#!/bin/zsh
# run-mdict-resource-metrics-probe-smoke.sh
# Build and run the synthetic smoke test for MDictResourceMetricsProbe.
set -euo pipefail

ROOT="${0:A:h:h}"
PROBE_SRC="$ROOT/Tests/Tools/MDictResourceMetricsProbe.cpp"
SMOKE_SRC="$ROOT/Tests/MDictResourceMetricsProbeSmoke.cpp"
BUILD_DIR="$ROOT/.build/mdict-resource-metrics-probe"

LTC="$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128"
MINIZ="$ROOT/ThirdParty/vendor/miniz"
MDICT="$ROOT/ThirdParty/vendor/mdict-cpp"
VENDOR="$ROOT/ThirdParty/vendor"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"

CFLAGS=(-std=c17 -Wall -Wextra -Werror -O1 -g -isysroot "$SDKROOT")
CXXFLAGS_STRICT=(-std=c++17 -Wall -Wextra -Werror -O1 -g -isysroot "$SDKROOT")
CXXFLAGS_RELAXED=(-std=c++17 -O1 -g -isysroot "$SDKROOT")

mkdir -p "$BUILD_DIR"
OBJECTS="$BUILD_DIR/objects"
mkdir -p "$OBJECTS"

echo "=== Building mdict-resource-metrics-probe ==="

# miniz (strict)
for src in miniz.c miniz_tinfl.c miniz_tdef.c; do
  "$CC" "${CFLAGS[@]}" -I"$MINIZ" -c "$MINIZ/$src" -o "$OBJECTS/${src%.c}.o"
done

# ripemd128 (strict)
"$CC" "${CFLAGS[@]}" -I"$LTC/include" -c "$LTC/src/rmd128.c" -o "$OBJECTS/rmd128.o"
"$CC" "${CFLAGS[@]}" -I"$ROOT/MDictCore" -I"$LTC/include" \
  -c "$ROOT/MDictCore/RIPEMD128Adapter.c" -o "$OBJECTS/ripemd128-adapter.o"

# mdict-cpp (relaxed – upstream warnings)
for src in mdict.cc binutils.cc adler32.cc; do
  "$CXX" "${CXXFLAGS_RELAXED[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" \
    -I"$MDICT/src/include" -I"$VENDOR" -c "$MDICT/src/$src" -o "$OBJECTS/${src%.cc}.o"
done

# Link probe (strict)
"$CXX" "${CXXFLAGS_STRICT[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" \
  -I"$MDICT/src/include" -I"$VENDOR" \
  "$PROBE_SRC" \
  "$OBJECTS/mdict.o" "$OBJECTS/binutils.o" "$OBJECTS/adler32.o" \
  "$OBJECTS/rmd128.o" "$OBJECTS/ripemd128-adapter.o" \
  "$OBJECTS/miniz.o" "$OBJECTS/miniz_tinfl.o" "$OBJECTS/miniz_tdef.o" \
  -o "$BUILD_DIR/MDictResourceMetricsProbe"

echo "=== Building smoke test ==="

export MDICT_METRICS_PROBE_BIN="$BUILD_DIR/MDictResourceMetricsProbe"
export PROBE_BUILD_DIR="$BUILD_DIR"

# Compile smoke miniz objects (separate from probe ones to avoid conflicts)
SMOKE_OBJ="$BUILD_DIR/smoke-objects"
mkdir -p "$SMOKE_OBJ"
for src in miniz.c miniz_tinfl.c miniz_tdef.c; do
  "$CC" "${CFLAGS[@]}" -I"$MINIZ" -c "$MINIZ/$src" -o "$SMOKE_OBJ/${src%.c}.o"
done

# Link smoke test (strict, only needs miniz)
"$CXX" "${CXXFLAGS_STRICT[@]}" -I"$MINIZ" \
  "$SMOKE_SRC" \
  "$SMOKE_OBJ/miniz.o" "$SMOKE_OBJ/miniz_tinfl.o" "$SMOKE_OBJ/miniz_tdef.o" \
  -o "$BUILD_DIR/MDictResourceMetricsProbeSmoke"

echo "=== Running smoke tests ==="
"$BUILD_DIR/MDictResourceMetricsProbeSmoke"

echo ""
echo "=== All mdict resource metrics probe smoke tests passed ==="
