#!/bin/zsh
set -euo pipefail

if (( $# > 1 )); then
    print -u2 "用法：audit-app-icon.sh [App Bundle]"
    exit 2
fi

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
PROJECT_FILE="$PROJECT_ROOT/App/LocalDictionary.xcodeproj/project.pbxproj"
SOURCE_INFO_PLIST="$PROJECT_ROOT/App/Info.plist"
ASSET_CATALOG="$PROJECT_ROOT/App/Assets.xcassets"
ICON_SET="$ASSET_CATALOG/AppIcon.appiconset"
CONTENTS_JSON="$ICON_SET/Contents.json"

fail() {
    print -u2 "App 图标审计失败：$1"
    exit 1
}

[[ -d "$ASSET_CATALOG" ]] || fail "缺少 Assets.xcassets。"
[[ -d "$ICON_SET" ]] || fail "缺少 AppIcon.appiconset。"
[[ -f "$CONTENTS_JSON" ]] || fail "缺少 AppIcon Contents.json。"
[[ -f "$PROJECT_FILE" ]] || fail "缺少 Xcode 工程配置。"
[[ -f "$SOURCE_INFO_PLIST" ]] || fail "缺少源 Info.plist。"

/usr/bin/plutil -convert xml1 -o /dev/null "$CONTENTS_JSON" || fail "AppIcon Contents.json 无效。"

typeset -a slots=(
    "0|AppIcon-16.png|16x16|1x|16"
    "1|AppIcon-16@2x.png|16x16|2x|32"
    "2|AppIcon-32.png|32x32|1x|32"
    "3|AppIcon-64.png|32x32|2x|64"
    "4|AppIcon-128.png|128x128|1x|128"
    "5|AppIcon-128@2x.png|128x128|2x|256"
    "6|AppIcon-256.png|256x256|1x|256"
    "7|AppIcon-256@2x.png|256x256|2x|512"
    "8|AppIcon-512.png|512x512|1x|512"
    "9|AppIcon-1024.png|512x512|2x|1024"
)

filename_count="$(/usr/bin/grep -c '"filename"' "$CONTENTS_JSON")"
[[ "$filename_count" == "10" ]] || fail "AppIcon 必须且只能声明 10 个标准 macOS 槽位。"

for slot in "${slots[@]}"; do
    IFS='|' read -r index filename size scale pixels <<< "$slot"
    actual_filename="$(/usr/bin/plutil -extract "images.${index}.filename" raw -o - "$CONTENTS_JSON")"
    actual_idiom="$(/usr/bin/plutil -extract "images.${index}.idiom" raw -o - "$CONTENTS_JSON")"
    actual_size="$(/usr/bin/plutil -extract "images.${index}.size" raw -o - "$CONTENTS_JSON")"
    actual_scale="$(/usr/bin/plutil -extract "images.${index}.scale" raw -o - "$CONTENTS_JSON")"

    [[ "$actual_filename" == "$filename" ]] || fail "槽位 ${index} 的文件名不正确。"
    [[ "$actual_idiom" == "mac" ]] || fail "槽位 ${index} 不是 macOS 图标。"
    [[ "$actual_size" == "$size" ]] || fail "槽位 ${index} 的点尺寸不正确。"
    [[ "$actual_scale" == "$scale" ]] || fail "槽位 ${index} 的缩放倍率不正确。"

    icon_file="$ICON_SET/$filename"
    [[ -s "$icon_file" ]] || fail "缺少图标文件 ${filename}。"
    width="$(/usr/bin/sips -g pixelWidth "$icon_file" 2>/dev/null | /usr/bin/awk '/pixelWidth:/ { print $2 }')"
    height="$(/usr/bin/sips -g pixelHeight "$icon_file" 2>/dev/null | /usr/bin/awk '/pixelHeight:/ { print $2 }')"
    format="$(/usr/bin/sips -g format "$icon_file" 2>/dev/null | /usr/bin/awk '/format:/ { print $2 }')"
    [[ "$width" == "$pixels" && "$height" == "$pixels" ]] || \
        fail "${filename} 的像素尺寸必须为 ${pixels}×${pixels}。"
    [[ "$format" == "png" ]] || fail "${filename} 必须是真正的 PNG。"
done

setting_count="$(/usr/bin/grep -c 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' "$PROJECT_FILE")"
[[ "$setting_count" == "2" ]] || fail "Debug 和 Release 必须都使用 AppIcon。"
if /usr/bin/grep 'ASSETCATALOG_COMPILER_APPICON_NAME[[:space:]]*=' "$PROJECT_FILE" | \
    /usr/bin/grep -v 'ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;' >/dev/null; then
    fail "存在不使用 AppIcon 的构建配置。"
fi

resource_reference_count="$(/usr/bin/grep -c 'Assets.xcassets in Resources' "$PROJECT_FILE")"
[[ "$resource_reference_count" == "2" ]] || fail "Assets.xcassets 未唯一加入 Copy Bundle Resources。"

if /usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$SOURCE_INFO_PLIST" >/dev/null 2>&1 || \
   /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$SOURCE_INFO_PLIST" >/dev/null 2>&1; then
    fail "源 Info.plist 不应绕过 Asset Catalog 手工指定图标。"
fi

if (( $# == 1 )); then
    BUNDLE="${1:A}"
    [[ -d "$BUNDLE" ]] || { print -u2 "用法：audit-app-icon.sh [App Bundle]"; exit 2; }
    BUNDLE_INFO="$BUNDLE/Contents/Info.plist"
    RESOURCES="$BUNDLE/Contents/Resources"

    [[ -f "$BUNDLE_INFO" ]] || fail "生成的 App 缺少 Info.plist。"
    [[ -s "$RESOURCES/Assets.car" ]] || fail "生成的 App 缺少编译后的 Assets.car。"
    [[ -s "$RESOURCES/AppIcon.icns" ]] || fail "生成的 App 缺少编译后的 AppIcon.icns。"

    bundle_icon_file="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$BUNDLE_INFO" 2>/dev/null || true)"
    bundle_icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$BUNDLE_INFO" 2>/dev/null || true)"
    [[ "$bundle_icon_file" == "AppIcon" ]] || fail "生成的 Info.plist 未指向 AppIcon 文件。"
    [[ "$bundle_icon_name" == "AppIcon" ]] || fail "生成的 Info.plist 未指向 AppIcon Asset。"

    finder_icon="$BUNDLE/Icon"$'\r'
    [[ ! -e "$finder_icon" ]] || fail "App Bundle 含 Finder 手工图标。"
fi

print "App 图标审计通过。"
