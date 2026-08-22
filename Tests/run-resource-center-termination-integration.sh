#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-termination-integration.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
DERIVED="$WORK/DerivedData"
APP="$DERIVED/Build/Products/Debug/LocalDictionary.app"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi

xcodebuild \
  -project "$ROOT/App/LocalDictionary.xcodeproj" \
  -scheme LocalDictionary \
  -configuration Debug \
  -arch arm64 \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  'OTHER_SWIFT_FLAGS=$(inherited) -D TERMINATION_INTEGRATION_TESTING' \
  build >"$WORK/build.log"

expect_json() {
  local file="$1"
  local literal="$2"
  /usr/bin/grep -Fq "$literal" "$file" || {
    print -u2 "termination report missing: $literal"
    /bin/cat "$file" >&2
    return 1
  }
}

run_scenario() {
  local mode="$1"
  local expected_source="$2"
  local scenario_root="$WORK/$mode"
  local report="$scenario_root/result.json"
  /bin/mkdir -p "$scenario_root"

  /usr/bin/open -W -n "$APP" --args \
    --termination-test-mode "$mode" \
    --termination-test-root "$scenario_root" \
    --termination-test-result "$report" &
  local opener_pid=$!
  local deadline=$((SECONDS + 12))
  while /bin/kill -0 "$opener_pid" 2>/dev/null; do
    if (( SECONDS >= deadline )); then
      /bin/kill -TERM "$opener_pid" 2>/dev/null || true
      if [[ -f "$report" ]]; then
        local app_pid
        app_pid="$(/usr/bin/sed -n 's/.*"process" : \([0-9][0-9]*\).*/\1/p' "$report")"
        [[ -z "$app_pid" ]] || /bin/kill -TERM "$app_pid" 2>/dev/null || true
        /bin/cat "$report" >&2
      fi
      print -u2 "termination scenario timed out without kill -9: $mode"
      return 1
    fi
    /bin/sleep 0.1
  done
  wait "$opener_pid"

  [[ -f "$report" ]] || { print -u2 "missing termination report: $mode"; return 1; }
  expect_json "$report" '"mainMenuConfigured" : true'
  expect_json "$report" '"applicationSubclassActive" : true'
  expect_json "$report" '"commandQKeyEquivalent" : true'
  expect_json "$report" '"sheetPresented" : true'
  expect_json "$report" '"resourceCenterOpen" : true'
  expect_json "$report" '"terminationRequested" : true'
  expect_json "$report" "\"terminationSource\" : \"$expected_source\""
  expect_json "$report" '"terminationCancellationIssued" : true'
  expect_json "$report" '"sheetEnded" : true'
  expect_json "$report" '"terminationDecision" : "terminateNow"'
  expect_json "$report" '"terminationCompleted" : true'
  expect_json "$report" '"resourceReadyState" : false'
  if [[ "$expected_source" == "commandQ" ]]; then
    expect_json "$report" '"commandQHandledBySheet" : true'
  fi

  case "$mode" in
    download-command-q)
      expect_json "$report" '"activeDownloadCount" : 1'
      ;;
    conversion-command-q)
      expect_json "$report" '"activeConversionCount" : 1'
      ;;
    heavy-wait-command-q)
      expect_json "$report" '"activeDownloadCount" : 1'
      expect_json "$report" '"activeConversionCount" : 1'
      ;;
    reverse-index-command-q)
      expect_json "$report" '"reverseIndexActive" : true'
      ;;
    translation-wait-command-q)
      expect_json "$report" '"translationWaitActive" : true'
      ;;
  esac
  print "Resource Center termination $mode: PASS"
}

run_scenario idle-command-q commandQ
run_scenario download-command-q commandQ
run_scenario conversion-command-q commandQ
run_scenario heavy-wait-command-q commandQ
run_scenario reverse-index-command-q commandQ
run_scenario translation-wait-command-q commandQ
run_scenario menu-quit menu
run_scenario system-terminate system

print "Resource Center real-process termination integration: PASS"
