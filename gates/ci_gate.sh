#!/usr/bin/env bash
# solgate portable CI master — host credentials/services 없이 재현 가능한 게이트만 자동 발견.
set -u
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
GATES_DIR="$(cd "$(dirname "$0")" && pwd)"
RC=0

for g in "$GATES_DIR"/*_gate.sh; do
  [ -e "$g" ] || continue
  base="$(basename "$g")"
  case "$base" in
    ci_gate.sh|e2e_compact_gate.sh|e2e_small_gate.sh|service_gate.sh|wiring_gate.sh)
      continue
      ;;
  esac
  bash "$g" "$ROOT"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL[%s]: exit %s\n' "$base" "$rc"
    RC=1
  fi
done

[ "$RC" -eq 0 ] && printf 'ci_gate PASS (portable)\n'
exit "$RC"
