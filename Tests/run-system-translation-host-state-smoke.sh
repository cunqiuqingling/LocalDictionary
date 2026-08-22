#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-translation-host.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/QueryIntentClassifier.swift" \
  "$ROOT/App/ManualEvidenceRecorder.swift" \
  "$ROOT/App/OfflineTranslationModels.swift" \
  "$ROOT/App/SystemTranslationHost.swift" \
  "$ROOT/Tests/SystemTranslationHostStateSmoke.swift" \
  -framework AppKit -framework SwiftUI -framework Translation \
  -o "$BUILD/SystemTranslationHostStateSmoke"

"$BUILD/SystemTranslationHostStateSmoke"
