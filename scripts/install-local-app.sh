#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
PROJECT_PATH="$PROJECT_ROOT/App/LocalDictionary.xcodeproj"
DERIVED_DATA="$PROJECT_ROOT/.build/xcode-install"
SOURCE_APP="$DERIVED_DATA/Build/Products/Release/LocalDictionary.app"
INSTALL_DIRECTORY="$HOME/Applications"
INSTALL_APP="$INSTALL_DIRECTORY/LocalDictionary.app"
TEMP_APP="$INSTALL_DIRECTORY/.LocalDictionary.app.new.$$"
BACKUP_APP="$INSTALL_DIRECTORY/.LocalDictionary.app.backup.$$"
EXPECTED_BUNDLE_IDENTIFIER="com.localdict.LocalDictionary"

if [[ -n "${DEVELOPER_DIR:-}" && -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
    :
elif [[ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
elif [[ -x "$HOME/Downloads/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$HOME/Downloads/Xcode.app/Contents/Developer"
else
    SELECTED_DEVELOPER_DIR="$(xcode-select -p)"
    if [[ -x "$SELECTED_DEVELOPER_DIR/usr/bin/xcodebuild" ]]; then
        export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"
    else
        print -u2 "未找到完整 Xcode。"
        exit 1
    fi
fi

cleanup() {
    [[ ! -e "$TEMP_APP" ]] || /bin/rm -rf "$TEMP_APP"
}
trap cleanup EXIT

/usr/bin/xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme LocalDictionary \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

[[ -d "$SOURCE_APP" ]] || { print -u2 "Release App 不存在：$SOURCE_APP"; exit 1; }
[[ -x "$SOURCE_APP/Contents/MacOS/LocalDictionary" ]] || { print -u2 "Release App 缺少可执行文件。"; exit 1; }

SOURCE_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")"
[[ "$SOURCE_BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || {
    print -u2 "Bundle identifier 不匹配：$SOURCE_BUNDLE_IDENTIFIER"
    exit 1
}

/bin/mkdir -p "$INSTALL_DIRECTORY"
/usr/bin/ditto "$SOURCE_APP" "$TEMP_APP"

[[ -d "$TEMP_APP" ]] || { print -u2 "临时 App 复制失败。"; exit 1; }
[[ -x "$TEMP_APP/Contents/MacOS/LocalDictionary" ]] || { print -u2 "临时 App 不完整。"; exit 1; }
TEMP_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TEMP_APP/Contents/Info.plist")"
[[ "$TEMP_BUNDLE_IDENTIFIER" == "$EXPECTED_BUNDLE_IDENTIFIER" ]] || {
    print -u2 "临时 App 的 Bundle identifier 不匹配。"
    exit 1
}

/usr/bin/pkill -x LocalDictionary 2>/dev/null || true

if [[ -e "$INSTALL_APP" ]]; then
    /bin/mv "$INSTALL_APP" "$BACKUP_APP"
fi

if ! /bin/mv "$TEMP_APP" "$INSTALL_APP"; then
    if [[ -e "$BACKUP_APP" ]]; then
        /bin/mv "$BACKUP_APP" "$INSTALL_APP"
    fi
    print -u2 "安装失败，已保留原版本。"
    exit 1
fi

if [[ -e "$BACKUP_APP" ]]; then
    /bin/rm -rf "$BACKUP_APP"
fi

trap - EXIT
print "$INSTALL_APP"
