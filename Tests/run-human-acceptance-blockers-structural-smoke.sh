#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
ASSERTIONS=0

require_fixed() {
  /usr/bin/grep -Fq -- "$1" "$2" || {
    print -u2 "missing human-acceptance lifecycle structure: $1 ($2)"
    exit 1
  }
  (( ASSERTIONS += 1 ))
}

forbid_pattern() {
  local pattern="$1"
  shift
  if /usr/bin/grep -E "$pattern" "$@" >/dev/null; then
    print -u2 "forbidden blocking/busy-loop structure matched: $pattern"
    exit 1
  fi
  (( ASSERTIONS += 1 ))
}

require_fixed 'func applicationShouldTerminate' "$ROOT/App/AppDelegate.swift"
require_fixed 'return .terminateNow' "$ROOT/App/AppDelegate.swift"
require_fixed 'panelController?.prepareForTermination()' "$ROOT/App/AppDelegate.swift"
require_fixed 'resourceCenterController.prepareForTermination()' "$ROOT/App/AppDelegate.swift"
require_fixed 'reverseIndexCoordinator.cancel()' "$ROOT/App/AppDelegate.swift"
require_fixed 'dictionaryIndexCoordinator.cancelCurrentTask()' "$ROOT/App/AppDelegate.swift"
require_fixed 'await backgroundWorkCoordinator.cancelAllWaiting()' "$ROOT/App/AppDelegate.swift"
forbid_pattern 'DispatchSemaphore|\.wait[[:space:]]*\(' \
  "$ROOT/App/AppDelegate.swift" \
  "$ROOT/App/ReverseIndexCoordinator.swift" \
  "$ROOT/App/OfflineTranslationModels.swift" \
  "$ROOT/App/SystemTranslationHost.swift"

for stage in notBuilt queued readingEntries writingIndex optimizing validating \
  publishing ready cancelling cancelled failed stale; do
  require_fixed "case $stage" "$ROOT/App/ReverseLookup.swift"
done
require_fixed 'Task.detached(priority: .utility)' "$ROOT/App/ReverseIndexCoordinator.swift"
require_fixed 'case .serious: return 20_000' "$ROOT/App/ReverseIndexCoordinator.swift"
require_fixed 'case .critical: return 100_000' "$ROOT/App/ReverseIndexCoordinator.swift"
require_fixed 'defaultTransactionBatchSize = 4_096' "$ROOT/App/ReverseLookup.swift"
require_fixed 'sqlite3_progress_handler(' "$ROOT/App/ReverseLookup.swift"
require_fixed 'PRAGMA quick_check(1)' "$ROOT/App/ReverseLookup.swift"
require_fixed 'static func runFullIntegrityDiagnostics' "$ROOT/App/ReverseLookup.swift"
require_fixed 'guard stage == .readingEntries || stage == .writingIndex' \
  "$ROOT/App/ReverseIndexCoordinator.swift"
require_fixed '正在执行可取消的快速安全验证；此阶段不显示伪造百分比。' \
  "$ROOT/App/DictionaryManagerPresentation.swift"
require_fixed 'case .unsupportedFormatter' "$ROOT/App/ReverseLookup.swift"
require_fixed 'case .enumerationUnsupported' "$ROOT/App/ReverseLookup.swift"
require_fixed 'case .insufficientChineseDefinitions' "$ROOT/App/ReverseLookup.swift"
require_fixed 'case .malformedRecords' "$ROOT/App/ReverseLookup.swift"
require_fixed 'case .validationFailed' "$ROOT/App/ReverseLookup.swift"
require_fixed 'event(failureEvent(for: source, error: error))' \
  "$ROOT/App/ReverseIndexCoordinator.swift"

NORMAL_FINISH="${TMPDIR:-/tmp}/LocalDictionary-reverse-normal-finish.$$.txt"
trap '/bin/rm -f "$NORMAL_FINISH"' EXIT
/usr/bin/sed -n '/func finish(/,/static func runFullIntegrityDiagnostics/p' \
  "$ROOT/App/ReverseLookup.swift" >"$NORMAL_FINISH"
forbid_pattern 'PRAGMA integrity_check' "$NORMAL_FINISH"

require_fixed 'glossary: localGlossaryService' "$ROOT/App/DictionaryPanelController.swift"
require_fixed 'static let maximumItems = 15' "$ROOT/App/LongTextAnalysis.swift"
require_fixed 'LocalBasicTranslationEngine' "$ROOT/App/OfflineTranslationModels.swift"
require_fixed 'case deadlineExceeded' "$ROOT/App/OfflineTranslationModels.swift"
require_fixed 'static func initialResult(for source: String)' "$ROOT/App/LongTextAnalysis.swift"
require_fixed 'configureLongTextAIAction' "$ROOT/App/DictionaryPanelController.swift"
forbid_pattern '本地词典暂无可靠释义|来源：基础词法筛选' \
  "$ROOT/App/LongTextAnalysis.swift" "$ROOT/App/DictionaryPanelController.swift"

require_fixed 'override func cancelOperation' "$ROOT/App/ResourceCenterViewController.swift"
require_fixed 'override func performClose' "$ROOT/App/DictionaryManagerWindowController.swift"
require_fixed 'func windowWillClose' "$ROOT/App/DictionaryManagerWindowController.swift"
require_fixed 'closeButton.title = t("关闭", "Close")' "$ROOT/App/ResourceCenterViewController.swift"

require_fixed 'manifestEndpoint: nil' "$ROOT/App/ResourceCenterProductionConfiguration.swift"
for host in wordnetcode.princeton.edu ftp.gnu.org; do
  require_fixed "\"$host\"" "$ROOT/App/ResourceCenterProductionConfiguration.swift"
done
for hidden_host in download.freedict.org www.mdbg.net kaikki.org; do
  forbid_pattern "\"$hidden_host\"" "$ROOT/App/ResourceCenterProductionConfiguration.swift"
done
require_fixed 'trustedManifestKeys: []' "$ROOT/App/ResourceCenterProductionConfiguration.swift"

print "Human acceptance blocker structural smoke: PASS ($ASSERTIONS/$ASSERTIONS)"
