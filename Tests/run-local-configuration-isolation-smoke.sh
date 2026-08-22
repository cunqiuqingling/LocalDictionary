#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$(/usr/bin/mktemp -d /private/tmp/LocalDictionary-ConfigIsolation.XXXXXX)"
trap '/bin/rm -rf "$WORK"' EXIT

ORIGINAL_HOME="$HOME"
export HOME="$WORK/home"
export CFFIXED_USER_HOME="$HOME"
/bin/mkdir -p "$HOME" "$WORK/module-cache"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    elif [[ -x "$ORIGINAL_HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$ORIGINAL_HOME/Downloads/Xcode.app/Contents/Developer"
    else
        export DEVELOPER_DIR="$(xcode-select -p)"
    fi
fi

xcrun --sdk macosx swiftc \
    -parse-as-library \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -module-cache-path "$WORK/module-cache" \
    "$ROOT/App/AppConfig.swift" \
    "$ROOT/App/DictionaryCatalog.swift" \
    "$ROOT/App/ResourceManifestKeyID.swift" \
    "$ROOT/App/LegacyDictionaryConfigAdapter.swift" \
    "$ROOT/Tests/LocalConfigurationIsolationSmoke.swift" \
    -lsqlite3 \
    -o "$WORK/LocalConfigurationIsolationSmoke"

"$WORK/LocalConfigurationIsolationSmoke"

if /usr/bin/grep -q 'Bundle\.main.*local\|url(forResource:.*local' "$ROOT/App/AppConfig.swift"; then
    print -u2 "production loader still references a bundled local.json"
    exit 1
fi

print "Local configuration source-boundary check PASS"
