#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h:h}"
if (( $# != 1 && $# != 3 )); then
  print -u2 "usage: $0 /absolute/path/to/LocalDictionary.app [candidate-dir tool-dir]"
  exit 2
fi
SOURCE_APP="$1"
if (( $# == 3 )); then
  CANDIDATE_DIR="$2"
  TOOL_DIR="$3"
else
  CANDIDATE_DIR="/Users/liuzhentie/Desktop/LocalDictionary-Evidence-Acceptance"
  TOOL_DIR="/Users/liuzhentie/Desktop/LocalDictionary-Manual-Evidence-Tool"
fi
[[ "$CANDIDATE_DIR" == /Users/liuzhentie/Desktop/LocalDictionary-* &&
   "$TOOL_DIR" == /Users/liuzhentie/Desktop/LocalDictionary-* ]] || {
  print -u2 "Destinations must be explicit LocalDictionary directories on Desktop."
  exit 2
}

[[ "$SOURCE_APP" == /* && -d "$SOURCE_APP" &&
   -x "$SOURCE_APP/Contents/MacOS/LocalDictionary" ]] || {
  print -u2 "A valid absolute LocalDictionary.app path is required."
  exit 2
}
for destination in "$CANDIDATE_DIR" "$TOOL_DIR"; do
  [[ ! -e "$destination" ]] || {
    print -u2 "Refusing to overwrite existing destination: $destination"
    exit 3
  }
done

"$ROOT/scripts/audit-app-bundle.sh" "$SOURCE_APP"

STAGING_ROOT="$(/usr/bin/mktemp -d /private/tmp/LocalDictionary-evidence-package.XXXXXX)"
trap '/bin/rm -rf "$STAGING_ROOT"' EXIT
STAGED_CANDIDATE="$STAGING_ROOT/LocalDictionary-Evidence-Acceptance"
STAGED_TOOL="$STAGING_ROOT/LocalDictionary-Manual-Evidence-Tool"
/bin/mkdir -m 700 "$STAGED_CANDIDATE" "$STAGED_TOOL"
/usr/bin/ditto "$SOURCE_APP" "$STAGED_CANDIDATE/LocalDictionary.app"

for item in Start-Evidence-Test.command Collect-Evidence.command \
  Analyze-Evidence.command analyze-evidence.py; do
  /bin/cp "$ROOT/scripts/manual-evidence/$item" "$STAGED_CANDIDATE/$item"
  /bin/cp "$ROOT/scripts/manual-evidence/$item" "$STAGED_TOOL/$item"
done
/bin/cp "$ROOT/scripts/manual-evidence/EVIDENCE-TEST-INSTRUCTIONS.md" \
  "$STAGED_CANDIDATE/EVIDENCE-TEST-INSTRUCTIONS.md"
/bin/cp "$ROOT/scripts/manual-evidence/EVIDENCE-TEST-INSTRUCTIONS.md" \
  "$STAGED_TOOL/EVIDENCE-TEST-INSTRUCTIONS.md"
/bin/cp "$ROOT/scripts/manual-evidence/README.md" "$STAGED_TOOL/README.md"
print -r -- "$CANDIDATE_DIR" > "$STAGED_CANDIDATE/CANDIDATE-PATH.txt"
print -r -- "$CANDIDATE_DIR" > "$STAGED_TOOL/CANDIDATE-PATH.txt"
/bin/chmod 755 "$STAGED_CANDIDATE"/*.command "$STAGED_CANDIDATE/analyze-evidence.py"
/bin/chmod 755 "$STAGED_TOOL"/*.command "$STAGED_TOOL/analyze-evidence.py"

INFO_PLIST="$STAGED_CANDIDATE/LocalDictionary.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
EXECUTABLE="$STAGED_CANDIDATE/LocalDictionary.app/Contents/MacOS/LocalDictionary"
EXECUTABLE_SHA="$(/usr/bin/shasum -a 256 "$EXECUTABLE" | /usr/bin/awk '{print $1}')"
{
  print -r -- "MANUAL-TEST-ONLY"
  print -r -- "UNSIGNED"
  print -r -- "NOT-FOR-GITHUB-RELEASE"
  print -r -- "version=$VERSION"
  print -r -- "build=$BUILD"
  print -r -- "bundleID=$BUNDLE_ID"
  print -r -- "architecture=arm64"
  print -r -- "minimumMacOS=15.0"
  print -r -- "executableSHA256=$EXECUTABLE_SHA"
  print -r -- "gitHEAD=$(git -C "$ROOT" rev-parse HEAD)"
  print -r -- "builtAt=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$STAGED_CANDIDATE/BUILD-INFO.txt"
{
  print -r -- "MANUAL-TEST-ONLY"
  print -r -- "UNSIGNED"
  print -r -- "NOT-FOR-GITHUB-RELEASE"
} > "$STAGED_CANDIDATE/CANDIDATE-LABELS.txt"

(
  cd "$STAGED_CANDIDATE"
  /usr/bin/shasum -a 256 \
    LocalDictionary.app/Contents/MacOS/LocalDictionary \
    Start-Evidence-Test.command Collect-Evidence.command Analyze-Evidence.command \
    analyze-evidence.py EVIDENCE-TEST-INSTRUCTIONS.md BUILD-INFO.txt \
    CANDIDATE-LABELS.txt CANDIDATE-PATH.txt > SHA256SUMS
)

/bin/mv "$STAGED_TOOL" "$TOOL_DIR"
/bin/mv "$STAGED_CANDIDATE" "$CANDIDATE_DIR"
print "candidate=$CANDIDATE_DIR"
print "tool=$TOOL_DIR"
print "executable_sha256=$EXECUTABLE_SHA"
