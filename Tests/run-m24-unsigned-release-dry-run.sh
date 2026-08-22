#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-unsigned-release.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
OUTPUT="$WORK/Output With Spaces"
LOG="$WORK/build.log"

"$ROOT/scripts/release/build-release.sh" \
    --mode unsigned-dry-run \
    --version 0.1 \
    --output "$OUTPUT" \
    --allow-dirty-dry-run | /usr/bin/tee "$LOG"

ARTIFACT="$OUTPUT/LocalDictionary-0.1-macOS-arm64-UNSIGNED-NOT-FOR-DISTRIBUTION.zip"
[[ -f "$ARTIFACT" ]]
[[ -f "$OUTPUT/SHA256SUMS" ]]
[[ -f "$OUTPUT/release-manifest.json" ]]
/usr/bin/grep -Fq "$(shasum -a 256 "$ARTIFACT" | /usr/bin/awk '{print $1}')  ${ARTIFACT:t}" \
    "$OUTPUT/SHA256SUMS"

/usr/bin/python3 - "$OUTPUT/release-manifest.json" "${ARTIFACT:t}" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
required = {
    "schemaVersion", "productName", "bundleID", "marketingVersion", "buildNumber",
    "gitCommit", "gitDirty", "xcodeVersion", "sdkVersion", "architecture",
    "deploymentTarget", "artifactFilename", "artifactSize", "artifactSHA256",
    "appBundleIdentity", "signingAuthority", "hardenedRuntime",
    "entitlementsSummary", "notarizationStatus", "notarizationSubmissionID",
    "stapleValidation", "gatekeeperAssessment", "buildTimestamp",
}
missing = sorted(required - manifest.keys())
if missing:
    raise SystemExit(f"manifest missing fields: {missing}")
if manifest["artifactFilename"] != sys.argv[2]:
    raise SystemExit("manifest artifact filename mismatch")
if manifest["signingAuthority"] != "UNSIGNED-NOT-FOR-DISTRIBUTION":
    raise SystemExit("unsigned status missing")
if manifest["notarizationStatus"] != "not-submitted":
    raise SystemExit("unsigned artifact claims notarization")
PY

EXTRACT="$WORK/Extracted Artifact With Spaces"
/bin/mkdir "$EXTRACT"
/usr/bin/ditto -x -k "$ARTIFACT" "$EXTRACT"
"$ROOT/scripts/release/verify-release.sh" \
    --mode unsigned-dry-run \
    --app "$EXTRACT/LocalDictionary.app" \
    --zip "$ARTIFACT" \
    --version 0.1

expect_verify_failure() {
    local label="$1"
    local app="$2"
    if "$ROOT/scripts/release/verify-release.sh" \
        --mode unsigned-dry-run \
        --app "$app" \
        --version 0.1 >"$WORK/$label.log" 2>&1; then
        print -u2 "release verifier unexpectedly accepted: $label"
        exit 1
    fi
}

WRONG_VERSION="$WORK/Wrong Version/LocalDictionary.app"
/bin/mkdir -p "${WRONG_VERSION:h}"
/usr/bin/ditto "$EXTRACT/LocalDictionary.app" "$WRONG_VERSION"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9' \
    "$WRONG_VERSION/Contents/Info.plist"
expect_verify_failure wrong-version "$WRONG_VERSION"

MISSING_ICON="$WORK/Missing Icon/LocalDictionary.app"
/bin/mkdir -p "${MISSING_ICON:h}"
/usr/bin/ditto "$EXTRACT/LocalDictionary.app" "$MISSING_ICON"
/bin/mv "$MISSING_ICON/Contents/Resources/AppIcon.icns" "$WORK/removed-AppIcon.icns"
expect_verify_failure missing-icon "$MISSING_ICON"

WRONG_ARCH="$WORK/Wrong Architecture/LocalDictionary.app"
/bin/mkdir -p "${WRONG_ARCH:h}"
/usr/bin/ditto "$EXTRACT/LocalDictionary.app" "$WRONG_ARCH"
/bin/cp /usr/bin/true "$WRONG_ARCH/Contents/MacOS/LocalDictionary"
expect_verify_failure wrong-architecture "$WRONG_ARCH"

UNKNOWN_LICENSE="$WORK/Unknown License/LocalDictionary.app"
/bin/mkdir -p "${UNKNOWN_LICENSE:h}"
/usr/bin/ditto "$EXTRACT/LocalDictionary.app" "$UNKNOWN_LICENSE"
print 'synthetic unaudited license' > \
    "$UNKNOWN_LICENSE/Contents/Resources/ReleaseLegal/Licenses/unknown-LICENSE.txt"
expect_verify_failure unknown-license "$UNKNOWN_LICENSE"

if /usr/bin/grep -Eq 'notarytool submit|gh release create|spctl_status=passed' "$LOG"; then
    print -u2 "unsigned dry-run log claims or invokes an external release result"
    exit 1
fi
print "M24UnsignedReleaseDryRun PASS (14/14)"
