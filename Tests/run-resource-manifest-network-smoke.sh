#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/resource-manifest-network-smoke"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi

/bin/mkdir -p "$BUILD/module-cache"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -module-cache-path "$BUILD/module-cache" \
  -strict-concurrency=complete \
  -warnings-as-errors \
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
  "$ROOT/App/BoundedHTTPSDataFetcher.swift" \
  "$ROOT/App/ResourceManifestRemoteLoader.swift" \
  "$ROOT/Tests/ResourceManifestNetworkSmoke.swift" \
  -o "$BUILD/ResourceManifestNetworkSmoke"

"$BUILD/ResourceManifestNetworkSmoke"

if /usr/bin/grep -Eq 'URLSession\.shared|data\(for:' \
  "$ROOT/App/ResourceNetworkModels.swift" \
  "$ROOT/App/ResourceNetworkURLPolicy.swift" \
  "$ROOT/App/BoundedHTTPSDataFetcher.swift" \
  "$ROOT/App/ResourceManifestRemoteLoader.swift"; then
  print -u2 "D1b-2A transport must not use shared session or data(for:)."
  exit 1
fi

if /usr/bin/grep -Eq 'ResourceManifestRemoteLoader|ResourceManifestEndpoint' \
  "$ROOT/App/AppDelegate.swift" "$ROOT/App/main.swift"; then
  print -u2 "D1b-2A transport must remain disconnected from App startup."
  exit 1
fi
