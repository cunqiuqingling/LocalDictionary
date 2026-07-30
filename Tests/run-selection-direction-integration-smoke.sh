#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-selection-direction.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
/bin/mkdir -p "$BUILD/module-cache"

/usr/bin/xcrun swiftc \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -module-cache-path "$BUILD/module-cache" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework Carbon \
    -framework NaturalLanguage \
    "$ROOT/App/QueryIntentClassifier.swift" \
    "$ROOT/App/OfflineTranslationModels.swift" \
    "$ROOT/App/LocalSentenceGlossaryService.swift" \
    "$ROOT/App/LongTextAnalysis.swift" \
    "$ROOT/App/AccessibilitySelection.swift" \
    "$ROOT/App/SelectionButtonPlacement.swift" \
    "$ROOT/Tests/SelectionDirectionIntegrationSmoke.swift" \
    -o "$BUILD/SelectionDirectionIntegrationSmoke"

"$BUILD/SelectionDirectionIntegrationSmoke"

/usr/bin/grep -Fq 'capture.selectionRects' "$ROOT/App/AppDelegate.swift"
/usr/bin/grep -Fq 'globalSelectionPlacement.present' \
    "$ROOT/App/DictionaryPanelController.swift"
/usr/bin/grep -Fq 'applyGlobalSelectionWindowFrame(result.frame' \
    "$ROOT/App/SelectionButtonPlacement.swift"
/usr/bin/grep -Fq 'LongTextActionRouter.parse' \
    "$ROOT/App/DictionaryPanelController.swift"
/usr/bin/grep -Fq 'prepareLanguagePack: true' \
    "$ROOT/App/DictionaryPanelController.swift"
/usr/bin/grep -Fq 'cancelOperation(id: operationID)' \
    "$ROOT/App/SystemTranslationHost.swift"
/usr/bin/grep -Fq 'static let maximumPendingOperations = 8' \
    "$ROOT/App/SystemTranslationHost.swift"
/usr/bin/grep -Fq 'guard canEnqueueOperation' \
    "$ROOT/App/SystemTranslationHost.swift"
if /usr/bin/grep -Fq 'cancelQueuedOperations()' \
    "$ROOT/App/SystemTranslationHost.swift"; then
    print -u2 "sentence cancellation still cancels unrelated translation operations"
    exit 1
fi

DIRECTION_ACTIONS="$(/usr/bin/sed -n \
    '/private func performLongTextNativeAction/,/private func requestLongTextSentenceAI/p' \
    "$ROOT/App/DictionaryPanelController.swift")"
if print -r -- "$DIRECTION_ACTIONS" |
   /usr/bin/grep -Eq 'aiService|AIProviderClient|URLSession'; then
    print -u2 "direction action references an AI provider or network client"
    exit 1
fi

if /usr/bin/grep -Eq \
    'NSScreenCaptureUsageDescription|CGWindowListCreateImage|ScreenCaptureKit' \
    "$ROOT/App/Info.plist" "$ROOT/App"/*.swift; then
    print -u2 "selection production integration crossed screen-recording boundary"
    exit 1
fi

print "Selection/direction production structural gates PASS"
