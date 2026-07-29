#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
ORIGINAL_HOME="$HOME"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-public-ci.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$ORIGINAL_HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$ORIGINAL_HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export HOME="$WORK/home"
export CFFIXED_USER_HOME="$HOME"
export LOCALDICTIONARY_SKIP_KEYCHAIN_SMOKE=1
/bin/mkdir -p "$HOME"

PUBLIC_TESTS=(
  Tests/run-resource-manifest-security-smoke.sh
  Tests/run-resource-manifest-network-smoke.sh
  Tests/run-resource-payload-download-smoke.sh
  Tests/run-resource-payload-staging-security-smoke.sh
  Tests/run-open-resource-installation-smoke.sh
  Tests/run-owned-dictionary-lifecycle-reconciliation-smoke.sh
  Tests/run-d1b3a2a-resource-limits-smoke.sh
  Tests/run-open-source-compliance-smoke.sh
  Tests/run-third-party-vendor-smoke.sh
  Tests/run-ripemd128-miniz-smoke.sh
  Tests/run-local-configuration-isolation-smoke.sh
  Tests/run-app-bundle-audit-smoke.sh
  Tests/run-app-icon-persistence-smoke.sh
  Tests/run-dictionary-catalog-smoke.sh
  Tests/run-dictionary-import-smoke.sh
  Tests/run-dictionary-indexing-smoke.sh
  Tests/run-managed-source-indexing-production-smoke.sh
  Tests/run-managed-dictionary-query-smoke.sh
  Tests/run-managed-dictionary-lifecycle-coordination-smoke.sh
  Tests/run-generic-mdict-formatter-security-smoke.sh
  Tests/run-dictionary-ordering-removal-smoke.sh
  Tests/run-dictionary-manager-ui-state-smoke.sh
  Tests/run-dark-appearance-attributed-text-smoke.sh
  Tests/run-ai-service-smoke.sh
  Tests/run-public-obsidian-note-store-smoke.sh
)

QUERY_SOURCE="$ROOT/App/ManagedDictionaryQueryModels.swift"
FINALIZATION_TAIL="$(/usr/bin/awk '
  /let finalSnapshots = await lifecycleCoordinator.queryValidationSnapshots/ {
    sawSnapshot = 1
    next
  }
  sawSnapshot && !capture {
    if ($0 ~ /^[[:space:]]*\)[[:space:]]*$/) {
      capture = 1
    }
    next
  }
  capture {
    print
    if ($0 ~ /return finalizeBatch/) {
      sawReturn = 1
      exit
    }
  }
  END {
    if (!sawSnapshot || !sawReturn) {
      exit 1
    }
  }
' "$QUERY_SOURCE")"
if print -r -- "$FINALIZATION_TAIL" | /usr/bin/grep -Eq \
    '(^|[^[:alnum:]_])(await|Task|async[[:space:]]+let|withCheckedContinuation)([^[:alnum:]_]|$)'; then
  print -u2 "managed query performs asynchronous work after its final batch snapshot"
  exit 1
fi

RUNTIME_DEFAULTS="$(/usr/bin/awk '
  /^extension ManagedDictionaryQueryRuntime \{/ {
    capture = 1
  }
  capture {
    print
    if ($0 ~ /^}/) {
      exit
    }
  }
' "$QUERY_SOURCE")"
if print -r -- "$RUNTIME_DEFAULTS" | /usr/bin/grep -q 'generation:'; then
  print -u2 "generation-scoped runtime removal must not have a protocol default"
  exit 1
fi

print "Managed query structural gates passed"

for relative_test in "${PUBLIC_TESTS[@]}"; do
  print "\n=== ${relative_test} ==="
  "$ROOT/$relative_test"
done

print "\n=== git diff --check ==="
git -C "$ROOT" diff --check

print "\nPublic CI smoke suite passed"
