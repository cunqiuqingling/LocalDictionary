#!/bin/zsh
set -euo pipefail

if [[ "$#" -ne 1 || ! -d "$1" ]]; then
    print -u2 "用法：audit-app-bundle.sh <App Bundle>"
    exit 2
fi

BUNDLE="${1:A}"
RISK_COUNT=0
ICON_AUDIT="${0:A:h}/audit-app-icon.sh"

if [[ ! -x "$ICON_AUDIT" ]]; then
    print -u2 "App Bundle 审计失败：缺少 App 图标审计脚本。"
    exit 1
fi

report_risk() {
    local risk="$1"
    local relative_path="$2"
    print -u2 -- "风险：${risk} [${relative_path}]"
    (( RISK_COUNT += 1 ))
}

is_allowed_markdown() {
    local lower_name="${1:l}"
    # Only conventional, project-supplied notices may be bundled. User notes are never allowed.
    [[ "$lower_name" == "readme.md" ||
       "$lower_name" == "license.md" ||
       "$lower_name" == "third_party_notices.md" ]]
}

scan_printable_strings() {
    local file="$1"
    local relative_path="$2"
    local risk="$3"
    local pattern="$4"

    if /usr/bin/strings -a "$file" 2>/dev/null | \
        /usr/bin/awk -v pattern="$pattern" '
            $0 ~ pattern { found = 1 }
            END { exit(found ? 0 : 1) }
        '; then
        report_risk "$risk" "$relative_path"
    fi
}

while IFS= read -r -d '' item; do
    relative_path="${item#$BUNDLE/}"
    [[ "$item" == "$BUNDLE" ]] && relative_path="."
    lower_path="${relative_path:l}"
    name="${item:t}"
    lower_name="${name:l}"

    if [[ "$lower_path" == *"pendingdeletion"* ]]; then
        report_risk "待删除运行数据" "$relative_path"
    fi
    if [[ "$lower_path" == *"application support/localdictionary"* ]]; then
        report_risk "Application Support 运行数据" "$relative_path"
    fi
    if [[ "$lower_path" == *"manifest-signing"* ||
          "$lower_path" == *"signing-private"* ]]; then
        report_risk "资源清单签名工作目录" "$relative_path"
    fi

    if [[ -L "$item" ]]; then
        report_risk "符号链接内容" "$relative_path"
        continue
    fi
    [[ -f "$item" ]] || continue

    case "$lower_name" in
        local.json|local.plist|private-config.json|legacy-config.json)
            report_risk "本机私有配置" "$relative_path"
            ;;
        *.mdx)
            report_risk "MDX 词典文件" "$relative_path"
            ;;
        *.mdd)
            report_risk "MDD 资源文件" "$relative_path"
            ;;
        *.eudic)
            report_risk "EUDIC 词典文件" "$relative_path"
            ;;
        *.sqlite|*.sqlite3|*.sqlite.building|*.sqlite-wal|*.sqlite-shm|dictionary.sqlite*|*dictionary*index*.db|*ai*cache*.db)
            report_risk "SQLite 或运行缓存" "$relative_path"
            ;;
        catalog-v*.json|catalog-v*.backup.json|*dictionary-catalog*.json)
            report_risk "Catalog 运行数据" "$relative_path"
            ;;
        *.pem|*.p8|*.p12|*.key)
            report_risk "私钥或签名密钥文件" "$relative_path"
            ;;
        *.md)
            if ! is_allowed_markdown "$name"; then
                report_risk "用户 Markdown 笔记" "$relative_path"
            fi
            ;;
    esac

    scan_printable_strings "$item" "$relative_path" "用户目录绝对路径" \
        '/Users/[^/[:space:]]+/'
    scan_printable_strings "$item" "$relative_path" "用户目录 file URL" \
        'file:///Users/'
    scan_printable_strings "$item" "$relative_path" "Authorization Bearer 内容" \
        '[Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]+[^[:space:]]+'
    scan_printable_strings "$item" "$relative_path" "疑似 API Key 值" \
        "([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Xx]-?[Aa][Pp][Ii]-?[Kk][Ee][Yy]|[Kk]eychain[_-]?[Vv]alue)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9_.-]{20,}"
    scan_printable_strings "$item" "$relative_path" "疑似服务密钥" \
        '(sk-[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{20,})'
    scan_printable_strings "$item" "$relative_path" "正式私钥格式" \
        '-----BEGIN ([A-Z0-9]+ )?PRIVATE KEY-----|OPENSSH PRIVATE KEY'
done < <(/usr/bin/find "$BUNDLE" -print0)

if (( RISK_COUNT > 0 )); then
    print -u2 "App Bundle 审计失败：发现 ${RISK_COUNT} 项风险。"
    exit 1
fi

"$ICON_AUDIT" "$BUNDLE"
print "App Bundle 审计通过。"
