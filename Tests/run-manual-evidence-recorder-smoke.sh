#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-evidence.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/ManualEvidenceRecorder.swift" \
  "$ROOT/Tests/ManualEvidenceRecorderSmoke.swift" \
  -o "$BUILD/ManualEvidenceRecorderSmoke"

EVIDENCE_SMOKE_MODE=off "$BUILD/ManualEvidenceRecorderSmoke"
/bin/mkdir -m 700 "$BUILD/session"
EVIDENCE_SMOKE_MODE=on "$BUILD/ManualEvidenceRecorderSmoke" \
  --manual-evidence-log "$BUILD/session/evidence.jsonl"
