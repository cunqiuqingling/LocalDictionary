#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-resource-payload.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT

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
  "$ROOT/App/DictionaryCatalog.swift" \
  "$ROOT/App/OpenResourceInstallationModels.swift" \
  "$ROOT/App/ResourcePayloadDownloadModels.swift" \
  "$ROOT/App/ResourcePayloadStagingStore.swift" \
  "$ROOT/App/ResourcePayloadFileDownloader.swift" \
  "$ROOT/App/ResourcePayloadDownloadCoordinator.swift" \
  "$ROOT/App/BundledOpenResourceCatalog.swift" \
  "$ROOT/Tests/ResourcePayloadDownloadSmoke.swift" \
  -o "$BUILD/ResourcePayloadDownloadSmoke"

"$BUILD/ResourcePayloadDownloadSmoke"

if /usr/bin/grep -Eq 'URLSession\.shared|\.data\(for:|downloadTask|background\(' \
  "$ROOT/App/ResourcePayloadDownloadModels.swift" \
  "$ROOT/App/ResourcePayloadStagingStore.swift" \
  "$ROOT/App/ResourcePayloadFileDownloader.swift" \
  "$ROOT/App/ResourcePayloadDownloadCoordinator.swift"; then
  print -u2 "D1b-2B payload transport must remain streaming, ephemeral, and foreground-only."
  exit 1
fi

if /usr/bin/grep -Eq 'DictionaryCatalog|DictionaryDescriptor|SQLite|AppDelegate' \
  "$ROOT/App/ResourcePayloadDownloadModels.swift" \
  "$ROOT/App/ResourcePayloadStagingStore.swift" \
  "$ROOT/App/ResourcePayloadFileDownloader.swift" \
  "$ROOT/App/ResourcePayloadDownloadCoordinator.swift"; then
  print -u2 "D1b-2B staging must remain disconnected from Catalog, indexes, and startup."
  exit 1
fi

if /usr/bin/grep -Eq 'ResourcePayloadDownloadCoordinator|ResourcePayloadFileDownloader' \
  "$ROOT/App/AppDelegate.swift" "$ROOT/App/main.swift"; then
  print -u2 "D1b-2B payload download must not be connected to App startup."
  exit 1
fi
