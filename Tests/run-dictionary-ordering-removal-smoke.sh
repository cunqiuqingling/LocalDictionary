#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/dictionary-ordering-removal-smoke"
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
  -D OWNED_LIFECYCLE_TESTING \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/AppConfig.swift" \
  "$ROOT/App/DictionaryCatalog.swift" \
  "$ROOT/App/ResourceManifestKeyID.swift" \
  "$ROOT/App/ManagedDictionaryLifecycleCoordinator.swift" \
  "$ROOT/App/DictionaryCatalogStore.swift" \
  "$ROOT/App/ResourceManifestModels.swift" \
  "$ROOT/App/StrictJSON.swift" \
  "$ROOT/App/StrictResourceManifestDecoder.swift" \
  "$ROOT/App/ResourceManifestValidator.swift" \
  "$ROOT/App/ResourceManifestSignature.swift" \
  "$ROOT/App/ResourceManifestVerifier.swift" \
  "$ROOT/App/VerifiedManifestStateStore.swift" \
  "$ROOT/App/OpenResourceInstallationModels.swift" \
  "$ROOT/App/LegacyDictionaryConfigAdapter.swift" \
  "$ROOT/App/DictionaryCatalogOrdering.swift" \
  "$ROOT/App/ManagedDictionaryQueryModels.swift" \
  "$ROOT/App/ManagedDictionaryRemoval.swift" \
  "$ROOT/Tests/DictionaryOrderingRemovalSmoke.swift" \
  -lsqlite3 \
  -o "$BUILD/DictionaryOrderingRemovalSmoke"

"$BUILD/DictionaryOrderingRemovalSmoke"
