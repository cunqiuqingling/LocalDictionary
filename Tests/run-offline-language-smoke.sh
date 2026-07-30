#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-offline-language.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
/bin/mkdir -p "$BUILD/module-cache"

/usr/bin/xcrun swiftc \
    -module-cache-path "$BUILD/module-cache" \
    -framework AppKit \
    -framework NaturalLanguage \
    -lsqlite3 \
    "$ROOT/App/QueryIntentClassifier.swift" \
    "$ROOT/App/OfflineTranslationModels.swift" \
    "$ROOT/App/LocalSentenceGlossaryService.swift" \
    "$ROOT/App/LongTextAnalysis.swift" \
    "$ROOT/App/ReverseLookup.swift" \
    "$ROOT/App/SelectionButtonPlacement.swift" \
    "$ROOT/Tests/OfflineLanguageSmoke.swift" \
    -o "$BUILD/OfflineLanguageSmoke"

"$BUILD/OfflineLanguageSmoke"
