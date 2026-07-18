#!/bin/zsh
# run-mdict-resource-metrics-probe.sh
# Compile and run the anonymous MDict resource metrics probe.
#
# Usage (synthetic smoke – Debug build):
#   Tests/run-mdict-resource-metrics-probe.sh ...
#
# Usage (real dictionary measurement – Release build):
#   Tests/run-mdict-resource-metrics-probe.sh --release ...
#
# Real dictionary measurement REQUIRES --release.
# Debug mode is for synthetic smoke only.
# Encrypted=2 dictionaries MUST be measured with --release.
#
# This script is test-only. It is NOT part of the App target.
set -euo pipefail

ROOT="${0:A:h:h}"
PROBE_SRC="$ROOT/Tests/Tools/MDictResourceMetricsProbe.cpp"

LTC="$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128"
MINIZ="$ROOT/ThirdParty/vendor/miniz"
MDICT="$ROOT/ThirdParty/vendor/mdict-cpp"
VENDOR="$ROOT/ThirdParty/vendor"

# ---------- argument scanning ----------
RELEASE_MODE=0
HAS_DICTIONARY=0
FORWARD_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --release)
      RELEASE_MODE=1
      ;;
    --dictionary)
      HAS_DICTIONARY=1
      FORWARD_ARGS+=("$arg")
      ;;
    *)
      FORWARD_ARGS+=("$arg")
      ;;
  esac
done

# ---------- safety gate ----------
if (( HAS_DICTIONARY && ! RELEASE_MODE )); then
  print -u2 "Error: real dictionary measurement requires --release"
  exit 1
fi

# ---------- build ----------
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"

CFLAGS_BASE=(-std=c17 -Wall -Wextra -Werror -isysroot "$SDKROOT")
CXXFLAGS_STRICT_BASE=(-std=c++17 -Wall -Wextra -Werror -isysroot "$SDKROOT")
CXXFLAGS_RELAXED_BASE=(-std=c++17 -isysroot "$SDKROOT")

if (( RELEASE_MODE )); then
  BUILD_DIR="$ROOT/.build/mdict-resource-metrics-probe-release"
  OPT_FLAGS=(-O2 -DNDEBUG)
else
  BUILD_DIR="$ROOT/.build/mdict-resource-metrics-probe"
  OPT_FLAGS=(-O1 -g)
  # Debug mode adds sanitizers for dev safety
  CFLAGS_BASE+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
  CXXFLAGS_STRICT_BASE+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
  CXXFLAGS_RELAXED_BASE+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi

CFLAGS=("${CFLAGS_BASE[@]}" "${OPT_FLAGS[@]}")
CXXFLAGS_STRICT=("${CXXFLAGS_STRICT_BASE[@]}" "${OPT_FLAGS[@]}")
CXXFLAGS_RELAXED=("${CXXFLAGS_RELAXED_BASE[@]}" "${OPT_FLAGS[@]}")

mkdir -p "$BUILD_DIR"
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

exec "$BUILD_DIR/MDictResourceMetricsProbe" "${FORWARD_ARGS[@]}"
