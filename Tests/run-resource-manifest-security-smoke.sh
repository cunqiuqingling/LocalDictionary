#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/resource-manifest-security-smoke"

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
  "$ROOT/Tests/ResourceManifestSecuritySmoke.swift" \
  -o "$BUILD/ResourceManifestSecuritySmoke"

"$BUILD/ResourceManifestSecuritySmoke"
