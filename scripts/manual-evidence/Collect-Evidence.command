#!/bin/zsh
set -euo pipefail

TOOL_DIR="${0:A:h}"
POINTER="$TOOL_DIR/CANDIDATE-PATH.txt"
[[ -f "$POINTER" ]] || { print -u2 "缺少 CANDIDATE-PATH.txt。"; exit 1; }
CANDIDATE_DIR="$(<"$POINTER")"
case "$CANDIDATE_DIR" in
  /Users/liuzhentie/Desktop/LocalDictionary-*) ;;
  *) print -u2 "人工候选路径无效。"; exit 1 ;;
esac
LAST="$TOOL_DIR/.last-session"
[[ -f "$LAST" ]] || { print -u2 "尚未开始 Evidence 测试。"; exit 1; }
SESSION_DIR="$(<"$LAST")"
case "$SESSION_DIR" in
  /Users/liuzhentie/Desktop/LocalDictionary-Evidence-[0-9]*) ;;
  *) print -u2 "Evidence session 路径无效。"; exit 1 ;;
esac
[[ -d "$SESSION_DIR" && -f "$SESSION_DIR/evidence.jsonl" ]] || {
  print -u2 "找不到 evidence.jsonl；请先运行 Start-Evidence-Test.command。"
  exit 1
}
if /usr/bin/pgrep -x LocalDictionary >/dev/null 2>&1; then
  print -u2 "LocalDictionary 仍在运行。请先从 App 菜单正常退出，再收集证据。"
  exit 1
fi
{
  print -r -- "collected_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
  print -r -- "process_exit_state=not_running"
  print -r -- "candidate_sha256=$(/usr/bin/shasum -a 256 "$CANDIDATE_DIR/LocalDictionary.app/Contents/MacOS/LocalDictionary" | /usr/bin/awk '{print $1}')"
} >> "$SESSION_DIR/session-metadata.txt"
"$TOOL_DIR/Analyze-Evidence.command" "$SESSION_DIR/evidence.jsonl"
print "收集完成：$SESSION_DIR"
print "请把 EVIDENCE-SUMMARY.md 和 evidence.jsonl 提供给 Codex。"
