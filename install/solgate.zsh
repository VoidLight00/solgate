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
  local opus_model="solgate,gpt-5.6-sol[330k]"
  local sonnet_model="solgate,gpt-5.6-terra[330k]"
  local haiku_model="solgate,gpt-5.6-luna[330k]"
  local opus_name="GPT-5.6 Sol (physical 330k)"
  local sonnet_name="GPT-5.6 Terra (physical 330k)"
  local haiku_name="GPT-5.6 Luna (physical 330k)"
  if [[ "$model" == gpt-5.6-*-1m ]]; then
    opus_model="solgate,gpt-5.6-sol-1m[1m]"
    sonnet_model="solgate,gpt-5.6-terra-1m[1m]"
    haiku_model="solgate,gpt-5.6-luna-1m[1m]"
    opus_name="GPT-5.6 Sol 1M (rolling context)"
    sonnet_name="GPT-5.6 Terra 1M (rolling context, sticky)"
    haiku_name="GPT-5.6 Luna 1M (rolling context)"
  fi
  ANTHROPIC_BASE_URL="http://127.0.0.1:3456" \
  ANTHROPIC_API_KEY="local" \
  ANTHROPIC_AUTH_TOKEN="test" \
  ANTHROPIC_MODEL="solgate,${model}[${cap}]" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$sonnet_model" \
  ANTHROPIC_DEFAULT_SONNET_MODEL_NAME="$sonnet_name" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$opus_model" \
  ANTHROPIC_DEFAULT_OPUS_MODEL_NAME="$opus_name" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku_model" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME="$haiku_name" \
  ANTHROPIC_SMALL_FAST_MODEL="$haiku_model" \
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
세션 중 `/model` picker:

- `vgpt`: Sol/Terra/Luna 물리 `[330k]` 슬롯
- `vgpt1m`: Sol 1M/Terra 1M/Luna 1M `[1m]` 슬롯
- 직접 지정: `/model solgate,gpt-5.6-terra-1m[1m]`

`[1m]`은 virtual profile의 auto-compact 선언이며 물리 창 확장이 아니다.
서브에이전트 티어: model:"opus"=sol, "sonnet"=terra, "haiku"=luna
상태: curl http://127.0.0.1:8321/solgate/stats
EOF
}
