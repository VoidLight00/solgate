#!/usr/bin/env bash
# qa-canon shared gate library. macOS bash 3.2 safe. fail-closed helpers.
# source in any *_gate.sh:  . "$(dirname "$0")/lib/gate-lib.sh"
# Design rule: gate helpers NEVER fail-open. Missing file = error, not "0".
set -u

# korean-safe capture: utf-8 output must not crash the gate
qa_run() {            # qa_run cmd...  -> QA_OUT set, returns rc
  QA_OUT="$( "$@" 2>&1 )"; return $?
}

# grep count WITHOUT fail-open masking. missing file -> -1 + rc2 (do not treat as 0).
qa_count() {          # qa_count <ERE> <file> -> prints int
  local pat="$1" file="$2"
  [ -f "$file" ] || { echo "-1"; return 2; }
  grep -cE "$pat" "$file" 2>/dev/null   # no-match prints 0 (real 0); never add '|| echo 0'
  return 0
}

# empty-array guard helper for bash 3.2 + set -u
qa_arr_empty() { [ "$#" -eq 0 ]; }

qa_fail() { QA_RC=1; QA_FAILED="${QA_FAILED:-} $1"; printf 'FAIL[%s]: %s\n' "$1" "$2" >&2; }
qa_ok()   { printf 'PASS[%s]: %s\n' "$1" "$2"; }
