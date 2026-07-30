#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIG="$ROOT/App/ResourceCenterProductionConfiguration.swift"
CONTROLLER="$ROOT/App/ResourceCenterController.swift"
MANAGER="$ROOT/App/DictionaryManagerWindowController.swift"
IMPORTER="$ROOT/App/MDictImportInspector.swift"
FORMATTER="$ROOT/App/GenericMDictEntryFormatter.mm"
PROJECT="$ROOT/App/LocalDictionary.xcodeproj/project.pbxproj"

require_literal() {
  local file="$1"
  local literal="$2"
  /usr/bin/grep -Fq -- "$literal" "$file" || {
    print -u2 "missing structural requirement: $literal ($file)"
    exit 1
  }
}

reject_pattern() {
  local pattern="$1"
  shift
  if /usr/bin/grep -En -- "$pattern" "$@" >/dev/null; then
    print -u2 "forbidden M23 production pattern: $pattern"
    exit 1
  fi
}

require_literal "$CONFIG" "manifestEndpoint: nil"
require_literal "$CONFIG" "payloadAllowedHosts: []"
require_literal "$CONFIG" "trustedManifestKeys: []"
reject_pattern 'ProcessInfo.*environment|getenv[(]|UserDefaults.*manifest|TextField.*URL' \
  "$CONFIG" "$CONTROLLER" "$MANAGER"

require_literal "$CONTROLLER" "manifestLoader.fetchAndPrepare"
require_literal "$CONTROLLER" "payloadDownloader.download"
require_literal "$CONTROLLER" "installationCoordinator.install"
require_literal "$CONTROLLER" "indexCoordinator.start"
require_literal "$CONTROLLER" "removalCoordinator.remove"
require_literal "$CONTROLLER" "defer { finishActiveTask(taskID) }"
require_literal "$CONTROLLER" "guard activeTaskID == taskID else { return }"
reject_pattern 'URLSession|Data[(]contentsOf:.*http|http://|/dev/fd|sqlite3_open' \
  "$CONTROLLER"

require_literal "$MANAGER" "panel.canChooseDirectories = false"
require_literal "$MANAGER" "我有权在本机使用该词典文件"
require_literal "$IMPORTER" "let candidates: [DictionaryMDDCandidate] = []"
require_literal "$ROOT/App/DictionaryImportService.swift" \
  "selection.preview.mddCandidates.isEmpty"
reject_pattern 'URLSession|NWConnection|http://|https://' \
  "$ROOT/App/DictionaryImportService.swift" "$IMPORTER"

require_literal "$ROOT/App/DictionaryCatalogOrdering.swift" "DictionarySourceID.oxfordOALD8.rawValue"
require_literal "$ROOT/App/DictionaryCatalogOrdering.swift" "DictionarySourceID.affixRootA.rawValue"
reject_pattern 'legacyDefaultOrder[[:space:]]*=' "$CONTROLLER" "$MANAGER"

for element in script iframe object embed frame frameset applet img; do
  require_literal "$FORMATTER" "\"$element\""
done
require_literal "$FORMATTER" "HTML_PARSE_NONET"
require_literal "$FORMATTER" "kMaximumRawBytes"
require_literal "$ROOT/App/ResourceManifestValidator.swift" \
  "resource.dictionaryFormat == .genericMDictV1"

for source in ResourceCenterProductionConfiguration.swift ResourceCenterModels.swift \
  ResourceCenterController.swift ResourceCenterViewController.swift; do
  require_literal "$PROJECT" "$source in Sources"
done

if /usr/bin/find "$ROOT" -type f \
  \( -iname '*.mdx' -o -iname '*.mdd' -o -iname '*.sqlite' \
     -o -iname '*.sqlite-wal' -o -iname '*.sqlite-shm' \) \
  ! -path "$ROOT/.build/*" ! -path "$ROOT/.git/*" -print -quit |
  /usr/bin/grep -q .; then
  print -u2 "repository contains a dictionary or SQLite payload"
  exit 1
fi

require_literal "$ROOT/docs/resource-center.md" \
  "contain no commercial MDX/MDD"
require_literal "$ROOT/docs/resource-center-deployment.md" \
  "Never insert test keys into production trust"

print "M23 Resource Center structural gates: PASS"
