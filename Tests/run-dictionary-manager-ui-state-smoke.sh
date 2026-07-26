#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build/c1-ui-state-smoke"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi

mkdir -p "$BUILD_DIR/module-cache"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT_DIR/App/AppConfig.swift" \
  "$ROOT_DIR/App/DictionaryCatalog.swift" \
  "$ROOT_DIR/App/ResourceManifestKeyID.swift" \
  "$ROOT_DIR/App/DictionaryManagerPresentation.swift" \
  "$ROOT_DIR/Tests/DictionaryManagerUIStateSmoke.swift" \
  -o "$BUILD_DIR/DictionaryManagerUIStateSmoke"

"$BUILD_DIR/DictionaryManagerUIStateSmoke"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$BUILD_DIR/module-cache" \
  "$ROOT_DIR/App/AppConfig.swift" \
  "$ROOT_DIR/App/DictionaryCatalog.swift" \
  "$ROOT_DIR/App/ResourceManifestKeyID.swift" \
  "$ROOT_DIR/App/DictionaryCatalogStore.swift" \
  "$ROOT_DIR/App/DictionaryCatalogOrdering.swift" \
  "$ROOT_DIR/App/DictionaryManagerPresentation.swift" \
  "$ROOT_DIR/App/DictionaryImportModels.swift" \
  "$ROOT_DIR/App/MDictImportInspector.swift" \
  "$ROOT_DIR/App/DictionaryImportService.swift" \
  "$ROOT_DIR/App/DictionaryImportPreviewAccessory.swift" \
  "$ROOT_DIR/App/DictionaryIndexModels.swift" \
  "$ROOT_DIR/App/DictionaryIndexingService.swift" \
  "$ROOT_DIR/App/ManagedDictionaryQueryModels.swift" \
  "$ROOT_DIR/App/ManagedDictionaryRemoval.swift" \
  "$ROOT_DIR/App/DictionaryManagerWindowController.swift" \
  "$ROOT_DIR/Tests/DictionaryManagerLayoutSmoke.swift" \
  -framework AppKit \
  -lsqlite3 \
  -o "$BUILD_DIR/DictionaryManagerLayoutSmoke"

"$BUILD_DIR/DictionaryManagerLayoutSmoke"
