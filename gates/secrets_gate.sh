#!/usr/bin/env bash
# secrets_gate — HARD. blocks publishing obvious secrets. bash 3.2 safe, fail-closed.
set -u
ROOT="${1:-$(pwd)}"
RC=0
PAT='(sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,})'
HITS="$(grep -rIlE "$PAT" "$ROOT" \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=fixtures \
  --exclude-dir=.next --exclude-dir=dist --exclude='*.bak*' 2>/dev/null || true)"
if [ -n "$HITS" ]; then
  echo "FAIL[secrets]: secret-like pattern found in:"
  printf '%s\n' "$HITS"
  RC=1
else
  echo "PASS[secrets]: no obvious secrets in tracked tree"
fi
exit "$RC"
