#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-common.sh"

MODE=""
VERSION=""
OUTPUT=""
EXPECTED_HEAD=""
IDENTITY=""
TEAM_ID=""
ALLOW_DIRTY_DRY_RUN=0
while (( "$#" )); do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --output) OUTPUT="${2:-}"; shift 2 ;;
        --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
        --identity) IDENTITY="${2:-}"; shift 2 ;;
        --team-id) TEAM_ID="${2:-}"; shift 2 ;;
        --allow-dirty-dry-run) ALLOW_DIRTY_DRY_RUN=1; shift ;;
        *) release_die "unknown argument: $1" ;;
    esac
done
[[ "$MODE" == "unsigned-dry-run" || "$MODE" == "developer-id" ]] ||
    release_die "--mode must be unsigned-dry-run or developer-id"
release_require_new_output "$OUTPUT"
release_require_xcode

if [[ "$MODE" == "developer-id" ]]; then
    release_require_clean_head "$EXPECTED_HEAD"
    [[ "$ALLOW_DIRTY_DRY_RUN" -eq 0 ]] || release_die "dirty override is invalid for developer-id"
    [[ "$IDENTITY" == "Developer ID Application:"* ]] ||
        release_die "--identity must name a Developer ID Application identity"
    [[ "$TEAM_ID" =~ '^[A-Z0-9]{10}$' ]] ||
        release_die "--team-id must be a 10-character Apple Team ID"
    IDENTITY_MATCHES="$(/usr/bin/security find-identity -v -p codesigning |
        /usr/bin/awk -v identity="\"$IDENTITY\"" '
            index($0, identity) { count += 1 }
            END { print count + 0 }
        ')"
    [[ "$IDENTITY_MATCHES" == "1" ]] ||
        release_die "Developer ID identity must resolve exactly once (matches: $IDENTITY_MATCHES)"
elif [[ -n "$(git -C "$RELEASE_ROOT" status --porcelain)" && "$ALLOW_DIRTY_DRY_RUN" -ne 1 ]]; then
    release_die "dirty unsigned dry-run requires --allow-dirty-dry-run"
fi

WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-release-build.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
SETTINGS="$WORK/build-settings.txt"
release_build_settings "$WORK/SettingsDerivedData" >"$SETTINGS"
PROJECT_VERSION="$(release_setting "$SETTINGS" MARKETING_VERSION)"
BUILD_NUMBER="$(release_setting "$SETTINGS" CURRENT_PROJECT_VERSION)"
release_require_version "$VERSION" "$PROJECT_VERSION"
release_require_build_number "$BUILD_NUMBER"
[[ "$(release_setting "$SETTINGS" PRODUCT_BUNDLE_IDENTIFIER)" == "$RELEASE_BUNDLE_ID" ]] ||
    release_die "project bundle identifier changed"

if [[ "$MODE" == "unsigned-dry-run" ]]; then
    ARCHIVE="$WORK/LocalDictionary-UNSIGNED.xcarchive"
    "$DEVELOPER_DIR/usr/bin/xcodebuild" \
        -project "$RELEASE_PROJECT" \
        -scheme "$RELEASE_SCHEME" \
        -configuration "$RELEASE_CONFIGURATION" \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$WORK/DerivedData" \
        -archivePath "$ARCHIVE" \
        CODE_SIGNING_ALLOWED=NO \
        archive
    APP="$ARCHIVE/Products/Applications/$RELEASE_PRODUCT.app"
    ARTIFACT_NAME="$RELEASE_PRODUCT-$VERSION-macOS-$RELEASE_ARCHITECTURE-UNSIGNED-NOT-FOR-DISTRIBUTION.zip"
    SIGNING_AUTHORITY="UNSIGNED-NOT-FOR-DISTRIBUTION"
    NOTARY_STATUS="not-submitted"
    STAPLE_STATUS="not-applicable"
    GATEKEEPER_STATUS="not-run"
    HARDENED_STATUS="configured-not-signature-asserted"
else
    ARCHIVE="$WORK/LocalDictionary.xcarchive"
    "$DEVELOPER_DIR/usr/bin/xcodebuild" \
        -project "$RELEASE_PROJECT" \
        -scheme "$RELEASE_SCHEME" \
        -configuration "$RELEASE_CONFIGURATION" \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$WORK/DerivedData" \
        -archivePath "$ARCHIVE" \
        DEVELOPMENT_TEAM="$TEAM_ID" \
        CODE_SIGN_IDENTITY="$IDENTITY" \
        OTHER_CODE_SIGN_FLAGS="--timestamp" \
        archive
    EXPORT_OPTIONS="$WORK/ExportOptions.plist"
    /usr/bin/plutil -create xml1 "$EXPORT_OPTIONS"
    /usr/bin/plutil -insert method -string developer-id "$EXPORT_OPTIONS"
    /usr/bin/plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"
    /usr/bin/plutil -insert signingCertificate -string "$IDENTITY" "$EXPORT_OPTIONS"
    /usr/bin/plutil -insert teamID -string "$TEAM_ID" "$EXPORT_OPTIONS"
    /usr/bin/plutil -lint "$EXPORT_OPTIONS" >/dev/null
    "$DEVELOPER_DIR/usr/bin/xcodebuild" \
        -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportPath "$WORK/Export" \
        -exportOptionsPlist "$EXPORT_OPTIONS"
    APP="$WORK/Export/$RELEASE_PRODUCT.app"
    ARTIFACT_NAME="$RELEASE_PRODUCT-$VERSION-macOS-$RELEASE_ARCHITECTURE-NOTARIZATION-SUBMISSION.zip"
    SIGNING_AUTHORITY="$IDENTITY"
    NOTARY_STATUS="not-submitted"
    STAPLE_STATUS="not-stapled"
    GATEKEEPER_STATUS="pending-notarization"
    HARDENED_STATUS="enabled-and-verified"
fi

[[ -d "$APP" ]] || release_die "archive/export did not produce LocalDictionary.app"
PUBLISH_DIR="$WORK/Publish"
/bin/mkdir "$PUBLISH_DIR"
/usr/bin/ditto "$APP" "$PUBLISH_DIR/$RELEASE_PRODUCT.app"
"$SCRIPT_DIR/verify-release.sh" \
    --mode "$MODE" \
    --app "$PUBLISH_DIR/$RELEASE_PRODUCT.app" \
    --version "$VERSION"

ARTIFACT="$PUBLISH_DIR/$ARTIFACT_NAME"
(cd "$PUBLISH_DIR" && /usr/bin/ditto -c -k --keepParent "$RELEASE_PRODUCT.app" "$ARTIFACT")
"$SCRIPT_DIR/verify-release.sh" \
    --mode "$MODE" \
    --app "$PUBLISH_DIR/$RELEASE_PRODUCT.app" \
    --zip "$ARTIFACT" \
    --version "$VERSION"

SHA="$(release_sha256 "$ARTIFACT")"
SIZE="$(release_file_size "$ARTIFACT")"
if [[ "$MODE" == "developer-id" ]]; then
    APP_IDENTITY="$(/usr/bin/codesign -d -r- "$PUBLISH_DIR/$RELEASE_PRODUCT.app" 2>&1 |
        /usr/bin/sed -n 's/^designated => //p')"
    [[ -n "$APP_IDENTITY" ]] || release_die "unable to record designated requirement"
else
    APP_IDENTITY="single-app-artifact-sha256:$SHA"
fi
GIT_HEAD="$(git -C "$RELEASE_ROOT" rev-parse HEAD)"
[[ -z "$(git -C "$RELEASE_ROOT" status --porcelain)" ]] && GIT_DIRTY=false || GIT_DIRTY=true
XCODE_VERSION="$("$DEVELOPER_DIR/usr/bin/xcodebuild" -version | /usr/bin/paste -sd ' ' -)"
SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
TIMESTAMP="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
MANIFEST="$PUBLISH_DIR/release-manifest.json"
release_write_manifest "$MANIFEST" \
    productName "$RELEASE_PRODUCT" \
    bundleID "$RELEASE_BUNDLE_ID" \
    marketingVersion "$VERSION" \
    buildNumber "$BUILD_NUMBER" \
    gitCommit "$GIT_HEAD" \
    gitDirty "$GIT_DIRTY" \
    xcodeVersion "$XCODE_VERSION" \
    sdkVersion "$SDK_VERSION" \
    architecture "$RELEASE_ARCHITECTURE" \
    deploymentTarget "$RELEASE_DEPLOYMENT_TARGET" \
    artifactFilename "$ARTIFACT_NAME" \
    artifactSize "$SIZE" \
    artifactSHA256 "$SHA" \
    appBundleIdentity "$APP_IDENTITY" \
    signingAuthority "$SIGNING_AUTHORITY" \
    hardenedRuntime "$HARDENED_STATUS" \
    entitlementsSummary "empty-minimum" \
    notarizationStatus "$NOTARY_STATUS" \
    notarizationSubmissionID "" \
    stapleValidation "$STAPLE_STATUS" \
    gatekeeperAssessment "$GATEKEEPER_STATUS" \
    buildTimestamp "$TIMESTAMP"
print "$SHA  $ARTIFACT_NAME" >"$PUBLISH_DIR/SHA256SUMS"

/bin/mv "$PUBLISH_DIR" "$OUTPUT"
ARTIFACT="$OUTPUT/$ARTIFACT_NAME"
MANIFEST="$OUTPUT/release-manifest.json"

print "mode=$MODE"
print "status=$([[ "$MODE" == unsigned-dry-run ]] && print UNSIGNED-NOT-FOR-DISTRIBUTION || print developer-id-signed-not-notarized)"
print "artifact=$ARTIFACT"
print "sha256=$SHA"
print "manifest=$MANIFEST"
print "checksums=$OUTPUT/SHA256SUMS"
