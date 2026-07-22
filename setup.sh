#!/usr/bin/env bash
# solgate 원웨이 설치기 (macOS 전용, bash 3.2 호환)
# usage: ./setup.sh [doctor|install|uninstall] [--upstream URL] [--no-probe] [--no-pong] [--no-npm]
#
# install이 하는 일 (멱등):
#  1. doctor — node/claude/ccr/업스트림(VibeProxy 등) 검증, luna auth 프로브
#  2. solgate launchd 상주 (com.solgate.gateway, :8321)
#  3. luna auth 버그 감지 시 CLIProxyAPI 사이드카 자동 설치 (com.solgate.sidecar, :8331)
#  4. CCR config에 solgate provider 비파괴 머지 + ccr restart
#  5. ~/.zshrc에 vgpt/vgpt1m 함수 source 블록 추가
#  6. 최종 실측 검증 (healthz / models / CCR 경유 PONG)
set -u

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CMD="${1:-install}"
[ $# -gt 0 ] && shift || true

UPSTREAM="http://127.0.0.1:8317"
NO_PROBE=0
NO_PONG=0
NO_NPM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --upstream) UPSTREAM="$2"; shift 2 ;;
    --no-probe) NO_PROBE=1; shift ;;
    --no-pong)  NO_PONG=1; shift ;;
    --no-npm)   NO_NPM=1; shift ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
done

SOLGATE_PORT=8321
SIDECAR_PORT=8331
SIDECAR_VERSION="7.2.58"
SIDECAR_SHA_ARM64="52882fab08d10882510969d3ada73dd7bcb5590831db6263849a7be987b0093b"
SIDECAR_SHA_AMD64="6508350c2b1da5f89164849c50cf9b53c9a9f9a5cfa27cdd8806e4f3f344082d"
LAUNCH_DIR="$HOME/Library/LaunchAgents"
GATEWAY_PLIST="$LAUNCH_DIR/com.solgate.gateway.plist"
SIDECAR_PLIST="$LAUNCH_DIR/com.solgate.sidecar.plist"
LEGACY_GATEWAY_PLIST="$LAUNCH_DIR/com.voidlight.solgate.plist"
LEGACY_SIDECAR_PLIST="$LAUNCH_DIR/com.voidlight.cpap-sidecar.plist"
ZSHRC_MARK_BEGIN="# >>> solgate >>>"
ZSHRC_MARK_END="# <<< solgate <<<"

RC=0
log()  { printf '%s\n' "$*"; }
ok()   { printf 'OK   %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
fail() { printf 'FAIL %s\n' "$*"; RC=1; }

need_luna_sidecar=0
migration_active=0
install_complete=0

rollback_legacy() {
  [ "$migration_active" -eq 1 ] || return 0
  [ "$install_complete" -eq 0 ] || return 0
  launchctl unload "$GATEWAY_PLIST" 2>/dev/null || true
  launchctl unload "$SIDECAR_PLIST" 2>/dev/null || true
  [ -f "$LEGACY_GATEWAY_PLIST" ] && launchctl load "$LEGACY_GATEWAY_PLIST" 2>/dev/null || true
  [ -f "$LEGACY_SIDECAR_PLIST" ] && launchctl load "$LEGACY_SIDECAR_PLIST" 2>/dev/null || true
  warn "설치 실패로 legacy launchd 서비스를 복구했습니다"
}

trap rollback_legacy EXIT

# ---------- doctor ----------
doctor() {
  RC=0
  [ "$(uname -s)" = "Darwin" ] || { fail "macOS 전용입니다 (launchd)"; return 1; }
  ok "platform: macOS $(uname -m)"

  if command -v node >/dev/null 2>&1; then
    major="$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null)"
    [ "${major:-0}" -ge 20 ] && ok "node $(node --version)" || fail "node >= 20 필요 (현재 $(node --version))"
  else
    fail "node 없음 — https://nodejs.org 또는 nvm으로 설치"
  fi

  command -v claude >/dev/null 2>&1 && ok "claude CLI $(claude --version 2>/dev/null | head -1)" \
    || fail "claude CLI 없음 — npm i -g @anthropic-ai/claude-code"

  command -v ccr >/dev/null 2>&1 && ok "ccr (claude-code-router)" \
    || fail "ccr 없음 — npm i -g @musistudio/claude-code-router 후 'ccr start'로 config 생성"

  if command -v codex >/dev/null 2>&1; then
    ok "codex CLI $(codex --version 2>/dev/null) (선택 사항 — 직접 codex 사용 시 0.144+ 권장)"
  else
    warn "codex CLI 없음 (proxy 체인에는 불필요, 참고용)"
  fi

  models="$(curl -fsS --max-time 8 "$UPSTREAM/v1/models" 2>/dev/null)"
  if [ -z "$models" ]; then
    fail "업스트림($UPSTREAM) 무응답 — VibeProxy(또는 CLIProxyAPI)를 설치하고 ChatGPT OAuth 로그인하세요"
  elif printf '%s' "$models" | grep -q 'gpt-5.6-sol'; then
    ok "업스트림 gpt-5.6-sol 노출 확인"
  else
    fail "업스트림에 gpt-5.6-sol 없음 — VibeProxy 재시작(원격 모델 카탈로그 재fetch) 후 재시도"
  fi

  # luna auth 프로브: 구엔진(<=7.2.54)의 auth_unavailable 버그 감지 → 사이드카 필요 판정
  if [ "$NO_PROBE" -eq 1 ]; then
    warn "luna 프로브 스킵(--no-probe) — luna 실패 시 setup.sh install을 다시 실행"
  else
    luna_raw="$(curl -sS --max-time 30 -w '\n%{http_code}' "$UPSTREAM/v1/chat/completions" -H 'Content-Type: application/json' \
      -d '{"model":"gpt-5.6-luna","max_tokens":8,"messages":[{"role":"user","content":"ping"}]}' 2>/dev/null)"
    luna_status="${luna_raw##*$'\n'}"
    luna="${luna_raw%$'\n'*}"
    if printf '%s' "$luna" | grep -q 'auth_unavailable'; then
      need_luna_sidecar=1
      warn "luna auth_unavailable — 업스트림 엔진 구버전 버그, 사이드카(CLIProxyAPI $SIDECAR_VERSION) 설치 예정"
    elif [ "$luna_status" = "200" ] && printf '%s' "$luna" | node -e '
      let raw = "";
      process.stdin.on("data", (chunk) => { raw += chunk; });
      process.stdin.on("end", () => {
        try {
          const data = JSON.parse(raw);
          const choice = Array.isArray(data.choices) ? data.choices[0] : null;
          const content = choice?.message?.content ?? choice?.text;
          process.exit(typeof content === "string" && content.length > 0 ? 0 : 1);
        } catch {
          process.exit(1);
        }
      });
    '; then
      ok "luna 업스트림 도달 (사이드카 불필요)"
    elif [ -z "$luna" ] || [ "$luna_status" = "000" ]; then
      fail "luna 프로브 무응답 — --no-probe로 명시적으로 건너뛰거나 업스트림을 복구하세요"
    else
      fail "luna 프로브 실패(HTTP ${luna_status}) — auth/쿼터/업스트림 상태를 확인하거나 --no-probe 사용"
    fi
  fi

  return "$RC"
}

render() { # $1=template $2=dest (+ 전역 치환변수)
  sed -e "s|{{NODE_BIN}}|$NODE_BIN|g" \
      -e "s|{{REPO_ROOT}}|$REPO_ROOT|g" \
      -e "s|{{HOME}}|$HOME|g" \
      -e "s|{{UPSTREAM}}|$UPSTREAM|g" \
      -e "s|{{UPSTREAM_LUNA}}|$UPSTREAM_LUNA|g" \
      -e "s|{{SIDECAR_PORT}}|$SIDECAR_PORT|g" \
      -e "s|{{SIDECAR_VERSION}}|$SIDECAR_VERSION|g" \
      "$1" > "$2"
}

reload_job() { # $1=plist
  launchctl unload "$1" 2>/dev/null || true
  launchctl load "$1"
}

install_sidecar() {
  arch="$(uname -m)"
  case "$arch" in
    arm64)
      asset="CLIProxyAPI_${SIDECAR_VERSION}_darwin_aarch64.tar.gz"
      expected_sha="$SIDECAR_SHA_ARM64"
      ;;
    x86_64)
      asset="CLIProxyAPI_${SIDECAR_VERSION}_darwin_amd64.tar.gz"
      expected_sha="$SIDECAR_SHA_AMD64"
      ;;
    *) fail "지원하지 않는 아키텍처: $arch"; return 1 ;;
  esac
  url="https://github.com/router-for-me/CLIProxyAPI/releases/download/v${SIDECAR_VERSION}/${asset}"
  tmp="$(mktemp -d)"
  log "사이드카 다운로드: $url"
  curl -fsSL --max-time 120 -o "$tmp/cpap.tar.gz" "$url" || { fail "사이드카 다운로드 실패"; return 1; }
  actual_sha="$(shasum -a 256 "$tmp/cpap.tar.gz" | cut -d ' ' -f 1)"
  if [ "$actual_sha" != "$expected_sha" ]; then
    rm -rf "$tmp"
    fail "사이드카 SHA-256 불일치 — 설치 중단"
    return 1
  fi
  ok "사이드카 SHA-256 검증"
  tar_list="$(tar tzf "$tmp/cpap.tar.gz" 2>/dev/null)" || { fail "사이드카 압축 목록 검증 실패"; return 1; }
  if printf '%s\n' "$tar_list" | grep -Eq '(^|/)\.\.(/|$)|^/'; then
    rm -rf "$tmp"
    fail "사이드카 압축에 안전하지 않은 경로 포함"
    return 1
  fi
  tar xzf "$tmp/cpap.tar.gz" -C "$tmp" || { fail "사이드카 압축해제 실패"; return 1; }
  [ -f "$tmp/cli-proxy-api" ] || { fail "사이드카 바이너리 없음(릴리스 구조 변경?)"; return 1; }
  mkdir -p "$HOME/.local/bin" "$HOME/.cli-proxy-api/logs"
  cp "$tmp/cli-proxy-api" "$HOME/.local/bin/cli-proxy-api-sidecar"
  chmod +x "$HOME/.local/bin/cli-proxy-api-sidecar"
  rm -rf "$tmp"
  render "$REPO_ROOT/install/sidecar-config.yaml.tmpl" "$HOME/.cli-proxy-api/sidecar-config.yaml"
  render "$REPO_ROOT/install/com.solgate.sidecar.plist.tmpl" "$SIDECAR_PLIST"
  reload_job "$SIDECAR_PLIST"
  sleep 4
  if curl -fsS --max-time 8 "http://127.0.0.1:${SIDECAR_PORT}/v1/models" 2>/dev/null | grep -q 'gpt-5.6-luna'; then
    ok "사이드카 가동 (:${SIDECAR_PORT}, luna 노출)"
  else
    fail "사이드카 기동 실패 — ~/.cli-proxy-api/logs/sidecar*.log 확인"
    return 1
  fi
}

do_install() {
  doctor || { log ""; log "doctor FAIL — 위 항목을 해결한 뒤 다시 실행하세요."; exit 1; }
  NODE_BIN="$(command -v node)"

  # 초기 개발판의 개인 launchd label이 남아 있으면 신규 서비스를 먼저 검증한 뒤 제거한다.
  if [ -f "$LEGACY_GATEWAY_PLIST" ] || [ -f "$LEGACY_SIDECAR_PLIST" ]; then
    migration_active=1
    warn "legacy launchd label 감지 — 신규 서비스 검증 후 제거합니다"
  fi

  mkdir -p "$HOME/.solgate/logs" "$LAUNCH_DIR"

  UPSTREAM_LUNA="$UPSTREAM"
  if [ "$need_luna_sidecar" -eq 1 ]; then
    install_sidecar || exit 1
    UPSTREAM_LUNA="http://127.0.0.1:${SIDECAR_PORT}"
  fi

  render "$REPO_ROOT/install/com.solgate.gateway.plist.tmpl" "$GATEWAY_PLIST"
  reload_job "$GATEWAY_PLIST"
  sleep 2
  if curl -fsS --max-time 8 "http://127.0.0.1:${SOLGATE_PORT}/healthz" >/dev/null 2>&1; then
    ok "solgate 가동 (:${SOLGATE_PORT})"
  else
    fail "solgate 기동 실패 — ~/.solgate/logs/launchd.err.log 확인"; exit 1
  fi
  if curl -fsS --max-time 8 "http://127.0.0.1:${SOLGATE_PORT}/v1/models" | grep -q 'gpt-5.6-sol-1m'; then
    ok "가상 1M 모델(gpt-5.6-sol-1m) 노출"
  else
    fail "가상 모델 미노출"; exit 1
  fi

  node "$REPO_ROOT/install/merge-ccr.mjs" --port "$SOLGATE_PORT" || exit 1
  ccr restart >/dev/null 2>&1 || warn "ccr restart 실패 — 수동으로 'ccr restart' 실행 필요"
  sleep 3

  if ! grep -q "$ZSHRC_MARK_BEGIN" "$HOME/.zshrc" 2>/dev/null; then
    {
      printf '\n%s\n' "$ZSHRC_MARK_BEGIN"
      printf 'source "%s/install/solgate.zsh"\n' "$REPO_ROOT"
      printf '%s\n' "$ZSHRC_MARK_END"
    } >> "$HOME/.zshrc"
    ok "~/.zshrc에 vgpt/vgpt1m 함수 블록 추가"
  else
    ok "~/.zshrc 블록 이미 존재 (스킵)"
  fi

  if [ "$NO_PONG" -eq 1 ]; then
    warn "CCR 경유 PONG 스킵(--no-pong)"
  else
    pong="$(curl -sS --max-time 90 http://127.0.0.1:3456/v1/messages \
      -H 'Content-Type: application/json' -H 'x-api-key: local' -H 'anthropic-version: 2023-06-01' \
      -d '{"model":"solgate,gpt-5.6-sol","max_tokens":20,"messages":[{"role":"user","content":"Reply with exactly: SOLGATE-SETUP-PONG"}]}' 2>/dev/null)"
    if printf '%s' "$pong" | grep -q 'SOLGATE-SETUP-PONG'; then
      ok "CCR 풀체인 PONG 성공"
    elif printf '%s' "$pong" | grep -q -e 'usage_limit_reached' -e 'model_cooldown'; then
      ok "체인은 백엔드 도달 (현재 플랜 사용량 한도 — 리셋 후 정상)"
    else
      fail "CCR 풀체인 검증 실패: $(printf '%s' "$pong" | head -c 160)"
      exit 1
    fi
  fi

  if [ "$need_luna_sidecar" -eq 1 ]; then
    luna_pong="$(curl -sS --max-time 60 "http://127.0.0.1:${SOLGATE_PORT}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"model":"gpt-5.6-luna","max_tokens":20,"messages":[{"role":"user","content":"Reply with exactly: LUNA-PONG"}]}' 2>/dev/null)"
    if printf '%s' "$luna_pong" | grep -q 'LUNA-PONG'; then
      ok "신규 gateway 경유 luna PONG 성공"
    elif printf '%s' "$luna_pong" | grep -q -e 'usage_limit_reached' -e 'model_cooldown'; then
      ok "신규 gateway 경유 luna 백엔드 도달 (현재 사용량 한도)"
    else
      fail "신규 gateway 경유 luna 검증 실패"
      exit 1
    fi
  fi

  if [ "$migration_active" -eq 1 ]; then
    launchctl unload "$LEGACY_GATEWAY_PLIST" 2>/dev/null || true
    launchctl unload "$LEGACY_SIDECAR_PLIST" 2>/dev/null || true
    rm -f "$LEGACY_GATEWAY_PLIST" "$LEGACY_SIDECAR_PLIST"
    ok "legacy launchd label을 com.solgate.*로 이전"
  fi
  install_complete=1

  log ""
  log "설치 완료. 새 터미널에서:"
  log "  vgpt            # gpt-5.6-sol[330k]"
  log "  vgpt terra      # gpt-5.6-terra[330k]"
  log "  vgpt luna       # gpt-5.6-luna[330k]"
  log "  vgpt1m          # 가상 1M (롤링 요약)"
  log "  vgpt models     # 도움말"
}

do_uninstall() {
  launchctl unload "$GATEWAY_PLIST" 2>/dev/null || true
  launchctl unload "$SIDECAR_PLIST" 2>/dev/null || true
  launchctl unload "$LEGACY_GATEWAY_PLIST" 2>/dev/null || true
  launchctl unload "$LEGACY_SIDECAR_PLIST" 2>/dev/null || true
  rm -f "$GATEWAY_PLIST" "$SIDECAR_PLIST" "$LEGACY_GATEWAY_PLIST" "$LEGACY_SIDECAR_PLIST"
  if grep -q "$ZSHRC_MARK_BEGIN" "$HOME/.zshrc" 2>/dev/null; then
    sed -i '' "/$ZSHRC_MARK_BEGIN/,/$ZSHRC_MARK_END/d" "$HOME/.zshrc"
  fi
  ok "launchd 잡·zshrc 블록 제거 완료 (바이너리·CCR provider는 보존 — 수동 정리)"
}

case "$CMD" in
  doctor)    doctor; exit "$RC" ;;
  install)   do_install ;;
  uninstall) do_uninstall ;;
  *) echo "usage: ./setup.sh [doctor|install|uninstall] [--upstream URL] [--no-probe] [--no-pong]"; exit 2 ;;
esac
