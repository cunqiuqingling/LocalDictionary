#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-fd-mdict-build.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT

MDICT="$ROOT/ThirdParty/vendor/mdict-cpp"
MINIZ="$ROOT/ThirdParty/vendor/miniz"
LTC="$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128"
SOURCE="$ROOT/MDictCore/ManagedMDictSource.cpp"
SMOKE="$ROOT/Tests/FDBoundMDictSourcePrototypeSmoke.cpp"

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"

fd_reader_region="$(/usr/bin/awk \
  '/class FDBoundRandomAccessReader/,/^};/' "$MDICT/src/mdict.cc")"
factory_region="$(/usr/bin/awk \
  '/std::unique_ptr<Mdict> Mdict::fromFileDescriptor/,/^}/' \
  "$MDICT/src/mdict.cc")"
readfile_region="$(/usr/bin/awk \
  '/void Mdict::readfile/,/^}/' "$MDICT/src/mdict.cc")"

for region in "$fd_reader_region" "$factory_region" "$readfile_region"; do
  if print -r -- "$region" | /usr/bin/grep -Eq \
      'std::ifstream|fopen[[:space:]]*\(|/dev/fd|filesystem::exists|(^|[^[:alnum:]_])stat[[:space:]]*\(|(^|[^[:alnum:]_])open[[:space:]]*\('; then
    print -u2 "fd-based parser region contains a pathname operation"
    exit 1
  fi
done
print -r -- "$fd_reader_region" | /usr/bin/grep -q 'pread' || {
  print -u2 "fd reader does not use pread"
  exit 1
}
print -r -- "$factory_region" | /usr/bin/grep -q \
  'FDBoundRandomAccessReader' || {
  print -u2 "fd factory does not construct the fd reader"
  exit 1
}
print -r -- "$readfile_region" | /usr/bin/grep -q \
  'source_->readExact' || {
  print -u2 "parser readfile bypasses the random-access reader"
  exit 1
}
if /usr/bin/grep -R -q '/dev/fd' \
    "$ROOT/Prototypes/FDBoundMDictSource.h" \
    "$ROOT/Prototypes/FDBoundMDictSource.cpp" \
    "$ROOT/MDictCore/ManagedMDictSource.h" \
    "$ROOT/MDictCore/ManagedMDictSource.cpp" \
    "$MDICT/src/include/mdict.h" "$MDICT/src/mdict.cc"; then
  print -u2 "fd source prototype contains a /dev/fd fallback"
  exit 1
fi

build_and_run() {
  local mode="$1"
  shift
  local flags=("$@")
  local directory="$WORK/$mode"
  /bin/mkdir -p "$directory"
  local cflags=(-std=c17 -Wall -Wextra -Werror -isysroot "$SDKROOT"
                "${flags[@]}")
  local cxxflags=(-std=c++17 -Wall -Wextra -Werror -pthread
                  -DLOCALDICTIONARY_SOURCE_CAPABILITY_TESTING
                  -isysroot "$SDKROOT" "${flags[@]}")

  for source in miniz.c miniz_tinfl.c miniz_tdef.c; do
    "$CC" "${cflags[@]}" -I"$MINIZ" -c "$MINIZ/$source" \
      -o "$directory/${source%.c}.o"
  done
  "$CC" "${cflags[@]}" -I"$LTC/include" -c "$LTC/src/rmd128.c" \
    -o "$directory/rmd128.o"
  "$CC" "${cflags[@]}" -I"$ROOT/MDictCore" -I"$LTC/include" \
    -c "$ROOT/MDictCore/RIPEMD128Adapter.c" \
    -o "$directory/ripemd128-adapter.o"

  for source in mdict.cc binutils.cc adler32.cc; do
    "$CXX" "${cxxflags[@]}" -I"$ROOT/MDictCore" -I"$MDICT/src" \
      -I"$MDICT/src/include" -I"$ROOT/ThirdParty/vendor" \
      -c "$MDICT/src/$source" -o "$directory/${source%.cc}.o"
  done
  "$CXX" "${cxxflags[@]}" -I"$ROOT/Prototypes" -I"$ROOT/Tests" \
    -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" \
    -I"$ROOT/ThirdParty/vendor" -c "$SOURCE" \
    -o "$directory/fd-source.o"
  "$CXX" "${cxxflags[@]}" -I"$ROOT/Prototypes" -I"$ROOT/Tests" \
    -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" \
    -I"$ROOT/ThirdParty/vendor" -c "$SMOKE" \
    -o "$directory/smoke.o"

  "$CXX" "${cxxflags[@]}" "$directory/smoke.o" \
    "$directory/fd-source.o" "$directory/mdict.o" \
    "$directory/binutils.o" "$directory/adler32.o" \
    "$directory/rmd128.o" "$directory/ripemd128-adapter.o" \
    "$directory/miniz.o" "$directory/miniz_tinfl.o" \
    "$directory/miniz_tdef.o" -o "$directory/smoke"
  if [[ "$mode" == debug ]]; then
    ASAN_OPTIONS=halt_on_error=1 \
      UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
      "$directory/smoke"
  else
    "$directory/smoke"
  fi
}

print "=== fd-bound MDict source prototype (Debug) ==="
build_and_run debug -O1 -g -fsanitize=address,undefined \
  -fno-omit-frame-pointer

print ""
print "=== fd-bound MDict source prototype (Release) ==="
build_and_run release -O2 -DNDEBUG

print ""
print "fd-bound MDict source prototype Debug/Release passed"
