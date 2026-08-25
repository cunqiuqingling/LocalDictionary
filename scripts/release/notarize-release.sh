#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-common.sh"

APP=""
SUBMISSION_ZIP=""
OUTPUT=""
VERSION=""
PROFILE=""
EXPECTED_HEAD=""
SUBMIT=0
while (( "$#" )); do
    case "$1" in
        --app) APP="${2:-}"; shift 2 ;;
        --submission-zip) SUBMISSION_ZIP="${2:-}"; shift 2 ;;
        --output) OUTPUT="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --keychain-profile) PROFILE="${2:-}"; shift 2 ;;
        --expected-head) EXPECTED_HEAD="${2:-}"; shift 2 ;;
        --submit-notarization) SUBMIT=1; shift ;;
        *) release_die "unknown argument: $1" ;;
    esac
done

[[ "$SUBMIT" -eq 1 ]] ||
    release_die "network submission is locked; explicit --submit-notarization is required"
[[ -n "$PROFILE" ]] || release_die "--keychain-profile is required"
[[ -d "$APP" && -f "$SUBMISSION_ZIP" ]] ||
    release_die "signed app and submission ZIP must exist"
[[ "${SUBMISSION_ZIP:t}" != *"UNSIGNED-NOT-FOR-DISTRIBUTION"* ]] ||
    release_die "unsigned dry-run artifacts cannot be notarized"
release_require_new_output "$OUTPUT"
release_require_xcode
release_require_clean_head "$EXPECTED_HEAD"

WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-notary.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
EXTRACTED="$WORK/SubmissionExtract"
/bin/mkdir "$EXTRACTED"
/usr/bin/ditto -x -k "$SUBMISSION_ZIP" "$EXTRACTED"
[[ -d "$EXTRACTED/$RELEASE_PRODUCT.app" ]] ||
    release_die "submission ZIP does not contain LocalDictionary.app"
"$SCRIPT_DIR/verify-release.sh" \
    --mode developer-id \
    --app "$EXTRACTED/$RELEASE_PRODUCT.app" \
    --zip "$SUBMISSION_ZIP" \
    --version "$VERSION"
if ! /usr/bin/diff -qr "$APP" "$EXTRACTED/$RELEASE_PRODUCT.app" >/dev/null; then
    release_die "submission ZIP app differs from --app"
fi

RESULT="$WORK/notary-result.json"
if ! /usr/bin/xcrun notarytool submit "$SUBMISSION_ZIP" \
        --keychain-profile "$PROFILE" \
        --wait \
        --output-format json >"$RESULT"; then
    release_die "notarytool submission failed before an accepted result"
fi
STATUS="$(/usr/bin/plutil -extract status raw "$RESULT")"
SUBMISSION_ID="$(/usr/bin/plutil -extract id raw "$RESULT")"
CLASS="$(release_notary_state_class "$STATUS")"
if [[ "$CLASS" != "accepted" ]]; then
    LOG="$WORK/notary-log.json"
    /usr/bin/xcrun notarytool log "$SUBMISSION_ID" \
        --keychain-profile "$PROFILE" "$LOG" || true
    if [[ -f "$LOG" ]]; then
        DIAGNOSTIC="${OUTPUT}.notary-log-sanitized.json"
        [[ ! -e "$DIAGNOSTIC" ]] ||
            release_die "refusing to overwrite existing sanitized notary log: $DIAGNOSTIC"
        /usr/bin/sed -E \
            -e 's/[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}/[redacted-email]/g' \
            -e 's#/Users/[^/\"[:space:]]+#/Users/[redacted]#g' \
            "$LOG" >"$DIAGNOSTIC"
    fi
    release_die "notarization was not accepted (state: $STATUS)"
fi

PUBLISH_DIR="$WORK/Publish"
/bin/mkdir "$PUBLISH_DIR"
/usr/bin/ditto "$APP" "$PUBLISH_DIR/$RELEASE_PRODUCT.app"
/usr/bin/xcrun stapler staple "$PUBLISH_DIR/$RELEASE_PRODUCT.app"
/usr/bin/xcrun stapler validate "$PUBLISH_DIR/$RELEASE_PRODUCT.app"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$PUBLISH_DIR/$RELEASE_PRODUCT.app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$PUBLISH_DIR/$RELEASE_PRODUCT.app"

FINAL_NAME="$RELEASE_PRODUCT-$VERSION-macOS-$RELEASE_ARCHITECTURE.zip"
(cd "$PUBLISH_DIR" && /usr/bin/ditto -c -k --norsrc --keepParent \
    "$RELEASE_PRODUCT.app" "$FINAL_NAME")
"$SCRIPT_DIR/verify-release.sh" \
    --mode notarized \
    --app "$PUBLISH_DIR/$RELEASE_PRODUCT.app" \
    --zip "$PUBLISH_DIR/$FINAL_NAME" \
    --version "$VERSION"
SHA="$(release_sha256 "$PUBLISH_DIR/$FINAL_NAME")"
SIZE="$(release_file_size "$PUBLISH_DIR/$FINAL_NAME")"
SETTINGS="$WORK/build-settings.txt"
release_build_settings "$WORK/SettingsDerivedData" >"$SETTINGS"
BUILD_NUMBER="$(release_setting "$SETTINGS" CURRENT_PROJECT_VERSION)"
release_require_version "$VERSION" "$(release_setting "$SETTINGS" MARKETING_VERSION)"
release_require_build_number "$BUILD_NUMBER"
SIGNING_AUTHORITY="$(/usr/bin/codesign -dv --verbose=4 "$PUBLISH_DIR/$RELEASE_PRODUCT.app" 2>&1 |
    /usr/bin/awk -F= '/^Authority=/ { print $2; exit }')"
[[ -n "$SIGNING_AUTHORITY" ]] || release_die "unable to record signing authority"
DESIGNATED_REQUIREMENT="$(/usr/bin/codesign -d -r- "$PUBLISH_DIR/$RELEASE_PRODUCT.app" 2>&1 |
    /usr/bin/sed -n 's/^designated => //p')"
[[ -n "$DESIGNATED_REQUIREMENT" ]] || release_die "unable to record designated requirement"
GIT_HEAD="$(git -C "$RELEASE_ROOT" rev-parse HEAD)"
XCODE_VERSION="$("$DEVELOPER_DIR/usr/bin/xcodebuild" -version | /usr/bin/paste -sd ' ' -)"
SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"
TIMESTAMP="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
release_write_manifest "$PUBLISH_DIR/release-manifest.json" \
    productName "$RELEASE_PRODUCT" \
    bundleID "$RELEASE_BUNDLE_ID" \
    marketingVersion "$VERSION" \
    buildNumber "$BUILD_NUMBER" \
    gitCommit "$GIT_HEAD" \
    gitDirty false \
    xcodeVersion "$XCODE_VERSION" \
    sdkVersion "$SDK_VERSION" \
    architecture "$RELEASE_ARCHITECTURE" \
    deploymentTarget "$RELEASE_DEPLOYMENT_TARGET" \
    artifactFilename "$FINAL_NAME" \
    artifactSize "$SIZE" \
    artifactSHA256 "$SHA" \
    appBundleIdentity "$DESIGNATED_REQUIREMENT" \
    signingAuthority "$SIGNING_AUTHORITY" \
    hardenedRuntime enabled \
    entitlementsSummary empty-minimum \
    notarizationStatus Accepted \
    notarizationSubmissionID "$SUBMISSION_ID" \
    stapleValidation passed \
    gatekeeperAssessment passed \
    buildTimestamp "$TIMESTAMP"
print "$SHA  $FINAL_NAME" >"$PUBLISH_DIR/SHA256SUMS"
/bin/mv "$PUBLISH_DIR" "$OUTPUT"
print "notarization_status=Accepted"
print "submission_id=$SUBMISSION_ID"
print "artifact=$OUTPUT/$FINAL_NAME"
print "sha256=$SHA"
