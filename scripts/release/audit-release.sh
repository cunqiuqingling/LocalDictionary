#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-common.sh"

[[ "$#" -eq 0 ]] || release_die "audit-release.sh accepts no arguments"
release_require_xcode

WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-release-audit.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT
SETTINGS="$WORK/build-settings.txt"
release_build_settings "$WORK/DerivedData" >"$SETTINGS"

expect_setting() {
    local key="$1"
    local expected="$2"
    local actual
    actual="$(release_setting "$SETTINGS" "$key")"
    [[ "$actual" == "$expected" ]] ||
        release_die "$key expected '$expected', found '${actual:-<unset>}'"
}

expect_setting PRODUCT_NAME "$RELEASE_PRODUCT"
expect_setting PRODUCT_BUNDLE_IDENTIFIER "$RELEASE_BUNDLE_ID"
expect_setting MACOSX_DEPLOYMENT_TARGET "$RELEASE_DEPLOYMENT_TARGET"
expect_setting ENABLE_HARDENED_RUNTIME "YES"
expect_setting ENABLE_APP_SANDBOX "NO"
expect_setting CODE_SIGN_ENTITLEMENTS "LocalDictionaryRelease.entitlements"
expect_setting INFOPLIST_FILE "Info.plist"
expect_setting SUPPORTED_PLATFORMS "macosx"

[[ "$(release_setting "$SETTINGS" ARCHS)" == *"$RELEASE_ARCHITECTURE"* ]] ||
    release_die "Release ARCHS does not contain $RELEASE_ARCHITECTURE"
[[ "$(release_setting "$SETTINGS" GCC_PREPROCESSOR_DEFINITIONS)" == *"NDEBUG=1"* ]] ||
    release_die "Release does not define NDEBUG=1"
MARKETING_VERSION="$(release_setting "$SETTINGS" MARKETING_VERSION)"
BUILD_NUMBER="$(release_setting "$SETTINGS" CURRENT_PROJECT_VERSION)"
release_require_version "$MARKETING_VERSION" "$MARKETING_VERSION"
release_require_build_number "$BUILD_NUMBER"

/usr/bin/plutil -lint "$RELEASE_ROOT/App/Info.plist" \
    "$RELEASE_ROOT/App/LocalDictionaryRelease.entitlements" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RELEASE_ROOT/App/Info.plist")" == '$(MARKETING_VERSION)' ]] ||
    release_die "Info.plist marketing version is not project-substituted"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$RELEASE_ROOT/App/Info.plist")" == '$(CURRENT_PROJECT_VERSION)' ]] ||
    release_die "Info.plist build number is not project-substituted"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$RELEASE_ROOT/App/Info.plist")" == "true" ]] ||
    release_die "LSUIElement must remain true"

[[ "$(/usr/bin/plutil -convert json -o - "$RELEASE_ROOT/App/LocalDictionaryRelease.entitlements")" == "{}" ]] ||
    release_die "Release entitlements must remain an empty dictionary"
if /usr/libexec/PlistBuddy -c 'Print' "$RELEASE_ROOT/App/LocalDictionaryRelease.entitlements" |
    /usr/bin/grep -Eq 'get-task-allow|allow-jit|allow-unsigned-executable-memory|disable-library-validation|network.server|app-sandbox'; then
    release_die "Release entitlements contain an unapproved exception"
fi

cmp -s "$RELEASE_ROOT/LICENSE" "$RELEASE_ROOT/App/ReleaseLegal/LICENSE.md" ||
    release_die "bundled root license copy differs"
cmp -s "$RELEASE_ROOT/THIRD_PARTY_NOTICES.md" "$RELEASE_ROOT/App/ReleaseLegal/THIRD_PARTY_NOTICES.md" ||
    release_die "bundled third-party notice differs"
cmp -s "$RELEASE_ROOT/docs/privacy.md" "$RELEASE_ROOT/App/ReleaseLegal/Privacy.md" ||
    release_die "bundled privacy notice differs"
cmp -s "$RELEASE_ROOT/ThirdParty/vendor/mdict-cpp/LICENSE" \
    "$RELEASE_ROOT/App/ReleaseLegal/Licenses/mdict-cpp-LICENSE.txt" ||
    release_die "bundled mdict-cpp license differs"
cmp -s "$RELEASE_ROOT/ThirdParty/vendor/miniz/LICENSE" \
    "$RELEASE_ROOT/App/ReleaseLegal/Licenses/miniz-LICENSE.txt" ||
    release_die "bundled miniz license differs"
/usr/bin/diff -u \
    <(/usr/bin/sed 's/[[:space:]]*$//' \
        "$RELEASE_ROOT/ThirdParty/vendor/libtomcrypt-ripemd128/LICENSE") \
    "$RELEASE_ROOT/App/ReleaseLegal/Licenses/libtomcrypt-LICENSE.txt" >/dev/null ||
    release_die "bundled libtomcrypt license differs beyond documented trailing-whitespace normalization"

/usr/bin/grep -Fq 'static let productionDefault: ResourceManifestEndpoint? = nil' \
    "$RELEASE_ROOT/App/ResourceNetworkModels.swift" ||
    release_die "Resource Center production endpoint is not empty"
/usr/bin/grep -Fq 'static let productionAllowedHosts: [String] = []' \
    "$RELEASE_ROOT/App/ResourcePayloadDownloadModels.swift" ||
    release_die "Resource Center production host allowlist is not empty"
/usr/bin/grep -Fq 'static let productionDefault = TrustedManifestKeyStore(keysByID: [:])' \
    "$RELEASE_ROOT/App/ResourceManifestSignature.swift" ||
    release_die "Resource Center production trust store is not empty"
[[ -d "$RELEASE_ROOT/App/Assets.xcassets/AppIcon.appiconset" ]] ||
    release_die "tracked AppIcon.appiconset is missing"

DEVELOPER_ID_COUNT="$(/usr/bin/security find-identity -v -p codesigning |
    /usr/bin/awk '/"Developer ID Application:/ { count += 1 } END { print count + 0 }')"

print "mode=audit"
print "scheme=$RELEASE_SCHEME"
print "bundle_id=$RELEASE_BUNDLE_ID"
print "version=$MARKETING_VERSION"
print "build=$BUILD_NUMBER"
print "architecture=$RELEASE_ARCHITECTURE"
print "deployment_target=$RELEASE_DEPLOYMENT_TARGET"
print "hardened_runtime=enabled_for_release"
print "app_sandbox=disabled_unchanged"
print "entitlements=empty_minimum"
print "developer_id_application_identity_count=$DEVELOPER_ID_COUNT"
print "notary_profile_readiness=requires_explicit_user_supplied_profile_name"
print "external_credentials=not_read"
print "audit_status=passed"
