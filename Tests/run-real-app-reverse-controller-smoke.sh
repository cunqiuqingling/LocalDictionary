#!/bin/zsh
set -euo pipefail
unsetopt BG_NICE

ROOT="${0:A:h:h}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-real-reverse.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun --find clang)"
CXX="$(xcrun --find clang++)"
MINIZ="$ROOT/ThirdParty/vendor/miniz"

for source in miniz.c miniz_tinfl.c miniz_tdef.c; do
  "$CC" -std=c17 -Wall -Wextra -Werror -isysroot "$SDKROOT" \
    -I"$MINIZ" -c "$MINIZ/$source" -o "$WORK/${source%.c}.o"
done
"$CXX" -std=c++17 -Wall -Wextra -Werror -isysroot "$SDKROOT" \
  -I"$ROOT/Tests" -I"$ROOT/ThirdParty/vendor" \
  "$ROOT/Tests/GenerateReverseControllerFixture.cpp" \
  "$WORK/miniz.o" "$WORK/miniz_tinfl.o" "$WORK/miniz_tdef.o" \
  -o "$WORK/generate-fixture"

ISOLATED="$WORK/IsolatedApplicationSupport"
/bin/mkdir -m 700 "$ISOLATED"
SOURCE="$ISOLATED/legacy-controller-fixture.mdx"
FORWARD="$ISOLATED/legacy-controller-fixture.sqlite"
LATE_PROBE_SOURCE="$ISOLATED/managed-probe-late-chinese.mdx"
LATE_PROBE_FORWARD="$ISOLATED/managed-probe-late-chinese.sqlite"
NO_GLOSS_SOURCE="$ISOLATED/managed-probe-english-only.mdx"
NO_GLOSS_FORWARD="$ISOLATED/managed-probe-english-only.sqlite"
"$WORK/generate-fixture" "$SOURCE"
"$WORK/generate-fixture" "$LATE_PROBE_SOURCE" late-chinese
"$WORK/generate-fixture" "$NO_GLOSS_SOURCE" english-only

DERIVED="$WORK/DerivedData"
"$DEVELOPER_DIR/usr/bin/xcodebuild" \
  -project "$ROOT/App/LocalDictionary.xcodeproj" \
  -scheme LocalDictionary \
  -configuration Debug \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -DREVERSE_INDEX_CONTROLLER_TESTING' \
  build >/dev/null

APP="$DERIVED/Build/Products/Debug/LocalDictionary.app"
EXECUTABLE="$APP/Contents/MacOS/LocalDictionary"
[[ -x "$EXECUTABLE" ]] || { print -u2 "real App executable missing"; exit 1; }

CRASH_DIRECTORY="$HOME/Library/Logs/DiagnosticReports"
BEFORE="$WORK/crashes-before.txt"
AFTER="$WORK/crashes-after.txt"
/usr/bin/find "$CRASH_DIRECTORY" -maxdepth 1 -type f \
  \( -name 'LocalDictionary*.ips' -o -name 'LocalDictionary*.crash' \) \
  -print 2>/dev/null | /usr/bin/sort >"$BEFORE" || true

run_app() {
  local mode="$1"
  local result="$2"
  local source="${3:-$SOURCE}"
  local index="${4:-$FORWARD}"
  LOCALDICTIONARY_REVERSE_TEST_MODE="$mode" \
  LOCALDICTIONARY_REVERSE_TEST_ROOT="$ISOLATED" \
  LOCALDICTIONARY_REVERSE_TEST_SOURCE="$source" \
  LOCALDICTIONARY_REVERSE_TEST_INDEX="$index" \
  LOCALDICTIONARY_REVERSE_TEST_NO_GLOSS_SOURCE="$NO_GLOSS_SOURCE" \
  LOCALDICTIONARY_REVERSE_TEST_NO_GLOSS_INDEX="$NO_GLOSS_FORWARD" \
  LOCALDICTIONARY_REVERSE_TEST_RESULT="$result" \
    "$EXECUTABLE" >"$WORK/$mode.log" 2>&1 &
  local process_id=$!
  local elapsed=0
  while /bin/kill -0 "$process_id" 2>/dev/null; do
    if (( elapsed >= 600 )); then
      /bin/kill "$process_id" 2>/dev/null || true
      print -u2 "real App integration timed out: $mode"
      exit 1
    fi
    /bin/sleep 1
    (( elapsed += 1 ))
  done
  if ! wait "$process_id"; then
    print -u2 "real App integration exited unsuccessfully: $mode"
    /bin/cat "$WORK/$mode.log" >&2
    exit 1
  fi
  [[ -f "$result" ]] || { print -u2 "real App result missing: $mode"; exit 1; }
}

FIRST_RESULT="$ISOLATED/first-result.json"
MIXED_RESULT="$ISOLATED/mixed-result.json"
PANEL_RESULT="$ISOLATED/panel-result.json"
PREFERRED_RESULT="$ISOLATED/preferred-result.json"
AFFIX_FAILURE_RESULT="$ISOLATED/affix-failure-result.json"
MANAGED_PROBE_RESULT="$ISOLATED/managed-probe-boundaries-result.json"
SECOND_RESULT="$ISOLATED/relaunch-result.json"
run_app first-launch "$FIRST_RESULT"
[[ "$(/usr/bin/plutil -extract controllerAction raw "$FIRST_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract ready raw "$FIRST_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract lookupApple raw "$FIRST_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract cleanTerminationRequested raw "$FIRST_RESULT")" == true ]]
FREEDICT_CAPABILITY="$(/usr/bin/plutil -extract capabilityFreeDict raw "$FIRST_RESULT")"
[[ -z "$FREEDICT_CAPABILITY" || "$FREEDICT_CAPABILITY" == *"已随资源建立"* ]]
[[ "$(/usr/bin/plutil -extract hiddenStarterCCCEDICT raw "$FIRST_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract capabilityWordNet raw "$FIRST_RESULT")" == *"英语查询"* ]]
[[ "$(/usr/bin/plutil -extract capabilityGCIDE raw "$FIRST_RESULT")" == *"英语查询"* ]]
[[ "$(/usr/bin/plutil -extract hiddenStarterKaikki raw "$FIRST_RESULT")" == true ]]

run_app mixed-build-all "$MIXED_RESULT"
[[ "$(/usr/bin/plutil -extract controllerAction raw "$MIXED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract batchTotal raw "$MIXED_RESULT")" == 3 ]]
[[ "$(/usr/bin/plutil -extract batchReady raw "$MIXED_RESULT")" == 3 ]]
[[ "$(/usr/bin/plutil -extract batchFailed raw "$MIXED_RESULT")" == 0 ]]
[[ "$(/usr/bin/plutil -extract skippedReady raw "$MIXED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract excludedUnsupported raw "$MIXED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract unsupportedCapability raw "$MIXED_RESULT")" == *"格式"* ]]
[[ "$(/usr/bin/plutil -extract ready raw "$MIXED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract lookupApple raw "$MIXED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract cleanTerminationRequested raw "$MIXED_RESULT")" == true ]]

run_app preferred-formatters "$PREFERRED_RESULT"
[[ "$(/usr/bin/plutil -extract controllerAction raw "$PREFERRED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract preferredBatchTotal raw "$PREFERRED_RESULT")" == 3 ]]
[[ "$(/usr/bin/plutil -extract preferredBatchReady raw "$PREFERRED_RESULT")" == 3 ]]
[[ "$(/usr/bin/plutil -extract preferredBatchFailed raw "$PREFERRED_RESULT")" == 0 ]]
[[ "$(/usr/bin/plutil -extract excludedNewOxford raw "$PREFERRED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract excludedAffix raw "$PREFERRED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract affixCapability raw "$PREFERRED_RESULT")" == *"暂不支持"* ]]
[[ "$(/usr/bin/plutil -extract minimumChineseEntries raw "$PREFERRED_RESULT")" == 5 ]]
[[ "$(/usr/bin/plutil -extract oxfordApple raw "$PREFERRED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract centuryApple raw "$PREFERRED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract centuryDownload raw "$PREFERRED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract centuryValidation raw "$PREFERRED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract medicalLiver raw "$PREFERRED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract medicalKidney raw "$PREFERRED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract newOxfordSidecarAbsent raw "$PREFERRED_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract newOxfordCapability raw "$PREFERRED_RESULT")" == *"中文释义"* ]]
[[ "$(/usr/bin/plutil -extract cleanTerminationRequested raw "$PREFERRED_RESULT")" == true ]]

run_app affix-failure-state "$AFFIX_FAILURE_RESULT"
print "Real App Affix failure diagnostic: $(/bin/cat "$AFFIX_FAILURE_RESULT")"
[[ "$(/usr/bin/plutil -extract controllerAction raw "$AFFIX_FAILURE_RESULT")" == false ]]
[[ "$(/usr/bin/plutil -extract affixExcludedFromBuild raw "$AFFIX_FAILURE_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract affixRetryDisabled raw "$AFFIX_FAILURE_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract affixStableStatus raw "$AFFIX_FAILURE_RESULT")" == *"暂不支持"* ]]
[[ "$(/usr/bin/plutil -extract affixTypedReason raw "$AFFIX_FAILURE_RESULT")" == *"unsupportedGlossStructure"* ]]
[[ "$(/usr/bin/plutil -extract cleanTerminationRequested raw "$AFFIX_FAILURE_RESULT")" == true ]]

run_app managed-probe-boundaries "$MANAGED_PROBE_RESULT" \
  "$LATE_PROBE_SOURCE" "$LATE_PROBE_FORWARD"
print "Managed reverse capability sample/full diagnostic: $(/bin/cat "$MANAGED_PROBE_RESULT")"
[[ "$(/usr/bin/plutil -extract lateSampleResult raw "$MANAGED_PROBE_RESULT")" == unknown ]]
[[ "$(/usr/bin/plutil -extract lateSampleReason raw "$MANAGED_PROBE_RESULT")" == \
  sampleLimitReached ]]
[[ "$(/usr/bin/plutil -extract lateSampleProcessed raw "$MANAGED_PROBE_RESULT")" == 512 ]]
[[ "$(/usr/bin/plutil -extract lateSampleBounded raw "$MANAGED_PROBE_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract lateFullResult raw "$MANAGED_PROBE_RESULT")" == supported ]]
[[ "$(/usr/bin/plutil -extract lateFullReason raw "$MANAGED_PROBE_RESULT")" == \
  usableNativeGlossFound ]]
[[ "$(/usr/bin/plutil -extract lateFullProcessed raw "$MANAGED_PROBE_RESULT")" == 513 ]]
[[ "$(/usr/bin/plutil -extract lateFullFoundEntry513 raw "$MANAGED_PROBE_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract noGlossSampleResult raw "$MANAGED_PROBE_RESULT")" == unknown ]]
[[ "$(/usr/bin/plutil -extract noGlossSampleReason raw "$MANAGED_PROBE_RESULT")" == \
  sampleLimitReached ]]
[[ "$(/usr/bin/plutil -extract noGlossSampleProcessed raw "$MANAGED_PROBE_RESULT")" == 512 ]]
[[ "$(/usr/bin/plutil -extract noGlossSampleBounded raw "$MANAGED_PROBE_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract noGlossFullResult raw "$MANAGED_PROBE_RESULT")" == \
  noUsableNativeGloss ]]
[[ "$(/usr/bin/plutil -extract noGlossFullReason raw "$MANAGED_PROBE_RESULT")" == \
  endOfFileNoUsableNativeGloss ]]
[[ "$(/usr/bin/plutil -extract noGlossFullProcessed raw "$MANAGED_PROBE_RESULT")" == 513 ]]
[[ "$(/usr/bin/plutil -extract noGlossFullReachedEOF raw "$MANAGED_PROBE_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract cleanTerminationRequested raw "$MANAGED_PROBE_RESULT")" == true ]]

run_app panel-flow "$PANEL_RESULT"
print "Real App panel-flow diagnostic: $(/bin/cat "$PANEL_RESULT")"
[[ "$(/usr/bin/plutil -extract appleLifecycleSameAppOperations raw "$PANEL_RESULT")" == 50 ]]
[[ "$(/usr/bin/plutil -extract appleLifecycleSuccesses raw "$PANEL_RESULT")" == 45 ]]
[[ "$(/usr/bin/plutil -extract appleLifecycleInjectedFailures raw "$PANEL_RESULT")" == 5 ]]
[[ "$(/usr/bin/plutil -extract appleLifecycleRecoverySuccesses raw "$PANEL_RESULT")" == 5 ]]
[[ "$(/usr/bin/plutil -extract appleLifecycleStaleCallbacksRejected raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract appleLifecyclePendingZero raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract appleLifecycleHealthy raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract tripleReturnExplanationCalls raw "$PANEL_RESULT")" == 1 ]]
[[ "$(/usr/bin/plutil -extract tripleReturnAIVisible raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract managedReverseCapabilityProbeSupported raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract installedReverseVisible raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract installedOfflineTitle raw "$PANEL_RESULT")" == \
  *"Apple"*"简体中文"*"English"* ]]
[[ "$(/usr/bin/plutil -extract installedAIVisible raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract installedAction raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract installedTranslationVisible raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseAIStarEnabled raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseAINoteOnlyAI raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseAISaved raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseAIStarFilledAfterSave raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseAIMarkdownOnlyAI raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract timeoutReverseVisible raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract timeoutAIVisibleBefore raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract timeoutAction raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract timeoutFallbackVisible raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract timeoutAIVisibleAfter raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longAIVisibleDuringWait raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longAITranslationVisibleDuringWait raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longAITranslationTitle raw "$PANEL_RESULT")" == \
  "AI 深度翻译" ]]
[[ "$(/usr/bin/plutil -extract longAISentenceTitle raw "$PANEL_RESULT")" == \
  "逐句 AI 深度分析" ]]
[[ "$(/usr/bin/plutil -extract longSeparateAISections raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longBasicVisibleDuringWait raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longFallbackVisible raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longAIVisibleAfterFallback raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longBaseStarEnabled raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longAINoteHasBoth raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longSaved raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longStarFilledAfterSave raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract longMarkdownComplete raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract englishLongStudyIsEnglish raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract englishLongAnalysisUsesStudyText raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongAIVisibleDuringWait raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongAITranslationVisibleDuringWait raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongFallbackVisible raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongAIVisibleAfterFallback raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongNaturalEnglish raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongStudyIsEnglish raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongAnalysisUsesEnglishStudyText raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongDoesNotAnalyzeChineseGrammar raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongFavoriteLanguageMetadata raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongSaved raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongStarFilledAfterSave raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract chineseLongMarkdownComplete raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract analysisFirstAction raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract analysisOnlyCacheButtonVisible raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract analysisOnlyCacheButtonIsReal raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract translationAfterAnalysisAction raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract analysisFirstCanonicalStable raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract analysisFirstSingleTranslationCall raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract cacheClearRemovedAIArtifacts raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract cacheClearRetainedLocalResult raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract cacheClearButtonHiddenAfterClear raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract translationFirstAction raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract translationOnlyCacheButtonVisible raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract translationOnlyCacheButtonIsReal raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract analysisAfterTranslationAction raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract translationFirstCanonicalStable raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract bothAIUsesOneCacheButton raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract bothClickOrdersOneTranslationEach raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract learningDeepTranslationAction raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract learningSentenceAnalysisAction raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract learningDeepTranslationWasFullContext raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract learningSentenceAnalysisPromotedCanonicalTranslation raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract pureNativeProductionTargetEnglish raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract pureNativeProductionUI raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract pureLearningProductionTargetNative raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract pureLearningProductionUI raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract pollutedLearningProductionTargetNative raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract pollutedLearningProductionNormalizedQuery raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract pollutedLearningProductionUI raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract mixedProductionBidirectional raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract mixedProductionIndependentOperations raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract mixedProductionUI raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract mixedOfflineStudyTextIsLearningOnly raw "$PANEL_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract cleanTerminationRequested raw "$PANEL_RESULT")" == true ]]

run_app verify-relaunch "$SECOND_RESULT"
[[ "$(/usr/bin/plutil -extract ready raw "$SECOND_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract lookupApple raw "$SECOND_RESULT")" == true ]]
[[ "$(/usr/bin/plutil -extract cleanTerminationRequested raw "$SECOND_RESULT")" == true ]]

/usr/bin/find "$CRASH_DIRECTORY" -maxdepth 1 -type f \
  \( -name 'LocalDictionary*.ips' -o -name 'LocalDictionary*.crash' \) \
  -print 2>/dev/null | /usr/bin/sort >"$AFTER" || true
if ! /usr/bin/cmp -s "$BEFORE" "$AFTER"; then
  print -u2 "real App integration produced a new LocalDictionary crash report"
  /usr/bin/comm -13 "$BEFORE" "$AFTER" >&2
  exit 1
fi

print "Real App reverse controller first launch: $(/bin/cat "$FIRST_RESULT")"
print "Real App reverse controller mixed build-all: $(/bin/cat "$MIXED_RESULT")"
print "Real App Preferred formatter compatibility: $(/bin/cat "$PREFERRED_RESULT")"
print "Real App Affix failure-state retention: $(/bin/cat "$AFFIX_FAILURE_RESULT")"
print "Real App managed probe boundaries: $(/bin/cat "$MANAGED_PROBE_RESULT")"
print "Real App Chinese/long-text panel flow: $(/bin/cat "$PANEL_RESULT")"
print "Real App reverse controller relaunch: $(/bin/cat "$SECOND_RESULT")"
print "Real App reverse controller smoke: PASS (no new crash report)"
