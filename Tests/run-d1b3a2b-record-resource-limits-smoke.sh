#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
TEST_SRC="$ROOT/Tests/D1b3A2BRecordResourceLimitsSmoke.cpp"
LTC="$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128"
MINIZ="$ROOT/ThirdParty/vendor/miniz"
MDICT="$ROOT/ThirdParty/vendor/mdict-cpp"
VENDOR="$ROOT/ThirdParty/vendor"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"; CXX="$(xcrun --find clang++)"
for mode in debug release; do
  [[ "$mode" == debug ]] && flags=(-O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer) || flags=(-O2 -DNDEBUG)
  dir="$ROOT/.build/d1b3a2b-record-$mode"; mkdir -p "$dir/objects"
  cflags=(-std=c17 -Wall -Wextra -Werror "${flags[@]}" -isysroot "$SDKROOT")
  cxxflags=(-std=c++17 -Wall -Wextra -Werror "${flags[@]}" -DMDICT_RESOURCE_TEST_OBSERVER -isysroot "$SDKROOT")
  for src in miniz.c miniz_tinfl.c miniz_tdef.c; do "$CC" "${cflags[@]}" -I"$MINIZ" -c "$MINIZ/$src" -o "$dir/objects/${src%.c}.o"; done
  "$CC" "${cflags[@]}" -I"$LTC/include" -c "$LTC/src/rmd128.c" -o "$dir/objects/rmd128.o"
  "$CC" "${cflags[@]}" -I"$ROOT/MDictCore" -I"$LTC/include" -c "$ROOT/MDictCore/RIPEMD128Adapter.c" -o "$dir/objects/ripemd128-adapter.o"
  for src in mdict.cc binutils.cc adler32.cc; do "$CXX" "${cxxflags[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" -I"$VENDOR" -c "$MDICT/src/$src" -o "$dir/objects/${src%.cc}.o"; done
  "$CXX" "${cxxflags[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" -I"$VENDOR" "$TEST_SRC" "$dir/objects/mdict.o" "$dir/objects/binutils.o" "$dir/objects/adler32.o" "$dir/objects/rmd128.o" "$dir/objects/ripemd128-adapter.o" "$dir/objects/miniz.o" "$dir/objects/miniz_tinfl.o" "$dir/objects/miniz_tdef.o" -o "$dir/smoke"
  "$dir/smoke"
done
