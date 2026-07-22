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
  Tests/run-managed-dictionary-query-smoke.sh
  Tests/run-generic-mdict-formatter-security-smoke.sh
  Tests/run-dictionary-ordering-removal-smoke.sh
  Tests/run-dictionary-manager-ui-state-smoke.sh
  Tests/run-dark-appearance-attributed-text-smoke.sh
  Tests/run-ai-service-smoke.sh
  Tests/run-public-obsidian-note-store-smoke.sh
)

for relative_test in "${PUBLIC_TESTS[@]}"; do
  print "\n=== ${relative_test} ==="
  "$ROOT/$relative_test"
done

print "\n=== git diff --check ==="
git -C "$ROOT" diff --check

print "\nPublic CI smoke suite passed"
