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
out="$(zsh -c "source '$ROOT/install/solgate.zsh'; _solgate_model_id terra1m; _solgate_model_id luna1m; _solgate_cap_for gpt-5.6-terra-1m" 2>/dev/null)"
printf '%s' "$out" | grep -q 'gpt-5.6-terra-1m' || { echo "FAIL: terra1m model resolution"; RC=1; }
printf '%s' "$out" | grep -q 'gpt-5.6-luna-1m' || { echo "FAIL: luna1m model resolution"; RC=1; }
printf '%s' "$out" | grep -q '1m' || { echo "FAIL: virtual cap resolution"; RC=1; }

# /model picker env: physical vgpt와 virtual vgpt1m 슬롯을 혼합하지 않는다.
picker_out="$(SOLGATE_ROOT="$ROOT" zsh -c '
  claude() {
    print -r -- "MAIN=$ANTHROPIC_MODEL"
    print -r -- "ARG=$2"
    print -r -- "OPUS=$ANTHROPIC_DEFAULT_OPUS_MODEL"
    print -r -- "ARGS=$*"
    print -r -- "SONNET=$ANTHROPIC_DEFAULT_SONNET_MODEL"
    print -r -- "HAIKU=$ANTHROPIC_DEFAULT_HAIKU_MODEL"
  }
  source "$SOLGATE_ROOT/install/solgate.zsh"
  vgpt1m
' 2>/dev/null)"
for want in \
  'MAIN=solgate,gpt-5.6-sol-1m[1m]' \
  'ARG=solgate,gpt-5.6-sol-1m[1m]' \
  'OPUS=solgate,gpt-5.6-sol-1m[1m]' \
  'SONNET=solgate,gpt-5.6-terra-1m[1m]' \
  'HAIKU=solgate,gpt-5.6-luna-1m[1m]'; do
  printf '%s\n' "$picker_out" | grep -Fq "$want" || { echo "FAIL: vgpt1m picker env missing: $want"; RC=1; }
done
printf '%s\n' "$picker_out" | grep -Fq '[330k][1m]' && { echo "FAIL: vgpt1m duplicated cap label"; RC=1; }

# Astra aliases preserve the main model and only use the Astra virtual profile
# when requested. Mock the executable so no provider request can be sent.
astra_out="$(SOLGATE_ROOT="$ROOT" zsh -c '
  claude() {
    print -r -- "MAIN=$ANTHROPIC_MODEL"
    print -r -- "ARG=$2"
    print -r -- "OPUS=$ANTHROPIC_DEFAULT_OPUS_MODEL"
    print -r -- "ARGS=$*"
  }
  source "$SOLGATE_ROOT/install/solgate.zsh"
  vgpt astra
  vgpt astra1m
  vgpt1m astra
' 2>/dev/null)"
for want in \
  'MAIN=solgate,gpt-6-astra[240k]' \
  'ARG=solgate,gpt-6-astra[240k]' \
  'OPUS=solgate,gpt-5.6-sol[330k]' \
  'ARGS=--model solgate,gpt-6-astra[240k] --autocompact 220k' \
  'MAIN=solgate,gpt-6-astra-1m[1m]' \
  'ARG=solgate,gpt-6-astra-1m[1m]' \
  'OPUS=solgate,gpt-5.6-sol-1m[1m]'; do
  printf '%s\n' "$astra_out" | grep -Fq "$want" || { echo "FAIL: Astra alias env missing: $want"; RC=1; }
done
virtual_count="$(printf '%s\n' "$astra_out" | grep -Fc 'MAIN=solgate,gpt-6-astra-1m[1m]')"
[ "$virtual_count" -eq 2 ] || { echo "FAIL: Astra virtual aliases disagree"; RC=1; }
if printf '%s\n' "$astra_out" | grep -E 'ARGS=.*gpt-6-astra-1m.*--autocompact' >/dev/null; then
  echo "FAIL: Astra virtual profile received physical auto-compact option"
  RC=1
fi

override_out="$(SOLGATE_ROOT="$ROOT" zsh -c '
  claude() { print -r -- "$*"; }
  source "$SOLGATE_ROOT/install/solgate.zsh"
  vgpt astra --autocompact 200k
' 2>/dev/null)"
printf '%s\n' "$override_out" | grep -Fq -- '--autocompact 220k --autocompact 200k' || {
  echo "FAIL: explicit user options must follow Astra defaults"
  RC=1
}

[ "$RC" -eq 0 ] && echo "install_gate PASS"
exit "$RC"
