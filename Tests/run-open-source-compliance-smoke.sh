#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-only
set -euo pipefail

ROOT="${0:A:h:h}"
GPL_SHA256="3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
PUBLIC_DOCS=(
  "$ROOT/README.md"
  "$ROOT/App/README.md"
  "$ROOT/Tests/README.md"
  "$ROOT/THIRD_PARTY_NOTICES.md"
  "$ROOT/SECURITY.md"
  "$ROOT/docs/privacy.md"
  "$ROOT/docs/architecture.md"
  "$ROOT/docs/d1-resource-policy.md"
  "$ROOT/docs/d1-manifest-format.md"
  "$ROOT/docs/provenance.md"
  "$ROOT/ThirdParty/README.md"
)

fail() {
  print -u2 -- "Open-source compliance smoke failed: $1"
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing ${1#$ROOT/}"
}

require_literal() {
  local file="$1"
  local value="$2"
  /usr/bin/grep -Fq -- "$value" "$file" || \
    fail "missing required statement in ${file#$ROOT/}"
}

reject_pattern() {
  local pattern="$1"
  local scan_exit
  shift
  if /usr/bin/grep -REni -- "$pattern" "$@" >/dev/null; then
    fail "forbidden text matched: $pattern"
  else
    scan_exit=$?
    (( scan_exit == 1 )) || fail "portable content scan failed: $pattern"
  fi
}

for file in "$ROOT/LICENSE" "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/SECURITY.md" \
            "$ROOT/docs/privacy.md" "$ROOT/docs/d1-resource-policy.md" \
            "$ROOT/docs/d1-manifest-format.md" "$ROOT/docs/provenance.md"; do
  require_file "$file"
done

actual_gpl_hash="$(/usr/bin/shasum -a 256 "$ROOT/LICENSE" | /usr/bin/awk '{print $1}')"
[[ "$actual_gpl_hash" == "$GPL_SHA256" ]] || fail "LICENSE is not the exact official GPLv3 text"
require_literal "$ROOT/LICENSE" "GNU GENERAL PUBLIC LICENSE"
require_literal "$ROOT/LICENSE" "Version 3, 29 June 2007"
require_literal "$ROOT/LICENSE" "END OF TERMS AND CONDITIONS"

require_literal "$ROOT/README.md" \
  "LocalDictionary original project code is licensed under GPL-3.0-only."
reject_pattern 'GPL-3\.0-or-later' "$ROOT/README.md" "$ROOT/docs/provenance.md"
reject_pattern 'original project code (is|are|采用|使用).*(MIT|Apache|MPL)' \
  "$ROOT/README.md" "$ROOT/docs/provenance.md"

for file in \
  "$ROOT/ThirdParty/vendor/mdict-cpp/LICENSE" \
  "$ROOT/ThirdParty/vendor/miniz/LICENSE" \
  "$ROOT/ThirdParty/vendor/libtomcrypt-ripemd128/LICENSE"; do
  require_file "$file"
done
(cd "$ROOT/ThirdParty" && /usr/bin/shasum -a 256 -c SHA256SUMS >/dev/null) || \
  fail "ThirdParty SHA-256 verification failed"

for value in \
  "00821615ffbd4fd3d49092a4d26e5c5a6ca10968" \
  "a4264837ae37384b1d7a205a6732db322f0f3769" \
  "7e7eb695d581782f04b24dc444cbfde86af59853"; do
  require_literal "$ROOT/THIRD_PARTY_NOTICES.md" "$value"
  require_literal "$ROOT/ThirdParty/README.md" "$value"
done
reject_pattern 'Unlicense' "$ROOT/THIRD_PARTY_NOTICES.md" "$ROOT/docs/provenance.md"

reject_pattern 'SPDX-License-Identifier:[[:space:]]*GPL-3\.0' "$ROOT/ThirdParty/vendor"
require_literal "$ROOT/README.md" "仓库不包含五本开发者本地商业词典"
require_literal "$ROOT/README.md" "首次公开阶段只提供源码"
require_literal "$ROOT/README.md" "暂不提供官方签名或公证的"

reject_pattern 'Fully offline|完全离线' "$ROOT/docs/privacy.md"
require_literal "$ROOT/docs/privacy.md" "可选 AI 功能会连接用户配置的第三方服务"
require_literal "$ROOT/docs/privacy.md" "当前缓存上限为 256 条"

expected_security_contact="cunqiuqingling""@""gmail.com"
require_literal "$ROOT/SECURITY.md" "$expected_security_contact"
security_contact_output=""
if security_contact_output="$(git -C "$ROOT" grep --untracked -l -F \
  "$expected_security_contact" -- . \
  ':(exclude)ThirdParty/vendor/mdict-cpp/**')"; then
  :
else
  scan_exit=$?
  (( scan_exit == 1 )) || fail "security contact scan failed"
fi
security_contact_files=("${(@f)security_contact_output}")
[[ "${#security_contact_files[@]}" -eq 1 && \
   "$security_contact_files[1]" == "SECURITY.md" ]] || \
  fail "security contact appears outside SECURITY.md"

require_literal "$ROOT/docs/provenance.md" \
  "Copyright holder: liuzhentie (刘震铁, aka \"cunqiu\")"
require_literal "$ROOT/docs/provenance.md" "Starting year: 2026"
require_literal "$ROOT/docs/provenance.md" \
  "The AppIcon was generated with assistance from Google Gemini."

reject_pattern '<COPYRIGHT_HOLDER>|<APP_ICON_SOURCE>|<SECURITY_CONTACT>' \
  "${PUBLIC_DOCS[@]}"
reject_pattern '/Users/[^/[:space:]`"]+' "${PUBLIC_DOCS[@]}"
reject_pattern 'sk-[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{20,}' "${PUBLIC_DOCS[@]}"
reject_pattern 'Authorization:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9_.-]{10,}' \
  "${PUBLIC_DOCS[@]}"

reject_pattern 'https?://' "$ROOT/docs/d1-resource-policy.md"
[[ ! -e "$ROOT/resources.json" ]] || fail "D1 resources.json must not exist"
require_literal "$ROOT/docs/d1-manifest-format.md" "LDMSIG01"
require_literal "$ROOT/docs/d1-manifest-format.md" "generic-mdict-v1"
require_literal "$ROOT/docs/d1-manifest-format.md" \
  "D1b-1 intentionally ships an empty production trust store"
private_key_output=""
if private_key_output="$(git -C "$ROOT" grep --untracked -E \
  'BEGIN ([A-Z0-9]+ )?PRIVATE KEY|OPENSSH PRIVATE KEY' -- . \
  ':(exclude)scripts/audit-app-bundle.sh' \
  ':(exclude)Tests/run-app-bundle-audit-smoke.sh' \
  ':(exclude)Tests/run-open-source-compliance-smoke.sh')"; then
  fail "formal private-key material appears outside the synthetic audit boundary"
else
  scan_exit=$?
  (( scan_exit == 1 )) || fail "private-key repository scan failed"
fi
require_literal "$ROOT/docs/d1-resource-policy.md" "### A：可由项目托管或镜像"
require_literal "$ROOT/docs/d1-resource-policy.md" "### B：仅链接官方来源"
require_literal "$ROOT/docs/d1-resource-policy.md" "### C：暂不收录"
require_literal "$ROOT/docs/d1-resource-policy.md" "### D：禁止收录"

require_literal "$ROOT/README.md" \
  "可选的第三方 AI 单词解释和句子学习分析"
require_literal "$ROOT/docs/privacy.md" \
  "本地词典在设备上运行，可选 AI 功能会连接用户配置的第三方服务"
require_literal "$ROOT/README.md" \
  "~/Library/Application Support/LocalDictionary/LegacyConfig/"
require_literal "$ROOT/docs/privacy.md" \
  "~/Library/Application Support/LocalDictionary/LegacyConfig/local.json"
require_literal "$ROOT/README.md" "不会进入 App Bundle"
require_literal "$ROOT/docs/privacy.md" "不进入 App Bundle"

require_literal "$ROOT/README.md" \
  "ThirdParty 文件继续适用各自许可证，词典数据不属于项目 GPL 授权范围。"
require_literal "$ROOT/docs/provenance.md" \
  "The root GPL-3.0-only license does not replace BSD-3-Clause, MIT, Public Domain, or WTFPL Version 2 terms"
require_literal "$ROOT/THIRD_PARTY_NOTICES.md" \
  "Any future binary distribution must reproduce the applicable third-party copyright notices"

print "Open-source compliance smoke passed"
