#!/usr/bin/env bash
# solgate e2e compact gate — SR4/SR5/SR6 실측:
#  >300k 대화 → 200 + needle(최근구간) 정답 + prompt_tokens < 372k + 2회차 cacheHits 증가
# 대형 토큰 소모 게이트. 명시적으로만 스킵: SOLGATE_SKIP_BIG=1
set -u
PORT="${SOLGATE_PORT:-8321}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RC=0

if [ "${SOLGATE_SKIP_BIG:-0}" = "1" ]; then
  echo "e2e_compact_gate SKIPPED (SOLGATE_SKIP_BIG=1) — SR4/SR6 미검증"
  exit 0
fi

build() { # $1=extra-turns  $2=outfile
  python3 - "$1" "$2" <<'PY'
import json, sys
extra, out = int(sys.argv[1]), sys.argv[2]
msgs = [{"role": "system", "content": "You are a coding assistant."}]
filler = "filler data alpha beta gamma delta epsilon zeta eta theta " * 120  # ~1.9k tok/msg
for i in range(170):  # ~330k tok → COMPACT_TRIGGER(300k) 초과
    msgs.append({"role": "user", "content": f"turn {i}: {filler}"})
    msgs.append({"role": "assistant", "content": f"ack {i}: {filler}"})
for j in range(extra):
    msgs.append({"role": "user", "content": f"extra {j}: {filler}"})
    msgs.append({"role": "assistant", "content": f"ack extra {j}: {filler}"})
msgs.append({"role": "user", "content": "The secret word is MANGO-AURORA. Remember it."})
msgs.append({"role": "assistant", "content": "Noted."})
msgs.append({"role": "user", "content": "What is the secret word? Reply with only the secret word."})
json.dump({"model": "gpt-5.6-sol-1m", "messages": msgs}, open(out, "w"))
PY
}

stat_field() {
  curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/solgate/stats" | python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"
}
stat_hits() { stat_field cacheHits; }

build 0 "$WORK/big1.json"
h0="$(stat_hits)"
d0="$(stat_field degraded)"
resp1="$(curl -fsS --max-time 300 "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' --data-binary @"$WORK/big1.json")"
if ! printf '%s' "$resp1" | python3 -c '
import json,sys
d=json.load(sys.stdin)
c=d["choices"][0]["message"]["content"]
u=d.get("usage",{}).get("prompt_tokens",10**9)
assert "MANGO-AURORA" in c, f"needle missing: {c[:100]}"
assert u < 372000, f"prompt_tokens {u} >= 372000"
print(f"round1 OK: prompt_tokens={u}")
'; then
  echo "FAIL: round1 (compaction correctness)"
  RC=1
fi

# 2회차: 같은 prefix + 턴 추가 → 앞쪽 완전 청크 요약은 캐시 재사용돼야 함 (SR6)
build 2 "$WORK/big2.json"
resp2="$(curl -fsS --max-time 300 "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' --data-binary @"$WORK/big2.json")"
if ! printf '%s' "$resp2" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert "MANGO-AURORA" in d["choices"][0]["message"]["content"]
print("round2 OK")
'; then
  echo "FAIL: round2 request"
  RC=1
fi
h1="$(stat_hits)"
if [ "${h1:-0}" -le "${h0:-0}" ]; then
  echo "FAIL: cacheHits did not increase (before=$h0 after=$h1)"
  RC=1
else
  echo "cacheHits: $h0 → $h1"
fi

# SR4 실질 검증: 요약 사이드콜이 실제로 작동해야 함 — degraded 증가 = 요약 실패 강등
d1="$(stat_field degraded)"
if [ "${d1:-0}" -gt "${d0:-0}" ]; then
  echo "FAIL: summarizer degraded during gate (before=$d0 after=$d1) — SR4 not actually working"
  RC=1
else
  echo "degraded: $d0 → $d1 (no degradation)"
fi

[ "$RC" -eq 0 ] && echo "e2e_compact_gate PASS"
exit "$RC"
