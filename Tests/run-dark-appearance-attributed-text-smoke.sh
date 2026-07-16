#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/dark-appearance-smoke"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/clang++" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/clang++" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi
mkdir -p "$BUILD"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="$(xcrun --find clang++)"
"$CLANG" -std=c++17 -fobjc-arc -fmodules \
  -isysroot "$SDK" -mmacosx-version-min=15.0 \
  -I"$ROOT/App" -I"$SDK/usr/include/libxml2" \
  "$ROOT/App/DictionaryAppearanceTextAdapter.mm" \
  "$ROOT/App/DictionarySemanticModel.mm" \
  "$ROOT/App/OxfordEntryFormatter.mm" \
  "$ROOT/App/SupplementalEntryFormatters.mm" \
  "$ROOT/App/GenericMDictEntryFormatter.mm" \
  "$ROOT/Tests/DarkAppearanceAttributedTextSmoke.mm" \
  -framework AppKit -lxml2 \
  -o "$BUILD/DarkAppearanceAttributedTextSmoke"

"$BUILD/DarkAppearanceAttributedTextSmoke"
