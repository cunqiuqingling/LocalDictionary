#!/bin/zsh
set -euo pipefail
umask 077

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
SOURCE_CONFIG="$PROJECT_ROOT/config/local.json"
TARGET_DIRECTORY="$HOME/Library/Application Support/LocalDictionary/LegacyConfig"
TARGET_CONFIG="$TARGET_DIRECTORY/local.json"
TEMP_CONFIG="$TARGET_DIRECTORY/.local.json.installing.$$"
FORCE=0

if [[ "$#" -gt 1 || ( "$#" -eq 1 && "$1" != "--force" ) ]]; then
    print -u2 "用法：install-private-local-config.sh [--force]"
    exit 2
fi
[[ "$#" -eq 1 ]] && FORCE=1

if [[ ! -f "$SOURCE_CONFIG" || ! -r "$SOURCE_CONFIG" ]]; then
    print -u2 "未找到可读取的私有 local.json，请先在 config 目录准备该文件。"
    exit 1
fi

if [[ -e "$TARGET_CONFIG" && "$FORCE" -ne 1 ]]; then
    if [[ -t 0 && -t 1 ]]; then
        read -r "reply?私有配置已存在。确认覆盖？[y/N] "
        case "${reply:l}" in
            y|yes) ;;
            *) print -u2 "未覆盖现有私有配置。"; exit 1 ;;
        esac
    else
        print -u2 "私有配置已存在，默认不覆盖；确认后可使用 --force。"
        exit 1
    fi
fi

cleanup() {
    [[ ! -e "$TEMP_CONFIG" ]] || /bin/rm -f "$TEMP_CONFIG"
}
trap cleanup EXIT

/bin/mkdir -p "$TARGET_DIRECTORY"
/bin/chmod 700 "$TARGET_DIRECTORY"
/usr/bin/ditto "$SOURCE_CONFIG" "$TEMP_CONFIG"
/bin/chmod 600 "$TEMP_CONFIG"
/bin/mv -f "$TEMP_CONFIG" "$TARGET_CONFIG"

[[ -f "$TARGET_CONFIG" ]] || {
    print -u2 "私有配置安装失败。"
    exit 1
}

trap - EXIT
print "私有配置已安装。"
