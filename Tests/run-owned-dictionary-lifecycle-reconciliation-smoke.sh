#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/owned-dictionary-lifecycle-reconciliation-smoke"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  elif [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi

SOURCES=(
  "$ROOT/App/AppConfig.swift"
  "$ROOT/App/DictionaryCatalog.swift"
  "$ROOT/App/ResourceManifestKeyID.swift"
  "$ROOT/App/ManagedDictionaryLifecycleCoordinator.swift"
  "$ROOT/App/DictionaryCatalogStore.swift"
  "$ROOT/App/ResourceManifestModels.swift"
  "$ROOT/App/StrictJSON.swift"
  "$ROOT/App/StrictResourceManifestDecoder.swift"
  "$ROOT/App/ResourceManifestValidator.swift"
  "$ROOT/App/ResourceManifestSignature.swift"
  "$ROOT/App/ResourceManifestVerifier.swift"
  "$ROOT/App/VerifiedManifestStateStore.swift"
  "$ROOT/App/OpenResourceInstallationModels.swift"
  "$ROOT/App/ManagedDictionaryQueryModels.swift"
  "$ROOT/App/DictionaryCatalogOrdering.swift"
  "$ROOT/App/ManagedDictionaryRemoval.swift"
  "$ROOT/App/OwnedDictionaryLifecycle.swift"
  "$ROOT/Tests/OwnedDictionaryLifecycleReconciliationSmoke.swift"
)

mkdir -p "$BUILD/debug-module-cache" "$BUILD/release-module-cache"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -D OWNED_LIFECYCLE_TESTING \
  -sanitize=address,undefined \
  -module-cache-path "$BUILD/debug-module-cache" \
  "${SOURCES[@]}" \
  -lsqlite3 \
  -o "$BUILD/OwnedDictionaryLifecycleDebug"

ASAN_OPTIONS=halt_on_error=1 \
UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 \
  "$BUILD/OwnedDictionaryLifecycleDebug"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -O \
  -DNDEBUG \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -D OWNED_LIFECYCLE_TESTING \
  -module-cache-path "$BUILD/release-module-cache" \
  "${SOURCES[@]}" \
  -lsqlite3 \
  -o "$BUILD/OwnedDictionaryLifecycleRelease"

"$BUILD/OwnedDictionaryLifecycleRelease"
