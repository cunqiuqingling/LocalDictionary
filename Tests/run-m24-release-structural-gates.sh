#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/App/LocalDictionary.xcodeproj/project.pbxproj"
INFO="$ROOT/App/Info.plist"
ENTITLEMENTS="$ROOT/App/LocalDictionaryRelease.entitlements"
ASSERTIONS=0

require_text() {
    local pattern="$1"
    local file="$2"
    /usr/bin/grep -Eq "$pattern" "$file" || {
        print -u2 "missing required release structure: $pattern ($file)"
        exit 1
    }
    (( ASSERTIONS += 1 ))
}

forbid_text() {
    local pattern="$1"
    shift
    if /usr/bin/grep -R -E "$pattern" "$@" >/dev/null; then
        print -u2 "forbidden release structure matched: $pattern"
        exit 1
    fi
    (( ASSERTIONS += 1 ))
}

require_fixed() {
    local text="$1"
    local file="$2"
    /usr/bin/grep -Fq -- "$text" "$file" || {
        print -u2 "missing required release structure: $text ($file)"
        exit 1
    }
    (( ASSERTIONS += 1 ))
}

require_text 'CODE_SIGN_ENTITLEMENTS = LocalDictionaryRelease.entitlements;' "$PROJECT"
require_text 'ENABLE_HARDENED_RUNTIME = YES;' "$PROJECT"
require_text 'ENABLE_HARDENED_RUNTIME = NO;' "$PROJECT"
require_text 'ARCHS = arm64;' "$PROJECT"
require_text 'MACOSX_DEPLOYMENT_TARGET = 15.0;' "$PROJECT"
require_text 'MARKETING_VERSION = 0.1;' "$PROJECT"
require_text 'CURRENT_PROJECT_VERSION = 1;' "$PROJECT"
require_fixed '<string>$(MARKETING_VERSION)</string>' "$INFO"
require_fixed '<string>$(CURRENT_PROJECT_VERSION)</string>' "$INFO"
require_text '<key>LSUIElement</key>' "$INFO"

/usr/bin/plutil -lint "$INFO" "$ENTITLEMENTS" >/dev/null
(( ASSERTIONS += 1 ))
[[ "$(/usr/bin/plutil -convert json -o - "$ENTITLEMENTS")" == "{}" ]] || {
    print -u2 "Release entitlements must be an empty dictionary"
    exit 1
}
(( ASSERTIONS += 1 ))

forbid_text 'get-task-allow|allow-jit|allow-unsigned-executable-memory|disable-library-validation|com\\.apple\\.security\\.app-sandbox' \
    "$ENTITLEMENTS"
forbid_text '(^|[^[:alnum:]])altool([^[:alnum:]]|$)' "$ROOT/scripts/release"
forbid_text '^[[:space:]]*gh[[:space:]]+release[[:space:]]+create' \
    "$ROOT/scripts/release/prepare-github-release.sh"
require_fixed '--submit-notarization' "$ROOT/scripts/release/notarize-release.sh"
require_text 'CODE_SIGNING_ALLOWED=NO' "$ROOT/scripts/release/build-release.sh"
require_text 'UNSIGNED-NOT-FOR-DISTRIBUTION' "$ROOT/scripts/release/build-release.sh"
require_text 'community-unsigned' "$ROOT/scripts/release/build-release.sh"
require_text 'macOS-\$RELEASE_ARCHITECTURE-unsigned.zip' \
    "$ROOT/scripts/release/build-release.sh"
require_text 'github-community-unsigned' "$ROOT/scripts/release/build-release.sh"
require_fixed 'codesign --force --sign - --timestamp=none --options runtime' \
    "$ROOT/scripts/release/build-release.sh"
require_fixed 'codesign --verify --deep --strict' \
    "$ROOT/scripts/release/verify-release.sh"
require_fixed 'Contents/_CodeSignature/CodeResources' \
    "$ROOT/scripts/release/verify-release.sh"
require_fixed '--norsrc' "$ROOT/scripts/release/build-release.sh"
require_text 'plutil -insert method -string developer-id' "$ROOT/scripts/release/build-release.sh"
require_text 'OTHER_CODE_SIGN_FLAGS="--timestamp"' "$ROOT/scripts/release/build-release.sh"
require_text 'codesign --verify --deep --strict' "$ROOT/scripts/release/notarize-release.sh"
require_text 'notarytool submit' "$ROOT/scripts/release/notarize-release.sh"
require_text 'stapler staple' "$ROOT/scripts/release/notarize-release.sh"
require_text 'spctl --assess --type execute' "$ROOT/scripts/release/notarize-release.sh"
require_fixed '$RELEASE_PRODUCT-$VERSION-macOS-$RELEASE_ARCHITECTURE.zip' \
    "$ROOT/scripts/release/notarize-release.sh"

require_text 'productionDefault: ResourceManifestEndpoint\? = nil' \
    "$ROOT/App/ResourceNetworkModels.swift"
require_text 'productionAllowedHosts: \[String\] = \[\]' \
    "$ROOT/App/ResourcePayloadDownloadModels.swift"
require_text 'productionDefault = TrustedManifestKeyStore\(keysByID: \[:\]\)' \
    "$ROOT/App/ResourceManifestSignature.swift"

cmp -s "$ROOT/LICENSE" "$ROOT/App/ReleaseLegal/LICENSE.md"
(( ASSERTIONS += 1 ))
cmp -s "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/App/ReleaseLegal/THIRD_PARTY_NOTICES.md"
(( ASSERTIONS += 1 ))
cmp -s "$ROOT/docs/privacy.md" "$ROOT/App/ReleaseLegal/Privacy.md"
(( ASSERTIONS += 1 ))
cmp -s "$ROOT/ThirdParty/vendor/mdict-cpp/LICENSE" \
    "$ROOT/App/ReleaseLegal/Licenses/mdict-cpp-LICENSE.txt"
(( ASSERTIONS += 1 ))
cmp -s "$ROOT/ThirdParty/vendor/miniz/LICENSE" \
    "$ROOT/App/ReleaseLegal/Licenses/miniz-LICENSE.txt"
(( ASSERTIONS += 1 ))
/usr/bin/diff -u \
    <(/usr/bin/sed 's/[[:space:]]*$//' \
        "$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128/LICENSE") \
    "$ROOT/App/ReleaseLegal/Licenses/libtomcrypt-LICENSE.txt" >/dev/null
(( ASSERTIONS += 1 ))

forbidden_payloads="$(
    /usr/bin/find "$ROOT" \
        -path "$ROOT/.git" -prune -o \
        -type f \( -iname '*.mdx' -o -iname '*.mdd' -o -iname '*.p12' -o -iname '*.p8' \) \
        -print
)"
[[ -z "$forbidden_payloads" ]] || {
    print -u2 "forbidden commercial/private/release credential payload exists"
    exit 1
}
(( ASSERTIONS += 1 ))

print "M24ReleaseStructuralGates PASS ($ASSERTIONS/$ASSERTIONS)"
