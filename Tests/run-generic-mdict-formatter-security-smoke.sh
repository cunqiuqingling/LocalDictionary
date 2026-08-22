#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-generic-formatter.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/clang++" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/clang++" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$BUILD"

xcrun --sdk macosx clang++ -std=c++17 -fobjc-arc \
  -I"$SDK/usr/include/libxml2" \
  "$ROOT/App/GenericMDictEntryFormatter.mm" \
  "$ROOT/Tests/GenericMDictFormatterSecuritySmoke.mm" \
  -framework Foundation -lxml2 \
  -o "$BUILD/GenericMDictFormatterSecuritySmoke"

"$BUILD/GenericMDictFormatterSecuritySmoke"
