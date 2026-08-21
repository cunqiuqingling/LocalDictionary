#!/bin/zsh
set -euo pipefail

TOOL_DIR="${0:A:h}"
if (( $# > 0 )); then
  EVIDENCE="$1"
else
  LAST="$TOOL_DIR/.last-session"
  [[ -f "$LAST" ]] || { print -u2 "尚未开始 Evidence 测试。"; exit 1; }
  EVIDENCE="$(<"$LAST")/evidence.jsonl"
fi
/usr/bin/python3 "$TOOL_DIR/analyze-evidence.py" "$EVIDENCE" \
  --output "${EVIDENCE:h}/EVIDENCE-SUMMARY.md"
