#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/resource-payload-staging-security-smoke"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi

/bin/mkdir -p "$BUILD/debug-module-cache" "$BUILD/release-module-cache"

xcrun --sdk macosx swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -sanitize=address,undefined -module-cache-path "$BUILD/debug-module-cache" \
  "$ROOT/App/ResourceManifestModels.swift" \
  "$ROOT/App/StrictJSON.swift" \
  "$ROOT/App/StrictResourceManifestDecoder.swift" \
  "$ROOT/App/ResourceManifestValidator.swift" \
  "$ROOT/App/ResourceManifestSignature.swift" \
  "$ROOT/App/ResourceManifestVerifier.swift" \
  "$ROOT/App/VerifiedManifestStateStore.swift" \
  "$ROOT/App/ResourceNetworkModels.swift" \
  "$ROOT/App/ResourceNetworkURLPolicy.swift" \
  "$ROOT/App/ResourcePayloadDownloadModels.swift" \
  "$ROOT/App/ResourcePayloadStagingStore.swift" \
  "$ROOT/Tests/ResourcePayloadStagingSecuritySmoke.swift" \
  -o "$BUILD/ResourcePayloadStagingSecuritySmoke-debug"

"$BUILD/ResourcePayloadStagingSecuritySmoke-debug"

xcrun --sdk macosx swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -O -DNDEBUG -module-cache-path "$BUILD/release-module-cache" \
  "$ROOT/App/ResourceManifestModels.swift" \
  "$ROOT/App/StrictJSON.swift" \
  "$ROOT/App/StrictResourceManifestDecoder.swift" \
  "$ROOT/App/ResourceManifestValidator.swift" \
  "$ROOT/App/ResourceManifestSignature.swift" \
  "$ROOT/App/ResourceManifestVerifier.swift" \
  "$ROOT/App/VerifiedManifestStateStore.swift" \
  "$ROOT/App/ResourceNetworkModels.swift" \
  "$ROOT/App/ResourceNetworkURLPolicy.swift" \
  "$ROOT/App/ResourcePayloadDownloadModels.swift" \
  "$ROOT/App/ResourcePayloadStagingStore.swift" \
  "$ROOT/Tests/ResourcePayloadStagingSecuritySmoke.swift" \
  -o "$BUILD/ResourcePayloadStagingSecuritySmoke-release"

"$BUILD/ResourcePayloadStagingSecuritySmoke-release"
