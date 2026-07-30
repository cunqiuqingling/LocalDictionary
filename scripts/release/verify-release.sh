#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/release-common.sh"

MODE=""
APP=""
ZIP=""
VERSION=""
while (( "$#" )); do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        --app) APP="${2:-}"; shift 2 ;;
        --zip) ZIP="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        *) release_die "unknown argument: $1" ;;
    esac
done
[[ "$MODE" == "unsigned-dry-run" || "$MODE" == "developer-id" || "$MODE" == "notarized" ]] ||
    release_die "--mode must be unsigned-dry-run, developer-id, or notarized"
[[ -d "$APP" && "${APP:t}" == "$RELEASE_PRODUCT.app" ]] ||
    release_die "--app must identify LocalDictionary.app"
[[ -n "$VERSION" ]] || release_die "--version is required"

"$RELEASE_ROOT/scripts/audit-app-bundle.sh" "$APP"

INFO="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/$RELEASE_PRODUCT"
[[ -f "$INFO" && -x "$EXECUTABLE" ]] || release_die "bundle metadata or executable is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "$RELEASE_BUNDLE_ID" ]] ||
    release_die "bundle identifier mismatch"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" == "$VERSION" ]] ||
    release_die "bundle version mismatch"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$INFO")" == "true" ]] ||
    release_die "LSUIElement changed"
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || release_die "AppIcon.icns is missing"

ARCHS="$(/usr/bin/lipo -archs "$EXECUTABLE")"
[[ "$ARCHS" == "$RELEASE_ARCHITECTURE" ]] ||
    release_die "executable architectures must be exactly $RELEASE_ARCHITECTURE (found: $ARCHS)"
DETECTED_MINOS="$(/usr/bin/vtool -show-build "$EXECUTABLE" |
    /usr/bin/awk '/minos/ { print $2; exit }')"
[[ "$DETECTED_MINOS" == "$RELEASE_DEPLOYMENT_TARGET" ]] ||
    release_die "minimum macOS mismatch: $DETECTED_MINOS"

MACHO_LIST=()
while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
        MACHO_LIST+=("$candidate")
    fi
done < <(/usr/bin/find "$APP" -type f -print0)
(( ${#MACHO_LIST[@]} == 1 )) ||
    release_die "unexpected nested Mach-O code count: ${#MACHO_LIST[@]}"
[[ "${MACHO_LIST[1]}" == "$EXECUTABLE" ]] ||
    release_die "unexpected Mach-O code: ${MACHO_LIST[1]}"

cmp -s "$RELEASE_ROOT/LICENSE" "$APP/Contents/Resources/ReleaseLegal/LICENSE.md" ||
    release_die "bundled LICENSE differs from repository authority"
cmp -s "$RELEASE_ROOT/THIRD_PARTY_NOTICES.md" \
    "$APP/Contents/Resources/ReleaseLegal/THIRD_PARTY_NOTICES.md" ||
    release_die "bundled third-party notice differs"
cmp -s "$RELEASE_ROOT/docs/privacy.md" "$APP/Contents/Resources/ReleaseLegal/Privacy.md" ||
    release_die "bundled privacy notice differs"
cmp -s "$RELEASE_ROOT/ThirdParty/vendor/mdict-cpp/LICENSE" \
    "$APP/Contents/Resources/ReleaseLegal/Licenses/mdict-cpp-LICENSE.txt" ||
    release_die "bundled mdict-cpp license differs"
cmp -s "$RELEASE_ROOT/ThirdParty/vendor/miniz/LICENSE" \
    "$APP/Contents/Resources/ReleaseLegal/Licenses/miniz-LICENSE.txt" ||
    release_die "bundled miniz license differs"
/usr/bin/diff -u \
    <(/usr/bin/sed 's/[[:space:]]*$//' \
        "$RELEASE_ROOT/ThirdParty/vendor/libtomcrypt-ripemd128/LICENSE") \
    "$APP/Contents/Resources/ReleaseLegal/Licenses/libtomcrypt-LICENSE.txt" >/dev/null ||
    release_die "bundled libtomcrypt license differs beyond documented trailing-whitespace normalization"
EXPECTED_LEGAL_FILES="$(
    print -l \
        "LICENSE.md" \
        "Licenses/libtomcrypt-LICENSE.txt" \
        "Licenses/mdict-cpp-LICENSE.txt" \
        "Licenses/miniz-LICENSE.txt" \
        "Privacy.md" \
        "THIRD_PARTY_NOTICES.md"
)"
ACTUAL_LEGAL_FILES="$(
    /usr/bin/find "$APP/Contents/Resources/ReleaseLegal" -type f -print |
        /usr/bin/sed "s#^$APP/Contents/Resources/ReleaseLegal/##" |
        /usr/bin/sort
)"
[[ "$ACTUAL_LEGAL_FILES" == "$EXPECTED_LEGAL_FILES" ]] ||
    release_die "ReleaseLegal contains a missing or unaudited file"

if /usr/bin/find "$APP" -type f |
    /usr/bin/grep -Eiq '\.(mdx|mdd|sqlite|sqlite3|p12|p8|key|cer|mobileprovision|o|swiftmodule|map)$|/local\.json$|/DerivedData/|/Tests?/' ; then
    release_die "bundle contains a forbidden release file"
fi

if [[ "$MODE" == "unsigned-dry-run" ]]; then
    if /usr/bin/codesign -dv "$APP" >/dev/null 2>&1; then
        SIGNATURE_DETAILS="$(/usr/bin/codesign -dv --verbose=4 "$APP" 2>&1)"
        [[ "$SIGNATURE_DETAILS" == *"Signature=adhoc"* ]] ||
            release_die "unsigned dry-run contains a non-ad-hoc signature"
        [[ "$SIGNATURE_DETAILS" != *"Authority="* ]] ||
            release_die "unsigned dry-run contains a signing authority"
        print "signature_status=linker_adhoc_UNSIGNED-NOT-FOR-DISTRIBUTION"
    else
        print "signature_status=unsigned_not_for_distribution"
    fi
    print "spctl_status=not_run_for_unsigned_artifact"
else
    /usr/bin/codesign --verify --deep --strict --verbose=4 "$APP"
    SIGNATURE_DETAILS="$(/usr/bin/codesign -d --verbose=4 "$APP" 2>&1)"
    print -r -- "$SIGNATURE_DETAILS"
    [[ "$SIGNATURE_DETAILS" == *"Authority=Developer ID Application:"* ]] ||
        release_die "signed app lacks a Developer ID Application authority"
    [[ "$SIGNATURE_DETAILS" == *"flags="*"runtime"* ]] ||
        release_die "signed app lacks hardened runtime"
    [[ "$SIGNATURE_DETAILS" == *"Timestamp="* &&
       "$SIGNATURE_DETAILS" != *"Timestamp=none"* ]] ||
        release_die "signed app lacks a secure timestamp"
    ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "$APP" 2>/dev/null)"
    [[ "$ENTITLEMENTS" != *"get-task-allow"* ]] ||
        release_die "signed app contains get-task-allow"
    NORMALIZED_ENTITLEMENTS="$(print -r -- "$ENTITLEMENTS" |
        /usr/bin/plutil -convert json -o - -- -)"
    [[ "$NORMALIZED_ENTITLEMENTS" == "{}" ]] ||
        release_die "signed app entitlements differ from the empty Release allowlist"
    if [[ "$MODE" == "notarized" ]]; then
        /usr/bin/xcrun stapler validate "$APP"
        /usr/sbin/spctl --assess --type execute --verbose=4 "$APP"
    fi
fi

if [[ -n "$ZIP" ]]; then
    [[ -f "$ZIP" ]] || release_die "ZIP does not exist: $ZIP"
    ZIP_LIST="$(/usr/bin/zipinfo -1 "$ZIP")"
    [[ -n "$ZIP_LIST" ]] || release_die "ZIP is empty"
    if print -r -- "$ZIP_LIST" |
        /usr/bin/awk -F/ '
            NF && $1 != "LocalDictionary.app" { bad = 1 }
            END { exit bad ? 0 : 1 }
        '; then
        release_die "ZIP contains content outside LocalDictionary.app"
    fi
fi

print "bundle_audit=passed"
print "nested_macho_count=${#MACHO_LIST[@]}"
print "architecture=$ARCHS"
print "deployment_target=$DETECTED_MINOS"
print "verification_mode=$MODE"
