#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
if [[ "${1:-}" != "--live" ]] && (( $# % 2 != 0 )); then
  print -u2 "usage: $0 [resource-id /absolute/public/payload ...]"
  exit 2
fi
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-open-full.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"

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
  "$ROOT/App/BundledOpenResourceCatalog.swift"
  "$ROOT/App/OfficialOpenResourceDiscovery.swift"
  "$ROOT/App/FreeDictStarDictResource.swift"
  "$ROOT/App/AuditedOpenResourceInstaller.swift"
  "$ROOT/Tests/OpenResourceFullLifecycleSmoke.swift"
)

/bin/mkdir -p "$BUILD/module-cache"
xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -D OWNED_LIFECYCLE_TESTING \
  -D OPEN_RESOURCE_CONVERTER_TESTING \
  -module-cache-path "$BUILD/module-cache" \
  "${SOURCES[@]}" \
  -lsqlite3 -larchive \
  -o "$BUILD/OpenResourceFullLifecycleSmoke"

"$BUILD/OpenResourceFullLifecycleSmoke" "$@"
