#!/bin/zsh
# run-mdict-resource-metrics-probe-smoke.sh
# Build and run the synthetic smoke test for MDictResourceMetricsProbe.
# Tests both Debug and --release modes.
set -euo pipefail

ROOT="${0:A:h:h}"
PROBE_SRC="$ROOT/Tests/Tools/MDictResourceMetricsProbe.cpp"
SMOKE_SRC="$ROOT/Tests/MDictResourceMetricsProbeSmoke.cpp"
PROBE_SCRIPT="$ROOT/Tests/run-mdict-resource-metrics-probe.sh"
BUILD_DIR="$ROOT/.build/mdict-resource-metrics-probe"
RELEASE_BUILD_DIR="$ROOT/.build/mdict-resource-metrics-probe-release"

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

# ---------- helpers ----------
build_probe_objects() {
  local out_dir="$1"
  shift  # consume out_dir; remaining args are compiler flags
  mkdir -p "$out_dir/objects"
  # miniz
  for src in miniz.c miniz_tinfl.c miniz_tdef.c; do
    "$CC" -std=c17 -Wall -Wextra -Werror -isysroot "$SDKROOT" "$@" \
      -I"$MINIZ" -c "$MINIZ/$src" -o "$out_dir/objects/${src%.c}.o"
  done
  # ripemd128
  "$CC" -std=c17 -Wall -Wextra -Werror -isysroot "$SDKROOT" "$@" \
    -I"$LTC/include" -c "$LTC/src/rmd128.c" -o "$out_dir/objects/rmd128.o"
  "$CC" -std=c17 -Wall -Wextra -Werror -isysroot "$SDKROOT" "$@" \
    -I"$ROOT/MDictCore" -I"$LTC/include" \
    -c "$ROOT/MDictCore/RIPEMD128Adapter.c" -o "$out_dir/objects/ripemd128-adapter.o"
  # mdict-cpp (relaxed)
  for src in mdict.cc binutils.cc adler32.cc; do
    "$CXX" -std=c++17 -isysroot "$SDKROOT" "$@" \
      -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" -I"$VENDOR" \
      -c "$MDICT/src/$src" -o "$out_dir/objects/${src%.cc}.o"
  done
}

link_probe() {
  local out_dir="$1"
  shift
  "$CXX" -std=c++17 -Wall -Wextra -Werror -isysroot "$SDKROOT" "$@" \
    -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" -I"$VENDOR" \
    "$PROBE_SRC" \
    "$out_dir/objects/mdict.o" "$out_dir/objects/binutils.o" \
    "$out_dir/objects/adler32.o" "$out_dir/objects/rmd128.o" \
    "$out_dir/objects/ripemd128-adapter.o" \
    "$out_dir/objects/miniz.o" "$out_dir/objects/miniz_tinfl.o" \
    "$out_dir/objects/miniz_tdef.o" \
    -lsqlite3 \
    -o "$out_dir/MDictResourceMetricsProbe"
}

# ---------- 1. Debug probe ----------
echo "=== Building mdict-resource-metrics-probe (Debug) ==="
build_probe_objects "$BUILD_DIR" -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer
link_probe "$BUILD_DIR" -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer

# ---------- 2. Release probe ----------
echo "=== Building mdict-resource-metrics-probe (Release) ==="
build_probe_objects "$RELEASE_BUILD_DIR" -O2 -DNDEBUG
link_probe "$RELEASE_BUILD_DIR" -O2 -DNDEBUG

# Verify release flags
echo "=== Verifying release build flags ==="
RELEASE_PROBE="$RELEASE_BUILD_DIR/MDictResourceMetricsProbe"
file "$RELEASE_PROBE"

# ---------- 3. C++ synthetic smoke tests ----------
echo "=== Building and running C++ synthetic smoke tests ==="
"$CXX" "${CXXFLAGS_STRICT[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer -I"$MINIZ" \
  "$SMOKE_SRC" \
  "$BUILD_DIR/objects/miniz.o" "$BUILD_DIR/objects/miniz_tinfl.o" \
  "$BUILD_DIR/objects/miniz_tdef.o" \
  -lsqlite3 \
  -o "$BUILD_DIR/MDictResourceMetricsProbeSmoke"
export MDICT_METRICS_PROBE_BIN="$BUILD_DIR/MDictResourceMetricsProbe"
export MDICT_METRICS_PROBE_RELEASE_BIN="$RELEASE_PROBE"
export PROBE_BUILD_DIR="$BUILD_DIR"
"$BUILD_DIR/MDictResourceMetricsProbeSmoke"

echo ""
echo "=== All mdict resource metrics probe smoke tests passed ==="
