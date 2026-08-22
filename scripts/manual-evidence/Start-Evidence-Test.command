#!/bin/zsh
set -euo pipefail

TOOL_DIR="${0:A:h}"
POINTER="$TOOL_DIR/CANDIDATE-PATH.txt"
[[ -f "$POINTER" ]] || { print -u2 "缺少 CANDIDATE-PATH.txt，无法确认测试对象。"; exit 1; }
CANDIDATE_DIR="$(<"$POINTER")"
case "$CANDIDATE_DIR" in
  /Users/liuzhentie/Desktop/LocalDictionary-*) ;;
  *) print -u2 "人工候选路径无效：$CANDIDATE_DIR"; exit 1 ;;
esac
CANDIDATE_APP="$CANDIDATE_DIR/LocalDictionary.app"
CANDIDATE_BIN="$CANDIDATE_APP/Contents/MacOS/LocalDictionary"

if /usr/bin/pgrep -x LocalDictionary >/dev/null 2>&1; then
  print -u2 "LocalDictionary 正在运行。请先正常退出 App，再重新双击本脚本。"
  exit 1
fi
if [[ ! -x "$CANDIDATE_BIN" ]]; then
  print -u2 "找不到人工验收 App：$CANDIDATE_APP"
  exit 1
fi

STAMP="$(/bin/date '+%Y%m%d-%H%M%S')"
SESSION_DIR="/Users/liuzhentie/Desktop/LocalDictionary-Evidence-$STAMP"
/bin/mkdir -m 700 "$SESSION_DIR"
EVIDENCE="$SESSION_DIR/evidence.jsonl"
{
  print -r -- "candidate=$CANDIDATE_APP"
  print -r -- "candidate_sha256=$(/usr/bin/shasum -a 256 "$CANDIDATE_BIN" | /usr/bin/awk '{print $1}')"
  print -r -- "candidate_pointer=$CANDIDATE_DIR"
  print -r -- "macos=$(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))"
  print -r -- "started_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$SESSION_DIR/session-metadata.txt"
/bin/chmod 600 "$SESSION_DIR/session-metadata.txt"
print -r -- "$SESSION_DIR" > "$TOOL_DIR/.last-session"
/bin/chmod 600 "$TOOL_DIR/.last-session"

/usr/bin/open -na "$CANDIDATE_APP" --args --manual-evidence-log "$EVIDENCE"
print "Evidence 模式已启动。请按 EVIDENCE-TEST-INSTRUCTIONS.md 做少量人工操作。"
print "证据目录：$SESSION_DIR"
