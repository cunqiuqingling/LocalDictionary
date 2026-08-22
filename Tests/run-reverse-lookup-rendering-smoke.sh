#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-reverse-rendering.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
/bin/mkdir -p "$BUILD/module-cache"

/usr/bin/xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/ReverseLookup.swift" \
  "$ROOT/Tests/ReverseLookupRenderingSmoke.swift" \
  -framework AppKit \
  -lsqlite3 \
  -o "$BUILD/ReverseLookupRenderingSmoke"

"$BUILD/ReverseLookupRenderingSmoke"
