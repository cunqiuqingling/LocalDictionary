#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-freedict-network.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/ResourceManifestModels.swift" \
  "$ROOT/App/StrictJSON.swift" \
  "$ROOT/App/StrictResourceManifestDecoder.swift" \
  "$ROOT/App/ResourceManifestValidator.swift" \
  "$ROOT/App/ResourceManifestKeyID.swift" \
  "$ROOT/App/ResourceManifestSignature.swift" \
  "$ROOT/App/ResourceManifestVerifier.swift" \
  "$ROOT/App/VerifiedManifestStateStore.swift" \
  "$ROOT/App/ResourceNetworkModels.swift" \
  "$ROOT/App/ResourceNetworkURLPolicy.swift" \
  "$ROOT/App/DictionaryCatalog.swift" \
  "$ROOT/App/OpenResourceInstallationModels.swift" \
  "$ROOT/App/ResourcePayloadDownloadModels.swift" \
  "$ROOT/App/ResourcePayloadStagingStore.swift" \
  "$ROOT/App/ResourcePayloadFileDownloader.swift" \
  "$ROOT/App/ResourcePayloadDownloadCoordinator.swift" \
  "$ROOT/App/BundledOpenResourceCatalog.swift" \
  "$ROOT/Tests/OpenResourceNetworkDownloadSmoke.swift" \
  -o "$BUILD/OpenResourceNetworkDownloadSmoke"

"$BUILD/OpenResourceNetworkDownloadSmoke"
