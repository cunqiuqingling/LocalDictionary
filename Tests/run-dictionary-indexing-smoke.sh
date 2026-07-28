#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/dictionary-indexing-smoke"
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
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/DictionaryCatalog.swift" \
  "$ROOT/App/ResourceManifestKeyID.swift" \
  "$ROOT/App/ManagedDictionaryLifecycleCoordinator.swift" \
  "$ROOT/App/DictionaryCatalogStore.swift" \
  "$ROOT/App/DictionaryImportModels.swift" \
  "$ROOT/App/DictionaryImportService.swift" \
  "$ROOT/App/DictionaryIndexModels.swift" \
  "$ROOT/App/DictionaryIndexingService.swift" \
  "$ROOT/App/ManagedDictionaryQueryModels.swift" \
  "$ROOT/Tests/DictionaryIndexingSmoke.swift" \
  -lsqlite3 \
  -o "$BUILD/DictionaryIndexingSmoke"

"$BUILD/DictionaryIndexingSmoke"
