# solgate 제네릭 셸 함수 — setup.sh가 ~/.zshrc에 source 라인을 추가한다.
# 개인 환경 의존(cmux 래퍼, 커스텀 auth-fix 등) 없이 claude CLI만 사용하는 이식판이다.
# 요구: claude(Claude Code CLI), ccr(claude-code-router, :3456), solgate(:8321)

_solgate_model_id() {
  local input="${1:l}"
  case "$input" in
    ""|gpt|sol|gpt5.6|gpt-5.6|gpt56|gpt-5.6-sol) print -r -- "gpt-5.6-sol" ;;
    1m|sol1m|sol-1m|gpt-5.6-sol-1m)              print -r -- "gpt-5.6-sol-1m" ;;
    terra1m|terra-1m|gpt-5.6-terra-1m)             print -r -- "gpt-5.6-terra-1m" ;;
    luna1m|luna-1m|gpt-5.6-luna-1m)                print -r -- "gpt-5.6-luna-1m" ;;
    terra|gpt-5.6-terra)                            print -r -- "gpt-5.6-terra" ;;
    luna|gpt-5.6-luna)                            print -r -- "gpt-5.6-luna" ;;
    gpt5.5|gpt-5.5|gpt55)                         print -r -- "gpt-5.5" ;;
    *) return 1 ;;
  esac
}

_solgate_cap_for() {
  case "$1" in
    gpt-5.6-*-1m) print -r -- "1m" ;;    # 가상 1M — solgate가 압축 소유
    gpt-5.6-*)    print -r -- "330k" ;;  # 실창 372k − 헤드룸
    *)              print -r -- "150k" ;;
  esac
}

_solgate_claude() {
  # 모델명은 "solgate,<model>" provider-prefix 형식 — CCR custom-router 없이도
  # CCR 내장 라우팅으로 solgate provider에 직행한다 (타 머신 이식성 핵심).
  local model="$1"; shift
  local cap
  cap="$(_solgate_cap_for "$model")"
  ANTHROPIC_BASE_URL="http://127.0.0.1:3456" \
  ANTHROPIC_API_KEY="local" \
  ANTHROPIC_AUTH_TOKEN="test" \
  ANTHROPIC_MODEL="solgate,${model}[${cap}]" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="solgate,gpt-5.6-terra[330k]" \
  ANTHROPIC_DEFAULT_SONNET_MODEL_NAME="gpt-5.6-terra (subagent worker)" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="solgate,gpt-5.6-sol[330k]" \
  ANTHROPIC_DEFAULT_OPUS_MODEL_NAME="gpt-5.6-sol (top tier)" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="solgate,gpt-5.6-luna[330k]" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME="gpt-5.6-luna (light/background)" \
  ANTHROPIC_SMALL_FAST_MODEL="solgate,gpt-5.6-luna[330k]" \
  claude --model "solgate,${model}[${cap}]" "$@"
}

# vgpt [sol|terra|luna|gpt5.5] — 물리 컨텍스트 세션 (기본 gpt-5.6-sol[330k])
vgpt() {
  local model
  if [[ "${1:l}" == "models" || "$1" == "--models" ]]; then vgpt-models; return 0; fi
  if [[ -n "$1" && "$1" != -* ]]; then
    model="$(_solgate_model_id "$1")" || { print -u2 -- "vgpt: unknown model '$1' (sol/terra/luna/sol1m/terra1m/luna1m/gpt5.5)"; return 2; }
    shift
  else
    model="gpt-5.6-sol"
  fi
  _solgate_claude "$model" "$@"
}

# vgpt1m — 가상 1M 세션 (solgate가 300k 초과분을 롤링 요약)
vgpt1m() {
  _solgate_claude "gpt-5.6-sol-1m" "$@"
}

vgpt-models() {
  cat <<'EOF'
solgate GPT models ([Nk] = auto-compact 시점 선언, 하드정지 아님):
  vgpt            → gpt-5.6-sol[330k]    실창 372k, 한도 시 terra→luna 자동 폴백+문구
  vgpt terra      → gpt-5.6-terra[330k]
  vgpt luna       → gpt-5.6-luna[330k]
  vgpt 1m / vgpt1m → gpt-5.6-sol-1m[1m]    sol 기반 가상 1M
  vgpt terra1m     → gpt-5.6-terra-1m[1m]  terra 기반 가상 1M (main route sticky)
  vgpt luna1m      → gpt-5.6-luna-1m[1m]   luna 기반 가상 1M
세션 중 전환: /model solgate,gpt-5.6-terra-1m[1m] 등
세 가상 1M 모두 300k 초과분 롤링 요약(무손실 아님) + context-too-large 재압축 적용
서브에이전트 티어: model:"opus"=sol, "sonnet"=terra, "haiku"=luna
상태: curl http://127.0.0.1:8321/solgate/stats
EOF
}
