#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
RELEASE="$ROOT/scripts/release"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-community-release.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
ARTIFACT="$WORK/LocalDictionary-0.1-macOS-arm64-unsigned.zip"
CHECKSUMS="$WORK/SHA256SUMS"
MANIFEST="$WORK/release-manifest.json"
OUTPUT="$WORK/Prepared"

print 'synthetic community artifact' >"$ARTIFACT"
SHA="$(/usr/bin/shasum -a 256 "$ARTIFACT" | /usr/bin/awk '{print $1}')"
SIZE="$(/usr/bin/stat -f '%z' "$ARTIFACT")"
print "$SHA  ${ARTIFACT:t}" >"$CHECKSUMS"
/usr/bin/python3 - "$MANIFEST" "$SHA" "$SIZE" <<'PY'
import json
import sys
with open(sys.argv[1], "x", encoding="utf-8") as handle:
    json.dump({
        "schemaVersion": 1,
        "marketingVersion": "0.1",
        "artifactFilename": "LocalDictionary-0.1-macOS-arm64-unsigned.zip",
        "artifactSHA256": sys.argv[2],
        "artifactSize": int(sys.argv[3]),
        "gitDirty": False,
        "signing": "ad-hoc",
        "signingAuthority": "authority-free-ad-hoc",
        "hardenedRuntime": "enabled-ad-hoc",
        "notarization": "not-submitted",
        "notarizationStatus": "not-submitted",
        "stapled": False,
        "gatekeeperDirectOpen": "not-guaranteed",
        "distributionChannel": "github-community-unsigned",
    }, handle)
PY

"$RELEASE/prepare-github-release.sh" \
    --mode community-unsigned \
    --version 0.1 \
    --artifact "$ARTIFACT" \
    --checksums "$CHECKSUMS" \
    --manifest "$MANIFEST" \
    --output "$OUTPUT" \
    --repository synthetic/project

[[ -f "$OUTPUT/draft-release-command.txt" && -f "$OUTPUT/release-notes.md" ]]
/usr/bin/grep -Fq 'LocalDictionary-0.1-macOS-arm64-unsigned.zip' \
    "$OUTPUT/draft-release-command.txt"
/usr/bin/grep -Fq 'Human-approved draft creation command' \
    "$OUTPUT/draft-release-command.txt"

if /usr/bin/grep -Eq 'notarytool[[:space:]]+submit|codesign[[:space:]].*Developer ID' \
    "$RELEASE/build-release.sh"; then
    # These commands are valid only inside the developer-id branch. Verify the community branch
    # is the CODE_SIGNING_ALLOWED=NO archive branch and has the canonical distinct filename.
    /usr/bin/grep -Fq 'community-unsigned' "$RELEASE/build-release.sh"
    /usr/bin/grep -Fq 'CODE_SIGNING_ALLOWED=NO' "$RELEASE/build-release.sh"
fi
/usr/bin/grep -Fq 'github-community-unsigned' "$RELEASE/build-release.sh"
/usr/bin/grep -Fq 'UNSIGNED-NOT-FOR-DISTRIBUTION.zip' "$RELEASE/build-release.sh"
/usr/bin/grep -Fq 'codesign --force --sign -' "$RELEASE/build-release.sh"
/usr/bin/grep -Fq 'codesign --verify --deep --strict' "$RELEASE/verify-release.sh"
/usr/bin/grep -Fq -- '--norsrc' "$RELEASE/build-release.sh"

print "CommunityUnsignedReleaseSmoke PASS"
