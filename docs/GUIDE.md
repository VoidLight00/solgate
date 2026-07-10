# GPT-5.6 풀스택 게이트웨이 구축 방법서 (정본)

> ChatGPT 구독(OAuth) 기반으로 Claude Code에서 gpt-5.6 sol/terra/luna를
> 풀컨텍스트·자동폴백·서브에이전트 티어까지 쓰는 전체 방법의 정본 문서다.
> 시간순 작업 기록은 `BACKLOG.md`, 요구사항 SSoT는 `../REQUIREMENTS.md`.
> 작성: 2026-07-10, 검증 증거는 각 절에 명시.

## 1. 전체 토폴로지

```
터미널 (vgpt / vgpt1m / vgpt terra / vgpt luna)
  │  Claude Code (--model 명시 + [Nk] 라벨 = auto-compact 시점)
  ▼
CCR :3456 (claude-code-router, Anthropic↔OpenAI 변환 + custom-router.js 라우팅)
  │
  ├─ gpt-5.6-sol / terra / luna ──────► solgate :8321  ─┬─► VibeProxy :8317 (sol/terra)
  │   (SOLGATE_FAILOVER: 한도 시                        └─► cpap-sidecar :8331 (luna)
  │    체인 폴백 + 응답에 문구 주입)                          │
  ├─ gpt-5.6-sol-1m ────────────────► solgate :8321        │ ChatGPT OAuth (codex provider)
  │   (SOLGATE_ALWAYS: 300k 초과분                          ▼
  │    luna/terra 롤링 요약 = 가상 1M)                   chatgpt.com backend
  ├─ >330k 요청 ─────────────────────► vibeproxy,gemini-3-flash (장문맥 우회)
  └─ 기타 모델(gemini/glm/gpt-5.5) ──► VibeProxy :8318 (Anthropic passthrough)
```

핵심 물리 팩트 (2026-07-10 실측):
- gpt-5.6 sol/terra/luna 실창 = **input 372k + output 128k** (gpt-5.5는 272k)
- VibeProxy는 자체 컨텍스트 캡이 없다 — 288,327 토큰 단일 요청 통과 실측
- 200k "한계"의 실체는 클라이언트측 `[Nk]` 라벨/캡. 라벨은 Claude Code가
  API 호출 전에 떼며(auto-compact 시점 선언), 실창보다 낮게 선언하면 세션이
  compact-and-continue로 영원히 산다
- 어떤 프록시도 모델 실창을 늘릴 수 없다 — "1M"은 압축 계층(가상)이며
  오래된 턴은 요약본이 된다(무손실 아님)

## 2. 구성요소와 역할

| 구성요소 | 위치 | 역할 |
|---|---|---|
| codex CLI ≥0.144 | npm `@openai/codex` (nvm) | 백엔드가 클라이언트 버전으로 모델 게이트 — 낡으면 "requires a newer version of Codex" 400 |
| VibeProxy 1.8.224 | /Applications (내장 cli-proxy-api-plus 7.2.54) | ChatGPT OAuth → OpenAI/Anthropic 호환 API (:8317/:8318). 모델 목록은 시작 시 원격 카탈로그(router-for-me/models) fetch — **새 모델은 앱 재시작으로 노출** |
| cpap-sidecar | `~/.local/bin/cli-proxy-api-sidecar` (7.2.58) + launchd `com.voidlight.cpap-sidecar` :8331 | 내장 7.2.54의 luna auth 매칭 버그(SG-001b) 우회 전용. **회수 조건: VibeProxy가 7.2.58+ 내장하면 solgate의 `SOLGATE_UPSTREAM_LUNA`를 8317로 되돌리고 launchd unload** |
| solgate | `~/projects/solgate/server.mjs` + launchd `com.voidlight.solgate` :8321 | ① 가상 1M(300k 초과분 청크 롤링 요약+캐시) ② 쿼터 자동 폴백+문구 주입 ③ luna→sidecar 업스트림 선택 |
| CCR | `~/.claude-code-router/{config.json,custom-router.js}` :3456 | Anthropic↔OpenAI 변환. custom-router가 모델명→provider 결정(solgate/vibeproxy/gemini 우회) |
| 래퍼 | `~/.zshrc` (vgpt/vgpt1m) + `~/.local/bin/vclaude-proxy` | 모델·캡 선택, 서브에이전트 티어 env, OAuth 자가치유(vgpt-auth-fix) |

## 3. 사용법

### 세션 시작

```bash
vgpt              # gpt-5.6-sol[330k] — 물리 풀컨텍스트, 품질 무손실
vgpt terra        # gpt-5.6-terra[330k]
vgpt luna         # gpt-5.6-luna[330k]
vgpt gpt5.5       # 레거시 [150k]
vgpt1m            # gpt-5.6-sol-1m[1m] — 가상 1M (300k 초과분 자동 요약)
```

### 세션 중 모델 전환 (슬래시)

```
/model gpt-5.6-sol[330k]
/model gpt-5.6-terra[330k]
/model gpt-5.6-luna[330k]
```
`/model` 피커의 슬롯도 티어 매핑됨(Opus=sol, Sonnet=terra, Haiku=luna).
`[330k]` 라벨을 빼면 기본 200k 가정으로 돌아가므로 항상 붙인다.

### 서브에이전트 티어 (Agent/Workflow)

vgpt/vgpt1m 세션 안에서 별칭이 다음으로 풀린다:

| 별칭 | 실모델 | 용도 |
|---|---|---|
| `model: "opus"` | gpt-5.6-sol[330k] | 최상위 판단·아키텍처 |
| `model: "sonnet"` | gpt-5.6-terra[330k] | 범용 워커 |
| `model: "haiku"` | gpt-5.6-luna[330k] | 경량·백그라운드 (SMALL_FAST 포함) |

커스텀 에이전트(`~/.claude/agents/*.md`)의 `model:` frontmatter도 같은 별칭 사용.
메인 세션 모델은 `--model` 명시라 티어 env의 영향을 받지 않는다.

### 자동 폴백

한도(429/usage_limit_reached/model_cooldown/auth_unavailable) 시 solgate가
체인(sol→terra→luna, terra→luna→sol, luna→terra→sol)으로 갈아타고
응답 첫머리에 문구를 주입한다:

```
[solgate fallback] gpt-5.6-sol → gpt-5.6-terra (gpt-5.6-sol: usage_limit_reached, gpt-5.6-sol 리셋 ~11:42)
```

체인 전체가 죽으면 마지막 에러를 원문 그대로 반환한다(숨기지 않음).
플랜(prolite) 사용량 한도는 sol/terra/luna 공유 — 대형 테스트 반복 실행 금지.

### 상태 확인

```bash
curl http://127.0.0.1:8321/solgate/stats   # requests/compactions/cacheHits/fallbacks/degraded
tail ~/.solgate/logs/solgate.log            # 요청별 메타 (원문은 기록 안 함)
curl http://127.0.0.1:8317/v1/models        # VibeProxy 모델 목록
curl http://127.0.0.1:8331/v1/models        # sidecar 모델 목록
```

## 4. 처음부터 재현 (새 머신)

### 원웨이 자동 설치 (권장)

전제: macOS + Node 20+ + Claude Code CLI + claude-code-router(`ccr`) +
VibeProxy(ChatGPT OAuth 로그인 완료). 그 다음 한 커맨드:

```bash
git clone https://github.com/VoidLight00/solgate.git ~/projects/solgate
cd ~/projects/solgate && ./setup.sh install
```

setup.sh가 하는 일: doctor(전제조건 fail-closed 검증) → luna auth 프로브(구엔진
버그 감지 시 사이드카 자동 설치) → solgate launchd 상주 → CCR provider 비파괴
머지 → zshrc 함수 블록 추가 → CCR 풀체인 PONG 실측. 상태 점검만 하려면
`./setup.sh doctor`, 제거는 `./setup.sh uninstall`.

설치판 셸 함수(install/solgate.zsh)는 `solgate,<model>` provider-prefix 형식을
써서 **custom-router 없이 CCR 내장 라우팅만으로 동작**한다(이식성 핵심,
PREFIX-PONG 실측). 아래는 수동 재현 절차다.

### 수동 재현

1. **codex CLI 최신화**: `npm install -g @openai/codex@latest` → `codex exec -m gpt-5.6-sol "PONG"` 확인
2. **VibeProxy** 설치·OAuth 로그인 → 새 모델 안 보이면 앱 재시작(원격 카탈로그 재fetch)
3. **sidecar** (luna 버그가 있는 엔진일 때만): 공식 릴리스 darwin_aarch64 →
   `~/.local/bin/cli-proxy-api-sidecar`, config `~/.cli-proxy-api/sidecar-config.yaml`(port 8331,
   auth-dir 공유), launchd plist 로드
4. **solgate**: 이 리포 clone → launchd `com.voidlight.solgate` 로드 →
   `bash gates/verify_solgate.sh ~/projects/solgate` (평시엔 `SOLGATE_SKIP_BIG=1`)
5. **CCR**: config.json에 provider `solgate`(:8321, models 4종) 추가,
   custom-router.js에 SOLGATE_ALWAYS/SOLGATE_FAILOVER/OVERFLOW_LIMITS 반영 → `ccr restart`
6. **래퍼**: zshrc vgpt/vgpt1m(모델 alias·캡·티어 env), vclaude-proxy 동일 반영
7. **검증**: `bash gates/verify_solgate.sh` exit 0 + CCR 경유 3모델 PONG

수정 파일 전체 인벤토리(백업 규칙 `*.bak-solwire-*`):
`~/.zshrc` · `~/.local/bin/vclaude-proxy` · `~/.claude-code-router/config.json` ·
`~/.claude-code-router/custom-router.js` · `~/.cli-proxy-api/sidecar-config.yaml` ·
`~/Library/LaunchAgents/com.voidlight.{solgate,cpap-sidecar}.plist`

## 5. 트러블슈팅

| 증상 | 원인 | 조치 |
|---|---|---|
| `requires a newer version of Codex` 400 | codex CLI 구버전 | `npm i -g @openai/codex@latest` |
| `unknown provider for model X` | VibeProxy 카탈로그 낡음 | VibeProxy 재시작 |
| `auth_unavailable ... model=<m>` (특정 모델만) | 프록시 엔진의 모델-auth 매칭 버그 | codex CLI로 교차확인 → CLI가 되면 엔진 문제. 최신 릴리스 격리 인스턴스로 검증 후 sidecar |
| `model_cooldown` / `usage_limit_reached` | 플랜 사용량 한도 | 자동 폴백이 처리. 전 모델 소진이면 리셋 대기(에러에 resets_in_seconds) |
| `no auth (providers=codex)` 전 모델 | codex 토큰 로테이션 | `~/bin/vgpt-auth-fix` (vgpt가 자동 실행) |
| 세션이 컨텍스트 한계에서 죽음 | `[Nk]` 라벨이 실창보다 높음 | 라벨을 실창 아래로(sol 330k) — auto-compact이 먼저 발동 |
| 가상 1M 요약 품질 저하 | 요약 프롬프트/청크 크기 | server.mjs `SUMMARIZER_SYSTEM`·`CHUNK_TOKENS` 튜닝, stats.degraded 확인 |

## 6. 설계 원칙 (이 방법의 뼈대)

1. **선언≠증거** — 모든 "된다"는 exit code·PONG·로그로만 판정 (HARD 게이트 7종)
2. **fail-closed 천장** — 어떤 경로로도 실창(372k) 초과 전송 금지, 초과분은 요약/절단
3. **앱 무변조** — 서명된 앱 바이너리는 건드리지 않고 사이드카/자체 레이어로 우회
4. **폴백은 보이게** — 자동 전환은 하되 어떤 모델로 갔는지 문구로 반드시 노출
5. **회수 조건 명시** — 임시 우회(sidecar)는 제거 조건을 코드 주석과 문서에 박아둔다
6. **기록 영속** — 세션마다 BACKLOG.md append, 실패는 FAILURE_LOG.md
