#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/open-resource-installation-smoke"
mkdir -p "$BUILD/module-cache"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi
xcrun --sdk macosx swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/DictionaryCatalog.swift" \
  "$ROOT/App/DictionaryCatalogStore.swift" \
  "$ROOT/App/ResourceManifestModels.swift" \
  "$ROOT/App/StrictJSON.swift" \
  "$ROOT/App/StrictResourceManifestDecoder.swift" \
  "$ROOT/App/ResourceManifestValidator.swift" \
  "$ROOT/App/ResourceManifestSignature.swift" \
  "$ROOT/App/ResourceManifestVerifier.swift" \
  "$ROOT/App/VerifiedManifestStateStore.swift" \
  "$ROOT/App/ResourceNetworkModels.swift" \
  "$ROOT/App/ResourceNetworkURLPolicy.swift" \
  "$ROOT/App/OpenResourceInstallationModels.swift" \
  "$ROOT/App/ResourcePayloadDownloadModels.swift" \
  "$ROOT/App/ResourcePayloadStagingStore.swift" \
  "$ROOT/App/OpenResourceInstallationCoordinator.swift" \
  "$ROOT/Tests/OpenResourceInstallationSmoke.swift" \
  -o "$BUILD/OpenResourceInstallationSmoke"
"$BUILD/OpenResourceInstallationSmoke"
