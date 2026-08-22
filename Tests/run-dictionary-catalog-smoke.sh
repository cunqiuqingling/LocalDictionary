#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-catalog.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi
mkdir -p "$BUILD/module-cache"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/AppConfig.swift" \
  "$ROOT/App/DictionaryCatalog.swift" \
  "$ROOT/App/ResourceManifestKeyID.swift" \
  "$ROOT/App/DictionaryCatalogStore.swift" \
  "$ROOT/App/LegacyDictionaryConfigAdapter.swift" \
  "$ROOT/Tests/DictionaryCatalogSmoke.swift" \
  -lsqlite3 \
  -o "$BUILD/DictionaryCatalogSmoke"

"$BUILD/DictionaryCatalogSmoke"
