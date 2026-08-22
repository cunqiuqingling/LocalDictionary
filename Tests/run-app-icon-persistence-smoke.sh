#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
AUDIT="$ROOT/scripts/audit-app-icon.sh"
TMP_ROOT="$(/usr/bin/mktemp -d /private/tmp/LocalDictionary-app-icon-smoke.XXXXXX)"
trap '/bin/rm -rf "$TMP_ROOT"' EXIT

CHECKS=0
expect_success() {
    "$@" >/dev/null
    (( CHECKS += 1 ))
}
expect_failure() {
    if "$@" >/dev/null 2>&1; then
        print -u2 "Expected failure: $*"
        exit 1
    fi
    (( CHECKS += 1 ))
}

expect_success "$AUDIT"

tracked=(
    App/Assets.xcassets/Contents.json
    App/Assets.xcassets/AppIcon.appiconset/Contents.json
    App/Assets.xcassets/AppIcon.appiconset/AppIcon-16.png
    App/Assets.xcassets/AppIcon.appiconset/AppIcon-16@2x.png
    App/Assets.xcassets/AppIcon.appiconset/AppIcon-32.png
    App/Assets.xcassets/AppIcon.appiconset/AppIcon-64.png
    App/Assets.xcassets/AppIcon.appiconset/AppIcon-128.png
    App/Assets.xcassets/AppIcon.appiconset/AppIcon-128@2x.png
    App/Assets.xcassets/AppIcon.appiconset/AppIcon-256.png
    App/Assets.xcassets/AppIcon.appiconset/AppIcon-256@2x.png
    App/Assets.xcassets/AppIcon.appiconset/AppIcon-512.png
    App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
)
for path in "${tracked[@]}"; do
    expect_success /usr/bin/git -C "$ROOT" ls-files --error-unmatch "$path"
done

make_bundle() {
    local destination="$1"
    /bin/mkdir -p "$destination/Contents/Resources"
    /usr/bin/plutil -create xml1 "$destination/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$destination/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconName string AppIcon' "$destination/Contents/Info.plist"
    print -n 'compiled-assets' > "$destination/Contents/Resources/Assets.car"
    print -n 'compiled-icon' > "$destination/Contents/Resources/AppIcon.icns"
}

CLEAN_APP="$TMP_ROOT/Clean.app"
make_bundle "$CLEAN_APP"
expect_success "$AUDIT" "$CLEAN_APP"

NO_ASSETS_APP="$TMP_ROOT/NoAssets.app"
make_bundle "$NO_ASSETS_APP"
/bin/rm "$NO_ASSETS_APP/Contents/Resources/Assets.car"
expect_failure "$AUDIT" "$NO_ASSETS_APP"

WRONG_NAME_APP="$TMP_ROOT/WrongName.app"
make_bundle "$WRONG_NAME_APP"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconName OtherIcon' "$WRONG_NAME_APP/Contents/Info.plist"
expect_failure "$AUDIT" "$WRONG_NAME_APP"

FINDER_ICON_APP="$TMP_ROOT/FinderIcon.app"
make_bundle "$FINDER_ICON_APP"
print -n 'manual-icon' > "$FINDER_ICON_APP/Icon"$'\r'
expect_failure "$AUDIT" "$FINDER_ICON_APP"

print "AppIcon persistence smoke passed: ${CHECKS} checks"
