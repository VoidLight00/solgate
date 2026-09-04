#!/usr/bin/env bash
# solgate service gate — SR2(/v1/models 가상 모델 주입) + SR9(127.0.0.1 바인드 + launchd)
set -u
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PORT="${SOLGATE_PORT:-8321}"
RC=0

# SR9a: launchd 등록. 공개 installer label 또는 초기 개발판 legacy label을 허용한다.
if ! launchctl list 2>/dev/null | grep -Eq "com\.solgate\.gateway|com\.voidlight\.solgate"; then
  echo "FAIL: launchd job com.solgate.gateway not loaded"
  RC=1
fi

# SR9b: 서비스 살아있음 + 127.0.0.1 바인드 (0.0.0.0/* 노출 금지)
if ! curl -fsS --max-time 5 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
  echo "FAIL: solgate not responding on 127.0.0.1:${PORT}"
  RC=1
else
  wide="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -E -c -e '\*:'"$PORT" -e '0\.0\.0\.0')"
  [ -z "$wide" ] && wide=0
  if [ "$wide" -gt 0 ]; then
    echo "FAIL: port $PORT bound on non-localhost interface"
    RC=1
  fi
fi

# SR2: 가상 모델 노출 + upstream 목록 보존
models="$(curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null)"
if ! printf '%s' "$models" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ids=[m["id"] for m in d["data"]]
by_id={m["id"]:m for m in d["data"]}
for model_id in ("gpt-6-astra-1m","gpt-5.6-sol-1m","gpt-5.6-terra-1m","gpt-5.6-luna-1m"):
    v=by_id.get(model_id)
    assert v, f"{model_id} missing"
    assert v.get("context_length")==1000000, f"{model_id} context_length != 1000000"
    assert ids.count(model_id)==1, f"{model_id} duplicated"
assert "gpt-5.6-sol" in by_id, "upstream model list not preserved"
' 2>/dev/null; then
  echo "FAIL: /v1/models virtual injection check"
  RC=1
fi

[ "$RC" -eq 0 ] && echo "service_gate PASS"
exit "$RC"
