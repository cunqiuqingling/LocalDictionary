#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
ORIGINAL_HOME="$HOME"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-public-obsidian.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  elif [[ -x "$ORIGINAL_HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/swiftc" ]]; then
    export DEVELOPER_DIR="$ORIGINAL_HOME/Downloads/Xcode.app/Contents/Developer"
  else
    export DEVELOPER_DIR="$(xcode-select -p)"
  fi
fi

export HOME="$WORK/home"
export CFFIXED_USER_HOME="$HOME"
/bin/mkdir -p "$HOME" "$WORK/module-cache" "$WORK/notes"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$WORK/module-cache" \
  "$ROOT/App/QueryIntentClassifier.swift" \
  "$ROOT/App/ObsidianNoteStore.swift" \
  "$ROOT/Tests/PublicObsidianNoteStoreSmoke.swift" \
  -o "$WORK/PublicObsidianNoteStoreSmoke"

"$WORK/PublicObsidianNoteStoreSmoke" "$WORK/notes"
