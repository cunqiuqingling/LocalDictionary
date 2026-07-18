#!/bin/zsh
# run-mdict-resource-metrics-probe.sh
# Compile and run the anonymous MDict resource metrics probe.
set -euo pipefail

ROOT="${0:A:h:h}"
PROBE_SRC="$ROOT/Tests/Tools/MDictResourceMetricsProbe.cpp"
BUILD_DIR="$ROOT/.build/mdict-resource-metrics-probe"

LTC="$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128"
MINIZ="$ROOT/ThirdParty/vendor/miniz"
MDICT="$ROOT/ThirdParty/vendor/mdict-cpp"
VENDOR="$ROOT/ThirdParty/vendor"

ARGS=("$@")

compile_probe() {
  mkdir -p "$BUILD_DIR"
  SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
  CC="$(xcrun --find clang)"
  CXX="$(xcrun --find clang++)"

  CFLAGS=(-std=c17 -Wall -Wextra -Werror -O1 -g -isysroot "$SDKROOT")
  CXXFLAGS_STRICT=(-std=c++17 -Wall -Wextra -Werror -O1 -g -isysroot "$SDKROOT")
  CXXFLAGS_RELAXED=(-std=c++17 -O1 -g -isysroot "$SDKROOT")

  OBJECTS="$BUILD_DIR/objects"
  mkdir -p "$OBJECTS"

  # miniz (strict)
  for src in miniz.c miniz_tinfl.c miniz_tdef.c; do
    "$CC" "${CFLAGS[@]}" -I"$MINIZ" -c "$MINIZ/$src" -o "$OBJECTS/${src%.c}.o"
  done

  # libtomcrypt ripemd128 (strict)
  "$CC" "${CFLAGS[@]}" -I"$LTC/include" -c "$LTC/src/rmd128.c" -o "$OBJECTS/rmd128.o"

  # RIPEMD128 adapter (strict)
  "$CC" "${CFLAGS[@]}" -I"$ROOT/MDictCore" -I"$LTC/include" \
    -c "$ROOT/MDictCore/RIPEMD128Adapter.c" -o "$OBJECTS/ripemd128-adapter.o"

  # mdict-cpp (relaxed – upstream has pre-existing warnings)
  for src in mdict.cc binutils.cc adler32.cc; do
    "$CXX" "${CXXFLAGS_RELAXED[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" \
      -I"$MDICT/src/include" -I"$VENDOR" -c "$MDICT/src/$src" -o "$OBJECTS/${src%.cc}.o"
  done

  # probe (strict)
  "$CXX" "${CXXFLAGS_STRICT[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" \
    -I"$MDICT/src/include" -I"$VENDOR" \
    "$PROBE_SRC" \
    "$OBJECTS/mdict.o" "$OBJECTS/binutils.o" "$OBJECTS/adler32.o" \
    "$OBJECTS/rmd128.o" "$OBJECTS/ripemd128-adapter.o" \
    "$OBJECTS/miniz.o" "$OBJECTS/miniz_tinfl.o" "$OBJECTS/miniz_tdef.o" \
    -o "$BUILD_DIR/MDictResourceMetricsProbe"
}

compile_probe
exec "$BUILD_DIR/MDictResourceMetricsProbe" "${ARGS[@]}"
