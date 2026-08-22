#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-managed-source-indexing.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT

MDICT="$ROOT/ThirdParty/vendor/mdict-cpp"
MINIZ="$ROOT/ThirdParty/vendor/miniz"
LTC="$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"

adapter_region="$(/usr/bin/awk \
  '/let liveDictionaryIndexBuilder/,/^}/' \
  "$ROOT/App/DictionaryIndexBuilderAdapter.swift")"
bridge_region="$(/usr/bin/awk \
  '/LocalDictionaryBuildManagedIndex/,/^}/' \
  "$ROOT/App/DictionaryCoreBridge.mm")"
core_region="$(/usr/bin/awk \
  '/SQLiteDictionaryCore::buildManagedIndexFromFileDescriptor/,/^}/' \
  "$ROOT/MDictCore/SQLiteDictionaryCore.cpp")"
worker_region="$(/usr/bin/awk \
  '/struct ManagedDictionaryIndexWorker/,/^}/' \
  "$ROOT/App/DictionaryIndexingService.swift")"

print -r -- "$adapter_region" | /usr/bin/grep -q \
  'LocalDictionaryBuildManagedIndex' || {
  print -u2 "managed adapter does not call the fd bridge"
  exit 1
}
if print -r -- "$adapter_region" | /usr/bin/grep -Eq \
    'sourceURL|sourceRelativePath|LocalDictionaryBuildIndex[[:space:]]*\('; then
  print -u2 "managed adapter contains a pathname parser fallback"
  exit 1
fi
print -r -- "$bridge_region" | /usr/bin/grep -q \
  'buildManagedIndexFromFileDescriptor' || {
  print -u2 "managed bridge does not call the fd core API"
  exit 1
}
if print -r -- "$bridge_region" | /usr/bin/grep -Eq \
    'Mdict[[:space:]]*\(|/dev/fd|dictionaryPath|stat[[:space:]]*\(|ifstream|fopen'; then
  print -u2 "managed bridge contains a pathname source operation"
  exit 1
fi
print -r -- "$core_region" | /usr/bin/grep -q \
  'fromFileDescriptor' || {
  print -u2 "managed core fd API does not construct an fd parser"
  exit 1
}
if print -r -- "$core_region" | /usr/bin/grep -Eq \
    'dictionary_path_|sourceMetadata|filesystem|/dev/fd|ifstream|fopen|stat[[:space:]]*\('; then
  print -u2 "managed core fd API contains a pathname source operation"
  exit 1
fi
if /usr/bin/grep -R -q '/dev/fd' \
    "$ROOT/MDictCore/ManagedMDictSource.h" \
    "$ROOT/MDictCore/ManagedMDictSource.cpp" \
    "$ROOT/App/DictionaryCoreBridge.mm" \
    "$ROOT/App/DictionaryIndexBuilderAdapter.swift"; then
  print -u2 "production source capability contains a /dev/fd fallback"
  exit 1
fi
print -r -- "$worker_region" | /usr/bin/grep -q \
  'openSource' || {
  print -u2 "managed worker does not establish a source capability"
  exit 1
}
print -r -- "$worker_region" | /usr/bin/grep -q \
  'isValidForPublication' || {
  print -u2 "managed worker does not revalidate source identity"
  exit 1
}
if print -r -- "$worker_region" | /usr/bin/grep -Eq \
    'sourceURL|FileHandle[[:space:]]*\(forReadingFrom:|sha256[[:space:]]*\(of:'; then
  print -u2 "managed worker contains a pathname source operation"
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
  local cxxflags=(-std=c++17 -Wall -Wextra -Werror -pthread -fblocks
                  -fobjc-arc -isysroot "$SDKROOT" "${flags[@]}")

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
    "$CXX" "${cxxflags[@]}" -x c++ -I"$ROOT/MDictCore" -I"$MDICT/src" \
      -I"$MDICT/src/include" -I"$ROOT/ThirdParty/vendor" \
      -c "$MDICT/src/$source" -o "$directory/${source%.cc}.o"
  done
  for source in ManagedMDictSource.cpp FDBoundSQLiteReadOnlyVFS.cpp SQLiteDictionaryCore.cpp; do
    "$CXX" "${cxxflags[@]}" -x c++ -I"$ROOT/MDictCore" -I"$MDICT/src" \
      -I"$MDICT/src/include" -I"$ROOT/ThirdParty/vendor" \
      -c "$ROOT/MDictCore/$source" -o "$directory/${source%.cpp}.o"
  done
  "$CXX" "${cxxflags[@]}" -x objective-c++ -I"$ROOT/App" \
    -I"$ROOT/MDictCore" -I"$MDICT/src" -I"$MDICT/src/include" \
    -I"$ROOT/ThirdParty/vendor" -c "$ROOT/App/DictionaryCoreBridge.mm" \
    -o "$directory/bridge.o"
  "$CXX" "${cxxflags[@]}" -x objective-c++ -I"$ROOT/App" \
    -I"$ROOT/Tests" -I"$ROOT/MDictCore" -I"$MDICT/src" \
    -I"$MDICT/src/include" -I"$ROOT/ThirdParty/vendor" \
    -c "$ROOT/Tests/ManagedSourceIndexingProductionSmoke.mm" \
    -o "$directory/smoke.o"

  "$CXX" "${cxxflags[@]}" "$directory/smoke.o" "$directory/bridge.o" \
    "$directory/ManagedMDictSource.o" "$directory/SQLiteDictionaryCore.o" \
    "$directory/FDBoundSQLiteReadOnlyVFS.o" \
    "$directory/mdict.o" "$directory/binutils.o" "$directory/adler32.o" \
    "$directory/rmd128.o" "$directory/ripemd128-adapter.o" \
    "$directory/miniz.o" "$directory/miniz_tinfl.o" \
    "$directory/miniz_tdef.o" -framework Foundation -lsqlite3 \
    -o "$directory/smoke"
  if [[ "$mode" == debug ]]; then
    ASAN_OPTIONS=halt_on_error=1 \
      UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
      "$directory/smoke"
  else
    "$directory/smoke"
  fi
}

print "=== production managed source indexing (Debug) ==="
build_and_run debug -O1 -g -fsanitize=address,undefined \
  -fno-omit-frame-pointer

print ""
print "=== production managed source indexing (Release) ==="
build_and_run release -O2 -DNDEBUG

print ""
print "production managed source indexing Debug/Release passed"
