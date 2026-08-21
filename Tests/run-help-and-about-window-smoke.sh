#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-help-about.XXXXXX")"
trap '/bin/rm -rf "$BUILD"' EXIT
export DEVELOPER_DIR="${DEVELOPER_DIR:-$HOME/Downloads/Xcode.app/Contents/Developer}"

xcrun --sdk macosx swiftc \
  -parse-as-library \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -module-cache-path "$BUILD/module-cache" \
  "$ROOT/App/HelpAndAboutWindowController.swift" \
  "$ROOT/Tests/HelpAndAboutWindowSmoke.swift" \
  -framework AppKit \
  -o "$BUILD/HelpAndAboutWindowSmoke"

"$BUILD/HelpAndAboutWindowSmoke"

[[ "$(/usr/bin/grep -c '使用说明与版权…' "$ROOT/App/AppDelegate.swift")" -eq 2 ]]
/usr/bin/grep -q '#selector(showHelpAndAbout)' "$ROOT/App/AppDelegate.swift"
/usr/bin/grep -q 'showHelpAndAbout()' "$ROOT/App/AppDelegate.swift"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSHumanReadableCopyright' \
  "$ROOT/App/Info.plist")" == *"liuzhentie"* ]]

EXPECTED_LEGAL="LICENSE.md
Licenses/libtomcrypt-LICENSE.txt
Licenses/mdict-cpp-LICENSE.txt
Licenses/miniz-LICENSE.txt
Privacy.md
THIRD_PARTY_NOTICES.md"
ACTUAL_LEGAL="$(/usr/bin/find "$ROOT/App/ReleaseLegal" -type f -print | \
  /usr/bin/sed "s#^$ROOT/App/ReleaseLegal/##" | /usr/bin/sort)"
[[ "$ACTUAL_LEGAL" == "$EXPECTED_LEGAL" ]]
