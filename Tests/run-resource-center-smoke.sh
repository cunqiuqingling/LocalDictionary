#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-resource-center.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$WORK/module-cache" \
  "$ROOT/App/AppConfig.swift" \
  "$ROOT/App/ResourceManifestKeyID.swift" \
  "$ROOT/App/ResourceManifestModels.swift" \
  "$ROOT/App/StrictJSON.swift" \
  "$ROOT/App/StrictResourceManifestDecoder.swift" \
  "$ROOT/App/ResourceManifestValidator.swift" \
  "$ROOT/App/ResourceManifestSignature.swift" \
  "$ROOT/App/ResourceManifestVerifier.swift" \
  "$ROOT/App/ResourceNetworkModels.swift" \
  "$ROOT/App/ResourceNetworkURLPolicy.swift" \
  "$ROOT/App/ResourcePayloadDownloadModels.swift" \
  "$ROOT/App/OpenResourceInstallationModels.swift" \
  "$ROOT/App/VerifiedManifestStateStore.swift" \
  "$ROOT/App/DictionaryCatalog.swift" \
  "$ROOT/App/DictionaryCatalogStore.swift" \
  "$ROOT/App/DictionaryCatalogOrdering.swift" \
  "$ROOT/App/ResourceCenterProductionConfiguration.swift" \
  "$ROOT/App/BundledOpenResourceCatalog.swift" \
  "$ROOT/App/OfficialOpenResourceDiscovery.swift" \
  "$ROOT/App/ResourceCenterModels.swift" \
  "$ROOT/Tests/ResourceCenterSmoke.swift" \
  -o "$WORK/ResourceCenterSmoke"

"$WORK/ResourceCenterSmoke"
