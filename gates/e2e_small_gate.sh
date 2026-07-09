#!/usr/bin/env bash
# solgate e2e small gate — SR1: 가상 모델 소형 왕복(non-stream) + stream SSE 왕복
set -u
PORT="${SOLGATE_PORT:-8321}"
RC=0

# non-stream
reply="$(curl -fsS --max-time 90 "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-5.6-sol-1m","messages":[{"role":"user","content":"Reply with exactly: GATE-PONG"}]}' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["choices"][0]["message"]["content"])' 2>/dev/null)"
if ! printf '%s' "$reply" | grep -q "GATE-PONG"; then
  echo "FAIL: non-stream roundtrip (got: ${reply:-<empty>})"
  RC=1
fi

# stream (SSE 데이터 라인 존재)
sse="$(curl -fsS --max-time 90 "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-5.6-sol-1m","stream":true,"messages":[{"role":"user","content":"Reply with exactly: GATE-PONG"}]}' \
  | grep -c '^data:')"
[ -z "$sse" ] && sse=0
if [ "$sse" -lt 1 ]; then
  echo "FAIL: stream roundtrip returned no SSE data lines"
  RC=1
fi

[ "$RC" -eq 0 ] && echo "e2e_small_gate PASS"
exit "$RC"
