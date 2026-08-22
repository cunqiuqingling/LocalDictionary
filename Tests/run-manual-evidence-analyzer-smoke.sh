#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/LocalDictionary-evidence-analyzer.XXXXXX")"
trap '/bin/rm -rf "$WORK"' EXIT

/usr/bin/python3 "$ROOT/scripts/manual-evidence/analyze-evidence.py" \
  "$ROOT/Tests/Fixtures/manual-evidence-pass.jsonl" --output "$WORK/pass.md"
/usr/bin/grep -Fq 'Overall: **PASS**' "$WORK/pass.md"

if /usr/bin/python3 "$ROOT/scripts/manual-evidence/analyze-evidence.py" \
     "$ROOT/Tests/Fixtures/manual-evidence-fail.jsonl" --output "$WORK/fail.md"; then
  print -u2 "failing evidence unexpectedly passed"
  exit 1
fi
for rule in APPLE-001 APPLE-002 APPLE-003 APPLE-004 APPLE-006 APPLE-007 \
            APPLE-008 APPLE-009 FREE-001 FREE-002 FREE-004 AI-001 AI-002 AI-003 \
            AI-004 AI-005 AI-006 AI-007 \
            AI-008 AI-009 AI-010 \
            INLINE-001 INLINE-002 INLINE-003 INLINE-004 INLINE-005 INLINE-006 \
            LANG-001 LANG-002 LANG-003 LANG-004 LANG-005 \
            LANG-006 LANG-007 LANG-008 LANG-009 LANG-010 LANG-011; do
  /usr/bin/grep -Fq "### $rule — FAIL" "$WORK/fail.md"
done
print "Manual Evidence analyzer smoke: PASS"
