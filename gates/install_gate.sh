#!/usr/bin/env bash
# solgate install gate — 설치기 무결성: 문법/템플릿/doctor 실측
set -u
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
RC=0

bash -n "$ROOT/setup.sh" || { echo "FAIL: setup.sh syntax"; RC=1; }
zsh -n "$ROOT/install/solgate.zsh" || { echo "FAIL: solgate.zsh syntax"; RC=1; }
node --check "$ROOT/install/merge-ccr.mjs" || { echo "FAIL: merge-ccr.mjs syntax"; RC=1; }

# 템플릿 플레이스홀더 존재 (렌더 치환 누락 방지)
for t in com.solgate.gateway.plist.tmpl com.solgate.sidecar.plist.tmpl sidecar-config.yaml.tmpl; do
  [ -f "$ROOT/install/$t" ] || { echo "FAIL: missing template $t"; RC=1; }
done
grep -q '{{NODE_BIN}}' "$ROOT/install/com.solgate.gateway.plist.tmpl" || { echo "FAIL: gateway tmpl placeholder"; RC=1; }
grep -q '{{SIDECAR_PORT}}' "$ROOT/install/sidecar-config.yaml.tmpl" || { echo "FAIL: sidecar tmpl placeholder"; RC=1; }

# 렌더 후 잔존 플레이스홀더 0 검증 (mock 변수로 렌더)
rendered="$(sed -e 's|{{NODE_BIN}}|/usr/local/bin/node|g' -e 's|{{REPO_ROOT}}|/tmp/x|g' \
  -e 's|{{HOME}}|/tmp/h|g' -e 's|{{UPSTREAM}}|http://u|g' -e 's|{{UPSTREAM_LUNA}}|http://l|g' \
  "$ROOT/install/com.solgate.gateway.plist.tmpl")"
leftover="$(printf '%s' "$rendered" | grep -c '{{')"
[ -z "$leftover" ] && leftover=0
[ "$leftover" -gt 0 ] && { echo "FAIL: gateway tmpl has unrendered placeholders ($leftover)"; RC=1; }

# doctor 실측 (read-only)은 명시한 경우에만 실행한다. CI/배포 검증은 구조 게이트로 재현 가능해야 한다.
if [ "${SOLGATE_INSTALL_LIVE:-0}" = "1" ]; then
  if ! bash "$ROOT/setup.sh" doctor --no-probe >/dev/null 2>&1; then
    echo "FAIL: setup.sh doctor --no-probe exit != 0"
    RC=1
  fi
else
  echo "install_gate: live doctor skipped (SOLGATE_INSTALL_LIVE=1 to enable)"
fi

# zshrc 함수 스모크: 함수 로드 + 모델/캡 해석
out="$(zsh -c "source '$ROOT/install/solgate.zsh'; _solgate_model_id terra; _solgate_cap_for gpt-5.6-sol-1m" 2>/dev/null)"
printf '%s' "$out" | grep -q 'gpt-5.6-terra' || { echo "FAIL: solgate.zsh model resolution"; RC=1; }
printf '%s' "$out" | grep -q '1m' || { echo "FAIL: solgate.zsh cap resolution"; RC=1; }

[ "$RC" -eq 0 ] && echo "install_gate PASS"
exit "$RC"
