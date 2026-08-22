#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-common.sh"

VERSION=""
MODE="notarized"
ARTIFACT=""
CHECKSUMS=""
MANIFEST=""
OUTPUT=""
REPOSITORY=""
while (( "$#" )); do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --artifact) ARTIFACT="${2:-}"; shift 2 ;;
        --checksums) CHECKSUMS="${2:-}"; shift 2 ;;
        --manifest) MANIFEST="${2:-}"; shift 2 ;;
        --output) OUTPUT="${2:-}"; shift 2 ;;
        --repository) REPOSITORY="${2:-}"; shift 2 ;;
        *) release_die "unknown argument: $1" ;;
    esac
done
[[ "$MODE" == "notarized" || "$MODE" == "community-unsigned" ]] ||
    release_die "--mode must be notarized or community-unsigned"
[[ -f "$ARTIFACT" && -f "$CHECKSUMS" && -f "$MANIFEST" ]] ||
    release_die "artifact, checksums, and manifest must exist"
if [[ "$MODE" == "community-unsigned" ]]; then
    EXPECTED_NAME="$RELEASE_PRODUCT-$VERSION-macOS-$RELEASE_ARCHITECTURE-unsigned.zip"
else
    EXPECTED_NAME="$RELEASE_PRODUCT-$VERSION-macOS-$RELEASE_ARCHITECTURE.zip"
fi
[[ "${ARTIFACT:t}" == "$EXPECTED_NAME" ]] ||
    release_die "artifact is not the canonical $MODE filename"
[[ "${ARTIFACT:t}" != *"UNSIGNED-NOT-FOR-DISTRIBUTION"* ]] ||
    release_die "unsigned artifacts cannot enter GitHub release preparation"
[[ "$REPOSITORY" =~ '^[[:alnum:]_.-]+/[[:alnum:]_.-]+$' ]] ||
    release_die "--repository must be owner/name"
release_require_new_output "$OUTPUT"

/usr/bin/grep -Fq "$(release_sha256 "$ARTIFACT")  ${ARTIFACT:t}" "$CHECKSUMS" ||
    release_die "SHA256SUMS does not match artifact"
/usr/bin/python3 - "$MANIFEST" "$VERSION" "${ARTIFACT:t}" "$MODE" \
    "$(release_sha256 "$ARTIFACT")" "$(release_file_size "$ARTIFACT")" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
if manifest.get("marketingVersion") != sys.argv[2]:
    raise SystemExit("manifest version mismatch")
if manifest.get("artifactFilename") != sys.argv[3]:
    raise SystemExit("manifest artifact mismatch")
mode = sys.argv[4]
if manifest.get("artifactSHA256") != sys.argv[5]:
    raise SystemExit("manifest SHA-256 mismatch")
if manifest.get("artifactSize") != int(sys.argv[6]):
    raise SystemExit("manifest artifact size mismatch")
if manifest.get("gitDirty") is not False:
    raise SystemExit("formal manifest must record gitDirty=false")
if mode == "community-unsigned":
    expected = {
        "signing": "unsigned",
        "notarization": "not-submitted",
        "stapled": False,
        "gatekeeperDirectOpen": "not-guaranteed",
        "distributionChannel": "github-community-unsigned",
    }
    for key, value in expected.items():
        if manifest.get(key) != value:
            raise SystemExit(f"community manifest mismatch: {key}")
    if manifest.get("signingAuthority") != "unsigned":
        raise SystemExit("community manifest claims a signing authority")
else:
    if manifest.get("notarizationStatus") != "Accepted":
        raise SystemExit("formal manifest must record Accepted notarization")
    if not manifest.get("notarizationSubmissionID"):
        raise SystemExit("formal manifest lacks a real submission ID")
    if manifest.get("stapleValidation") != "passed":
        raise SystemExit("formal manifest lacks staple validation")
    if manifest.get("gatekeeperAssessment") != "passed":
        raise SystemExit("formal manifest lacks Gatekeeper validation")
    if manifest.get("hardenedRuntime") != "enabled":
        raise SystemExit("formal manifest lacks Hardened Runtime validation")
    if not str(manifest.get("signingAuthority", "")).startswith("Developer ID Application:"):
        raise SystemExit("formal manifest lacks Developer ID authority")
PY

WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-github-preparation.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
PUBLISH_DIR="$WORK/Publish"
/bin/mkdir "$PUBLISH_DIR"
/usr/bin/sed "s/<VERSION>/$VERSION/g" \
    "$RELEASE_ROOT/docs/release-notes-template.md" >"$PUBLISH_DIR/release-notes.md"
{
    print "# Human-approved draft creation command"
    print "# Review every file and run only after explicit authorization."
    print "gh release create \"v$VERSION\" \\"
    print "  \"$ARTIFACT\" \"$CHECKSUMS\" \"$MANIFEST\" \\"
    print "  --repo \"$REPOSITORY\" --draft --verify-tag \\"
    print "  --title \"LocalDictionary $VERSION\" --notes-file \"$OUTPUT/release-notes.md\""
} >"$PUBLISH_DIR/draft-release-command.txt"
/bin/mv "$PUBLISH_DIR" "$OUTPUT"
print "github_network_access=not_performed"
print "draft_command=$OUTPUT/draft-release-command.txt"
print "release_notes=$OUTPUT/release-notes.md"
