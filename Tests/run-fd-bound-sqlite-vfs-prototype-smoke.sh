#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-fd-vfs-build.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/clang++" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/clang++" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi

SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CXX="$(xcrun --find clang++)"
PROTOTYPE="$ROOT/Prototypes/FDBoundSQLiteReadOnlyVFS.cpp"
SMOKE="$ROOT/Tests/FDBoundSQLiteVFSPrototypeSmoke.cpp"
COMMON=(-std=c++17 -Wall -Wextra -Werror -pthread -isysroot "$SDKROOT"
        -I"$ROOT/Prototypes" "$PROTOTYPE" "$SMOKE" -lsqlite3)

print "=== fd-bound SQLite read-only VFS prototype (Debug) ==="
"$CXX" -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
  "${COMMON[@]}" -o "$WORK/fd-vfs-debug"
ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
  "$WORK/fd-vfs-debug"

print ""
print "=== fd-bound SQLite read-only VFS prototype (Release) ==="
"$CXX" -O2 -DNDEBUG "${COMMON[@]}" -o "$WORK/fd-vfs-release"
"$WORK/fd-vfs-release"

print ""
print "fd-bound SQLite read-only VFS prototype Debug/Release passed"
