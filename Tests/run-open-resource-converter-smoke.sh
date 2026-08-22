#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
ASSET="${1:-}"
if [[ -z "$ASSET" || ! -f "$ASSET" ]]; then
  print -u2 "usage: $0 /absolute/path/to/freedict-eng-zho-2025.11.23.stardict.tar.xz"
  exit 2
fi
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-open-resource.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -D OPEN_RESOURCE_CONVERTER_TESTING \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/ResourceManifestKeyID.swift" \
  "$ROOT/App/DictionaryCatalog.swift" \
  "$ROOT/App/DictionaryCatalogStore.swift" \
  "$ROOT/App/OpenResourceInstallationModels.swift" \
  "$ROOT/App/BundledOpenResourceCatalog.swift" \
  "$ROOT/App/ReverseLookup.swift" \
  "$ROOT/App/FreeDictStarDictResource.swift" \
  "$ROOT/App/AuditedOpenResourceInstaller.swift" \
  "$ROOT/Tests/OpenResourceConverterSmoke.swift" \
  -framework AppKit -lsqlite3 -larchive \
  -o "$BUILD/OpenResourceConverterSmoke"

"$BUILD/OpenResourceConverterSmoke" "$ASSET"
