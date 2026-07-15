#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$ROOT/.build/ai-service-smoke"
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi
mkdir -p "$BUILD"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/QueryIntentClassifier.swift" \
  "$ROOT/App/AIProviderConfiguration.swift" \
  "$ROOT/App/AIKeychainStore.swift" \
  "$ROOT/App/AIProviderCredentialSession.swift" \
  "$ROOT/App/AIProviderProfileManager.swift" \
  "$ROOT/App/AIProviderSettingsSession.swift" \
  "$ROOT/App/AISentenceAnalysis.swift" \
  "$ROOT/App/InlineLookupModels.swift" \
  "$ROOT/App/AIProviderClient.swift" \
  "$ROOT/App/AIExplanationCache.swift" \
  "$ROOT/App/AIExplanationService.swift" \
  "$ROOT/App/AIEntryFormatter.swift" \
  "$ROOT/App/AISentenceEntryFormatter.swift" \
  "$ROOT/App/LocalSentenceGlossaryService.swift" \
  "$ROOT/App/LocalSentenceGlossaryFormatter.swift" \
  "$ROOT/App/ObsidianNoteStore.swift" \
  "$ROOT/App/AIExplanationMarkdownFormatter.swift" \
  "$ROOT/App/SentenceAnalysisMarkdownFormatter.swift" \
  "$ROOT/Tests/AIServiceSmoke.swift" \
  -framework AppKit -framework NaturalLanguage -framework Security -lsqlite3 \
  -o "$BUILD/AIServiceSmoke"

"$BUILD/AIServiceSmoke"
