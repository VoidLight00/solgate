#!/usr/bin/env bash
# solgate unit gate — SR3/SR4/SR5/SR7/SR10 순수 함수 + SR8 로그 원문 금지(정적)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
RC=0

TESTS="tests/unit.test.mjs tests/fallback.e2e.test.mjs tests/ctxretry.e2e.test.mjs tests/ctxwindow.e2e.test.mjs tests/virtual-models.e2e.test.mjs"
for test_file in $TESTS; do
  if [ ! -f "$ROOT/$test_file" ]; then
    echo "FAIL: required test missing: $test_file"
    RC=1
  elif command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && ! git -C "$ROOT" ls-files --error-unmatch "$test_file" >/dev/null 2>&1; then
    echo "FAIL: required test is not tracked: $test_file"
    RC=1
  fi
done

if [ "$RC" -eq 0 ]; then
  out="$(cd "$ROOT" && node --test $TESTS 2>&1)"; rc=$?
else
  out=""
  rc=1
fi
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$out" | tail -20
  echo "FAIL: node --test exit $rc"
  RC=1
fi

# SR8 정적 검사: logLine 호출 블록에 대화 원문 필드(content/messages)가 없어야 한다.
leak="$(awk '/logLine\(\{/,/\}\);/' "$ROOT/server.mjs" | grep -E -c -e 'content' -e 'messages\b' 2>/dev/null)"
[ -z "$leak" ] && leak=0
if [ "$leak" -gt 0 ]; then
  echo "FAIL: logLine block references content/messages ($leak)"
  RC=1
fi

[ "$RC" -eq 0 ] && echo "unit_gate PASS"
exit "$RC"
