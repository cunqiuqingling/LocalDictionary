#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
AUDIT="$ROOT/scripts/audit-app-bundle.sh"
WORK="$(/usr/bin/mktemp -d /private/tmp/LocalDictionary-BundleAudit.XXXXXX)"
trap '/bin/rm -rf "$WORK"' EXIT

make_bundle() {
    local name="$1"
    local bundle="$WORK/$name.app"
    /bin/mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
    print '#!/bin/sh' > "$bundle/Contents/MacOS/LocalDictionary"
    print 'exit 0' >> "$bundle/Contents/MacOS/LocalDictionary"
    /bin/chmod +x "$bundle/Contents/MacOS/LocalDictionary"
    /usr/bin/plutil -create xml1 "$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$bundle/Contents/Info.plist"
    print -n 'synthetic-compiled-assets' > "$bundle/Contents/Resources/Assets.car"
    print -n 'synthetic-compiled-icon' > "$bundle/Contents/Resources/AppIcon.icns"
    print -r -- "$bundle"
}

expect_failure() {
    local label="$1"
    local bundle="$2"
    local forbidden_value="$3"
    local output="$WORK/output-$label.txt"
    if "$AUDIT" "$bundle" >"$output" 2>&1; then
        print -u2 "audit unexpectedly accepted: $label"
        exit 1
    fi
    if [[ -n "$forbidden_value" ]] && /usr/bin/grep -Fq -- "$forbidden_value" "$output"; then
        print -u2 "audit exposed a synthetic sensitive value: $label"
        exit 1
    fi
}

CLEAN="$(make_bundle 'Clean App With Spaces')"
BEFORE="$WORK/before.sha"
AFTER="$WORK/after.sha"
/usr/bin/find -s "$CLEAN" -type f -exec /usr/bin/shasum -a 256 {} \; > "$BEFORE"
"$AUDIT" "$CLEAN" >/dev/null
/usr/bin/find -s "$CLEAN" -type f -exec /usr/bin/shasum -a 256 {} \; > "$AFTER"
/usr/bin/cmp -s "$BEFORE" "$AFTER" || {
    print -u2 "audit modified the inspected bundle"
    exit 1
}

LOCAL="$(make_bundle local-config-risk)"
print '{}' > "$LOCAL/Contents/Resources/local.json"
expect_failure local "$LOCAL" ""

MDX="$(make_bundle mdx-risk)"
print 'synthetic' > "$MDX/Contents/Resources/sample.mdx"
expect_failure mdx "$MDX" ""

MDD="$(make_bundle mdd-risk)"
print 'synthetic' > "$MDD/Contents/Resources/sample.mdd"
expect_failure mdd "$MDD" ""

SQLITE="$(make_bundle sqlite-risk)"
print 'synthetic' > "$SQLITE/Contents/Resources/dictionary.sqlite"
expect_failure sqlite "$SQLITE" ""

CATALOG="$(make_bundle catalog-risk)"
print '{}' > "$CATALOG/Contents/Resources/catalog-v1.json"
expect_failure catalog "$CATALOG" ""

PENDING="$(make_bundle pending-risk)"
/bin/mkdir -p "$PENDING/Contents/Resources/PendingDeletion"
print '{}' > "$PENDING/Contents/Resources/PendingDeletion/record.json"
expect_failure pending "$PENDING" ""

PRIVATE_PATH="/Users/test-user/SyntheticAuditOnly/private-file"
PATH_RISK="$(make_bundle path-risk)"
print -r -- "$PRIVATE_PATH" > "$PATH_RISK/Contents/Resources/value.txt"
expect_failure path "$PATH_RISK" "$PRIVATE_PATH"

TEMP_PATH="/private/tmp/LocalDictionary-SyntheticAuditOnly/output"
TEMP_PATH_RISK="$(make_bundle temp-path-risk)"
print -r -- "$TEMP_PATH" > "$TEMP_PATH_RISK/Contents/Resources/value.txt"
expect_failure temp-path "$TEMP_PATH_RISK" "$TEMP_PATH"

AUTH_VALUE="Authorization: Bearer SYNTHETIC_AUDIT_ONLY_NOT_A_KEY"
AUTH_RISK="$(make_bundle authorization-risk)"
print -r -- "$AUTH_VALUE" > "$AUTH_RISK/Contents/Resources/value.txt"
expect_failure authorization "$AUTH_RISK" "$AUTH_VALUE"

API_VALUE="api_key=SYNTHETIC_AUDIT_ONLY_NOT_A_REAL_SECRET"
API_RISK="$(make_bundle api-key-risk)"
print -r -- "$API_VALUE" > "$API_RISK/Contents/Resources/value.txt"
expect_failure api-key "$API_RISK" "$API_VALUE"

SYMLINK_RISK="$(make_bundle symlink-risk)"
/bin/ln -s "$WORK/non-bundle-target" "$SYMLINK_RISK/Contents/Resources/external-data"
expect_failure symlink "$SYMLINK_RISK" ""

SIGNING_WORK_RISK="$(make_bundle manifest-signing-work-risk)"
/bin/mkdir -p "$SIGNING_WORK_RISK/Contents/Resources/manifest-signing"
print 'synthetic' > "$SIGNING_WORK_RISK/Contents/Resources/manifest-signing/notes.txt"
expect_failure manifest-signing "$SIGNING_WORK_RISK" ""

PRIVATE_KEY_MARKER="-----BEGIN PRIVATE KEY-----"
PRIVATE_KEY_RISK="$(make_bundle private-key-risk)"
print -r -- "$PRIVATE_KEY_MARKER" > "$PRIVATE_KEY_RISK/Contents/Resources/synthetic.txt"
expect_failure private-key "$PRIVATE_KEY_RISK" "$PRIVATE_KEY_MARKER"

TEST_KEY_RISK="$(make_bundle test-trust-key-risk)"
print 'synthetic public material' > "$TEST_KEY_RISK/Contents/Resources/test-manifest-trust-key.txt"
expect_failure test-key "$TEST_KEY_RISK" ""

DERIVED_DATA_RISK="$(make_bundle derived-data-risk)"
/bin/mkdir -p "$DERIVED_DATA_RISK/Contents/Resources/DerivedData"
print 'synthetic object' > "$DERIVED_DATA_RISK/Contents/Resources/DerivedData/file.o"
expect_failure derived-data "$DERIVED_DATA_RISK" ""

FAKE_PROJECT="$WORK/Fake Project With Spaces"
/bin/mkdir -p "$FAKE_PROJECT/scripts" "$FAKE_PROJECT/config"
/usr/bin/ditto "$ROOT/scripts/install-private-local-config.sh" \
    "$FAKE_PROJECT/scripts/install-private-local-config.sh"
/bin/chmod +x "$FAKE_PROJECT/scripts/install-private-local-config.sh"
SYNTHETIC_CONFIG_VALUE="SYNTHETIC_PRIVATE_CONFIGURATION_CONTENT"
print -r -- "$SYNTHETIC_CONFIG_VALUE" > "$FAKE_PROJECT/config/local.json"
INSTALL_HOME="$WORK/install home"
/bin/mkdir -p "$INSTALL_HOME"
INSTALL_OUTPUT="$WORK/install-output.txt"
HOME="$INSTALL_HOME" CFFIXED_USER_HOME="$INSTALL_HOME" \
    "$FAKE_PROJECT/scripts/install-private-local-config.sh" >"$INSTALL_OUTPUT" 2>&1
TARGET="$INSTALL_HOME/Library/Application Support/LocalDictionary/LegacyConfig/local.json"
[[ -f "$TARGET" ]] || { print -u2 "private config installer did not create its target"; exit 1; }
[[ "$(/usr/bin/stat -f '%Lp' "$TARGET")" == "600" ]] || {
    print -u2 "private config target permissions are not 600"
    exit 1
}
if HOME="$INSTALL_HOME" CFFIXED_USER_HOME="$INSTALL_HOME" \
    "$FAKE_PROJECT/scripts/install-private-local-config.sh" >>"$INSTALL_OUTPUT" 2>&1; then
    print -u2 "private config installer overwrote without confirmation"
    exit 1
fi
if /usr/bin/grep -Fq "$SYNTHETIC_CONFIG_VALUE" "$INSTALL_OUTPUT" || \
   /usr/bin/grep -Fq "$TARGET" "$INSTALL_OUTPUT"; then
    print -u2 "private config installer exposed private content or its target path"
    exit 1
fi

PROJECT_FILE="$ROOT/App/LocalDictionary.xcodeproj/project.pbxproj"
! /usr/bin/grep -q 'Copy optional local configuration\|../config/local.json' "$PROJECT_FILE"
/usr/bin/grep -q 'Audit App Bundle' "$PROJECT_FILE"
/usr/bin/grep -q 'audit-app-bundle.sh' "$ROOT/scripts/install-local-app.sh"

print "AppBundleAuditSmoke PASS (19/19)"
