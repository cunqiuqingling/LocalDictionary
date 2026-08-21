#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-lifecycle.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
fi
mkdir -p "$BUILD/debug-module-cache" "$BUILD/release-module-cache"
SOURCES=(
  "$ROOT/App/AppConfig.swift"
  "$ROOT/App/DictionaryCatalog.swift"
  "$ROOT/App/ResourceManifestKeyID.swift"
  "$ROOT/App/ManagedDictionaryLifecycleCoordinator.swift"
  "$ROOT/App/DictionaryCatalogStore.swift"
  "$ROOT/App/ManagedDictionaryQueryModels.swift"
  "$ROOT/Tests/ManagedDictionaryLifecycleCoordinatorSmoke.swift"
)
xcrun --sdk macosx swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
  -D MANAGED_DICTIONARY_LIFECYCLE_TESTING \
  -sanitize=address,undefined -module-cache-path "$BUILD/debug-module-cache" "${SOURCES[@]}" \
  -lsqlite3 -o "$BUILD/ManagedLifecycleDebug"
ASAN_OPTIONS=halt_on_error=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$BUILD/ManagedLifecycleDebug"
xcrun --sdk macosx swiftc -parse-as-library -O -DNDEBUG -strict-concurrency=complete -warnings-as-errors \
  -D MANAGED_DICTIONARY_LIFECYCLE_TESTING \
  -module-cache-path "$BUILD/release-module-cache" "${SOURCES[@]}" \
  -lsqlite3 -o "$BUILD/ManagedLifecycleRelease"
"$BUILD/ManagedLifecycleRelease"

# The focused coordinator binary above owns the actor, cancellation, query-service and real
# Catalog transaction coverage. These existing isolated smokes exercise the real POSIX index
# publication and PendingDeletion removal paths that the coordinator is wired into.
"$ROOT/Tests/run-dictionary-indexing-smoke.sh"
"$ROOT/Tests/run-dictionary-ordering-removal-smoke.sh"
print "Managed lifecycle/query coordination integration coverage: real-index=PASS real-removal=PASS"
