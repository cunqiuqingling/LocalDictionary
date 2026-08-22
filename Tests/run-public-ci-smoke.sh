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
  Tests/run-offline-language-smoke.sh
  Tests/run-selection-direction-integration-smoke.sh
  Tests/run-community-unsigned-release-smoke.sh
  Tests/run-m24-release-structural-gates.sh
  Tests/run-m24-release-tooling-smoke.sh
  Tests/run-m24-unsigned-release-dry-run.sh
  Tests/run-resource-center-smoke.sh
  Tests/run-m23-resource-center-structural-gates.sh
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
  Tests/run-fd-bound-sqlite-vfs-prototype-smoke.sh
  Tests/run-fd-bound-mdict-source-prototype-smoke.sh
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

OFFLINE_SOURCES=(
  "$ROOT/App/OfflineTranslationModels.swift"
  "$ROOT/App/LongTextAnalysis.swift"
  "$ROOT/App/ReverseLookup.swift"
)
if /usr/bin/grep -E 'AIProvider|AIExplanationService|URLSession|ResourceCenter|https?://' \
    "${OFFLINE_SOURCES[@]}" >/dev/null; then
  print -u2 "offline translation path references a Provider or network client"
  exit 1
fi
if ! /usr/bin/grep -Fq '.translationTask(model.configuration)' \
      "$ROOT/App/SystemTranslationHost.swift" ||
   ! /usr/bin/grep -Fq 'prepareTranslation()' "$ROOT/App/SystemTranslationHost.swift" ||
   ! /usr/bin/grep -Fq 'LanguageAvailability()' "$ROOT/App/SystemTranslationHost.swift"; then
  print -u2 "system translation host is missing reviewed public API boundaries"
  exit 1
fi
if /usr/bin/grep -Eq 'NSScreenCaptureUsageDescription|CGWindowListCreateImage|ScreenCaptureKit' \
    "$ROOT/App/Info.plist" "$ROOT/App"/*.swift; then
  print -u2 "selection placement added a screen-recording boundary"
  exit 1
fi
print "Offline/provider/selection structural gates passed"

QUERY_SOURCE="$ROOT/App/ManagedDictionaryQueryModels.swift"
QUERY_RUNTIME="$ROOT/App/ManagedDictionaryQueryRuntime.swift"
INDEX_ADAPTER="$ROOT/App/DictionaryIndexBuilderAdapter.swift"
INDEX_SERVICE="$ROOT/App/DictionaryIndexingService.swift"
BRIDGE_SOURCE="$ROOT/App/DictionaryCoreBridge.mm"
CATALOG_MODEL="$ROOT/App/DictionaryCatalog.swift"
CATALOG_STORE="$ROOT/App/DictionaryCatalogStore.swift"
RECONCILIATION_SOURCE="$ROOT/App/OwnedDictionaryLifecycle.swift"
STARTUP_VERIFIER="$ROOT/App/PublishedIndexIdentityAdapter.swift"
VFS_SOURCE="$ROOT/MDictCore/FDBoundSQLiteReadOnlyVFS.cpp"
SQLITE_CORE="$ROOT/MDictCore/SQLiteDictionaryCore.cpp"
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

if ! /usr/bin/grep -q 'LocalDictionarySealManagedIndex' "$INDEX_ADAPTER" ||
   ! /usr/bin/grep -q 'LocalDictionaryPublishManagedIndex' "$INDEX_ADAPTER" ||
   ! /usr/bin/grep -q 'openManagedReadOnly' "$SQLITE_CORE" ||
   ! /usr/bin/grep -q 'FDBoundReadOnlyVFSName' "$SQLITE_CORE"; then
  print -u2 "managed candidate/query chain is not bound to the production fd VFS"
  exit 1
fi

if /usr/bin/grep -q 'sqlite3_open_v2' "$QUERY_SOURCE" "$QUERY_RUNTIME" ||
   /usr/bin/grep -q '/dev/fd' "$BRIDGE_SOURCE" "$VFS_SOURCE" "$SQLITE_CORE" ||
   /usr/bin/grep -q 'sqlite3_vfs_find' "$VFS_SOURCE"; then
  print -u2 "managed production chain contains a forbidden pathname/default-VFS fallback"
  exit 1
fi

if ! /usr/bin/grep -q 'managedReadOnlyWithRootPath' "$QUERY_RUNTIME" ||
   ! /usr/bin/grep -q 'indexPublicationID: String' "$QUERY_RUNTIME" ||
   ! /usr/bin/grep -q 'indexSHA256: String' "$QUERY_RUNTIME"; then
  print -u2 "managed runtime or cache key is missing persistent publication identity"
  exit 1
fi

if ! /usr/bin/grep -q 'static let currentSchemaVersion = 3' "$CATALOG_MODEL" ||
   ! /usr/bin/grep -q 'guard let publishedIndexIdentity' "$CATALOG_MODEL" ||
   ! /usr/bin/grep -Fq 'dictionary.\(publicationID).sqlite' "$INDEX_SERVICE"; then
  print -u2 "Catalog v3 ready identity or versioned final-name gate is missing"
  exit 1
fi

if ! /usr/bin/grep -q 'renameatx_np' "$BRIDGE_SOURCE" ||
   ! /usr/bin/grep -q 'RENAME_EXCL' "$BRIDGE_SOURCE" ||
   ! /usr/bin/grep -q 'NameStillMatches' "$BRIDGE_SOURCE"; then
  print -u2 "index publication/cleanup lacks no-replace or capability-rebind enforcement"
  exit 1
fi

MIGRATION_BODY="$(/usr/bin/awk '
  /private func migrateV2/ { capture = 1 }
  capture {
    print
    if ($0 ~ /private struct CatalogV1/) {
      exit
    }
  }
' "$CATALOG_STORE")"
if print -r -- "$MIGRATION_BODY" | /usr/bin/grep -Eq \
    'Data[(]contentsOf|FileManager|sqlite3|LocalDictionary|sourceURL|indexURL'; then
  print -u2 "Catalog v2 migration performs source/index I/O"
  exit 1
fi

if ! /usr/bin/grep -q 'isVersionedIndexEntry' "$RECONCILIATION_SOURCE" ||
   ! /usr/bin/grep -q 'publishedIndexIdentity = nil' "$RECONCILIATION_SOURCE" ||
   /usr/bin/grep -Eq 'LocalDictionaryOpenManagedSource|sourceRelativePath|payload\\.mdx' \
      "$STARTUP_VERIFIER"; then
  print -u2 "startup reconciliation promotes or reads outside the sealed index authority"
  exit 1
fi

print "Managed sealed-index structural gates passed"

if [[ "${LOCALDICTIONARY_STRUCTURAL_GATES_ONLY:-0}" == "1" ]]; then
  exit 0
fi

for relative_test in "${PUBLIC_TESTS[@]}"; do
  print "\n=== ${relative_test} ==="
  "$ROOT/$relative_test"
done

print "\n=== git diff --check ==="
git -C "$ROOT" diff --check

print "\nPublic CI smoke suite passed"
