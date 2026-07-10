# solgate — Session Backlog

> Claude(Fable 5)와의 작업 대화 정본 기록. 세션마다 아래에 append한다.
> 형식: 목표 → 결정 → 증거 → 남은 것. 산문 주장 없이 실측 증거만 기록.

---

## 2026-07-10 — 탄생 세션: "1M 컨텍스트 GPT 프록시를 우리가 만들자"

### 발단

1. 사용자가 VibeProxy에서 "gpt sol" 사용 가능 여부 질문 → `/v1/models`에 없음 실측.
2. codex CLI 0.142.5가 낡아 백엔드가 sol 거부("requires a newer version of Codex" 400) → **0.144.0 업그레이드**로 해결, `codex exec -m gpt-5.6-sol` PONG.
3. VibeProxy(cli-proxy-api-plus 7.2.54)는 모델 목록을 원격 카탈로그
   (`router-for-me/models`의 models.json)에서 시작 시 fetch → **앱 재시작**만으로
   gpt-5.6-sol/terra/luna 노출. E2E "SOL-PONG" 확인.
4. 사용자: "VibeProxy는 200k 한계 아니냐, 직접 프록시 만들자" →
   **288,327 prompt tokens 단일 요청이 VibeProxy를 그대로 통과**(HTTP 200, 6.7s,
   needle 정답)함을 실측. 200k 캡은 VibeProxy가 아니라 클라이언트측
   라벨/캡(zshrc 150k·custom-router 160k)이었음을 증명.

### 물리 팩트 (모든 설계의 전제)

| 모델 | context (input) | max output | 비고 |
|---|---|---|---|
| gpt-5.6-sol | 372,000 | 128,000 | 플래그십, thinking ultra까지 |
| gpt-5.6-terra | 372,000 | 128,000 | 균형 |
| gpt-5.6-luna | 372,000 | 128,000 | 경량 — cli-proxy-api서 auth 불가(SG-001) |
| gpt-5.5 | 272,000 | 128,000 | 레거시 |

어떤 프록시도 모델 실창을 늘릴 수 없다. "1M"은 압축 계층(가상)으로만 가능하며
오래된 턴은 요약본이 된다(무손실 아님). 오픈소스 정찰 결과 투명한 가상 창
프록시 완제품은 없음(에이전트측 compaction / 압축 미들웨어 / SaaS뿐) → 자체 구축 결정.

### 결정 (사용자 선택)

- 가상 1M 프록시 신규 구축 + 물리 372k 배선 즉시 적용 (둘 다)

### Phase 1 — 물리 배선 (완료)

- `~/.zshrc`: `vgpt` 기본 gpt-5.6-sol[330k], per-model cap(`_vgpt_cap_for`), sol/terra/luna/gpt5.5 alias
- `~/.local/bin/vclaude-proxy`: auto-latest 정규식에 코드네임 변형 추가(sol>terra>무접미>luna), cap 330k
- `~/.claude-code-router/custom-router.js`: VIBEPROXY_MODELS + OVERFLOW_LIMITS(sol 계열 330k)
- `~/.claude-code-router/config.json`: provider 모델 추가, Router 기본 sol, longContext=gemini-3-flash@330k
- 증거: 라우터 단위검증(240k→sol / 350k→gemini / 라벨 스트립), CCR e2e `SOL-CCR-PONG`
- 백업: `*.bak-solwire-20260710-082846`

### Phase 2 — solgate 구축 (완료)

- `server.mjs` (Node 24 stdlib 단일 파일): OpenAI 호환, 가상 id `gpt-5.6-sol-1m`(1M 선언),
  300k 초과 시 40k 청크 롤링 요약(terra) + 최근 ~200k 원문 + sha256 디스크 캐시 +
  tools 토큰 차감 + 330k fail-closed ceiling + user 경계 컷(orphan tool 금지)
- launchd `com.voidlight.solgate` KeepAlive, 127.0.0.1:8321 전용
- 배선: CCR provider `solgate` / custom-router SOLGATE_MODELS(우회 제외) / `vgpt1m`→sol-1m[1m]
- HARD 게이트 7종 (`gates/verify_solgate.sh`) 최종 실측:
  - unit 9/9 · service(가상모델 주입+localhost 바인드+launchd) · e2e small(PONG+SSE)
  - **e2e compact: 338k 대화 → 200 OK, needle 정답, prompt_tokens=139,816(<372k), cacheHits 0→11, degraded 0→0**
  - wiring · secrets · no_vertical_stripe 전부 PASS → `VERIFY PASS`
- 풀체인 실측: CCR Anthropic 엔드포인트 → solgate → sol `SOLGATE-CHAIN-PONG`

### 게이트가 잡은 실버그 (FAILURE_LOG SG-001)

첫 게이트는 겉으로 PASS였으나 stats `degraded: 13` — luna 요약 사이드콜이 전부
`auth_unavailable`로 죽고 절단 강등으로 통과했었다. 조치:
① 요약 모델 terra 전환 ② 강등 마커 캐시 저장 금지(영구 오염 차단) ③ 오염 캐시 purge
④ 게이트에 "degraded 증가 = FAIL" 추가 → 재실행 진짜 PASS.

### 사용법

- `vgpt` = 물리 372k (품질 무손실, 일반 작업)
- `vgpt1m` = 가상 1M (초장기 세션, 오래된 턴은 요약)
- 상태: `curl http://127.0.0.1:8321/solgate/stats`

### 남은 것 / 알려진 제약

- luna auth_unavailable 원인(카탈로그 override_header 의심)은 cli-proxy-api 업스트림 이슈 — 추적만 → **같은 날 세션 2에서 해결(아래)**
- 가상 1M의 요약 품질은 세션 종류에 따라 체감 다름 — 장기 사용 후 SUMMARIZER_SYSTEM 프롬프트 튜닝 여지
- gpt-5.5 구실측 "~200k 천장"은 재검증 안 함(카탈로그 272k) — 레거시라 보수 캡 유지

---

## 2026-07-10 (세션 2) — vgpt에서 terra·luna 실사용 개통 + GitHub 공개

### 목표

`vgpt terra` / `vgpt luna` 를 실제 사용 가능하게. + 리포 GitHub 업로드와 세션 백로그 프로세스 확립.

### 진행/증거

1. **GitHub**: `VoidLight00/solgate` PRIVATE 생성, main push 원격 검증(ls-remote 일치).
   세션 백로그 컨벤션(docs/BACKLOG.md append) README에 명문화.
2. **terra**: 배선 이미 완료 상태 + VibeProxy 직결 실측 `TERRA-PONG` — 즉시 사용 가능.
3. **luna 근인 확정(SG-001b)**: codex CLI로는 `LUNA-CLI-PONG` 정상 → 백엔드 문제 아님.
   CLIProxyAPI 소스 확인 결과 plan_type "prolite"는 default→CodexPro 목록(luna 포함)이라
   등록돼야 정상. VibeProxy 내장 7.2.54(07-08 빌드)가 07-09 카탈로그에 추가된 luna의
   `config.override_header` 신필드를 처리 못하는 구버전 버그. 7.2.58(커밋 26d45fd,
   "add model header overrides from configuration")로 격리 인스턴스(:8390) 실측 → auth 통과.
4. **해법 결정**: VibeProxy.app 바이너리 스왑은 권한 분류기가 차단(서명 앱 변조) →
   **사이드카**: `~/.local/bin/cli-proxy-api-sidecar`(7.2.58) + launchd
   `com.voidlight.cpap-sidecar` :8331 + CCR provider `cpapside`(luna만) +
   custom-router `SIDECAR_MODELS`. sol/terra는 기존 VibeProxy 경로 유지.
5. **최종 실측**: CCR 풀체인 luna → `usage_limit_reached`(실 업스트림 429) 도달 =
   auth 매칭 해결 증명. 정상 PONG은 플랜 한도 리셋(~11:37) 후 가능.

### 오늘의 비용 교훈

대형 게이트 실측(288k 프로브 + compact e2e 2회 ≈ 총 1.3M+ input tokens)이 prolite 플랜
사용량 한도를 소진시켜 sol/terra/luna 전체가 ~2.5h 잠김(`model_cooldown`/`usage_limit_reached`).
→ 대형 e2e는 `SOLGATE_SKIP_BIG=1`로 스킵 가능하게 이미 설계돼 있음. 반복 실행 금지,
한도 여유 있는 시간대에만 풀게이트.

### 남은 것

- [ ] 한도 리셋 후 `vgpt luna` 실 PONG 확인 (auth는 이미 증명됨)
- [ ] VibeProxy가 7.2.58+ 엔진을 내장하면 사이드카 제거(custom-router SIDECAR_MODELS 주석 참조)

---

## 2026-07-10 (세션 3) — 쿼터 자동 폴백 + 폴백 문구 노출 (SR12)

### 니즈 확인

사용자 니즈 5겹 정리(최신 모델 즉시 접근 / 세션 불사 / 자가 소유 인프라 / 리던던시·폴백 /
영속 기록) 후, 미충족 항목 "한도 자동 폴백"을 지목 → 사용자 확정: **폴백이 되면
어떤 모델로 폴백됐다는 문구가 반드시 떠야 함**.

### 구현

- solgate에 SR12 폴백 루프: 429·usage_limit_reached·model_cooldown·auth_unavailable →
  체인(sol→terra→luna / terra→luna→sol / luna→terra→sol)으로 재시도.
  성공 시 응답 첫머리에 `[solgate fallback] <from> → <to> (사유, 리셋 ~HH:MM)` 주입
  (stream=합성 첫 SSE 청크, non-stream=content 앞단). 폴백 비대상 에러는 원문 그대로.
- gpt-5.6 물리 3종 라우팅을 solgate 경유로 승격(CCR SOLGATE_FAILOVER), cpapside
  provider 제거 — luna upstream은 solgate 내부 상수(UPSTREAM_LUNA=:8331)로 이동(SR13).
- 요약 사이드콜도 체인 1회 폴백(terra 실패 시 luna).

### 증거

- 모킹 게이트 5/5 (실 토큰 0): non-stream 문구 주입 + 사유 포함 + 실응답 보존 /
  stream 첫 청크 문구 / 비폴백 시 문구 없음 / stats.fallbacks 증가 / 정상 모델 무간섭.
- 라이브 체인 순회: 전 모델 한도 상태에서 sol 요청 →
  로그 `attempted: ['gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna']` 후 최종 429 원문 반환(정답 동작).
- unit_gate PASS / wiring_gate PASS (라우팅 5케이스: sol-1m 500k 유지, 물리 3종 solgate,
  sol 350k → gemini 우회).
- 한도 리셋(+120s) 시점에 자동 검증 백그라운드 잡 예약(3모델 PONG + 마스터 게이트 SKIP_BIG).

### 리셋 후 자동 검증 결과 (11:45, 백그라운드 잡)

- `PONG-gpt-5.6-sol` / `PONG-gpt-5.6-terra` / **`PONG-gpt-5.6-luna`** — 3모델 전부
  CCR 풀체인 실응답. luna 최종 증명 완료(sidecar 경유).
- 마스터 게이트 `VERIFY PASS` (e2e_compact만 SKIP_BIG 명시 스킵 — 한도 재소진 방지).

---

## 2026-07-10 (세션 4) — 서브에이전트 모델 티어 (vgpt 안에서 terra/luna 호출)

### 니즈

vgpt(sol) 세션에서 서브에이전트(Agent/Workflow)가 terra·luna 등 다른 GPT 모델을
쓸 수 있어야 함 — 메인은 sol, 워커는 가볍게.

### 구현

Claude Code 모델 별칭 슬롯(env) 매핑 — `vgpt`/`vgpt1m` (zshrc + vclaude-proxy 4곳):
- `model:"opus"` → `gpt-5.6-sol[330k]` (최상위 판단)
- `model:"sonnet"` → `gpt-5.6-terra[330k]` (범용 워커)
- `model:"haiku"` → `gpt-5.6-luna[330k]` (경량/백그라운드, ANTHROPIC_SMALL_FAST_MODEL 포함)
메인 모델은 `--model` 명시 고정이라 영향 없음. 별칭 요청도 CCR→solgate라 SR12 폴백 적용.

### 증거

- 실제 Claude Code 비대화 세션에서 별칭 해석 실측:
  `claude --model haiku -p` → `TIER-HAIKU-OK` + solgate 로그 `model: gpt-5.6-luna, status: 200`
  `claude --model opus -p` → `TIER-OPUS-OK` + solgate 로그 `model: gpt-5.6-sol, status: 200`
- wiring_gate에 티어 env 배선 검사 추가(zshrc·vclaude-proxy 양쪽 grep) → PASS.
- 신규 셸부터 적용 (기존 셸은 `source ~/.zshrc`).

---

## 2026-07-10 (세션 5) — 원웨이 설치기 + /github 프로페셔널화

### 니즈

다른 사람 PC에서도 GitHub 코드 기반으로 한 커맨드 올바른 세팅. `/github` 하네스로
업로드 품질 개선. 공개범위 질문 결과: **PRIVATE 유지**(collaborator 초대 접근),
/gi 이미지 포함.

### 구현 — 설치기 (`setup.sh` + `install/`)

- `setup.sh doctor|install|uninstall` (macOS·bash 3.2 호환, 멱등):
  doctor(node≥20/claude/ccr/업스트림 gpt-5.6 노출, fail-closed) →
  **luna auth 프로브로 구엔진 버그 자동 감지** → 감지 시 CLIProxyAPI 7.2.58
  사이드카 자동 설치(공식 릴리스, arch별 asset) → solgate launchd
  (`com.solgate.gateway`, 템플릿 렌더: NODE_BIN/REPO_ROOT/HOME/UPSTREAM 치환) →
  `install/merge-ccr.mjs`로 CCR provider **비파괴 머지**(백업 후) →
  zshrc 마커 블록(`# >>> solgate >>>`) → CCR 풀체인 PONG 실측(한도 중이면
  usage_limit 도달도 체인 OK로 인정).
- **이식성 핵심**: 설치판 셸 함수(`install/solgate.zsh`)는 `solgate,<model>`
  provider-prefix 형식 → **custom-router 없이 CCR 내장 라우팅만으로 동작**.
  실측: `PREFIX-PONG` (CCR→solgate→sol 200).
- `gates/install_gate.sh` 신설: 문법 3종 + 템플릿 플레이스홀더/렌더 잔존 0 +
  doctor 실측 exit 0 + 셸함수 모델/캡 해석 스모크. 마스터 게이트 자동 발견(8종째).

### 구현 — /github 파이프라인

- `bin/github init --tier full`: LICENSE(MIT)·CHANGELOG·CITATION·Makefile·
  .github 커뮤니티 세트(SECURITY/SUPPORT/ISSUE/PR/dependabot/CODEOWNERS/workflows)·
  commit-msg 훅(Conventional Commits 강제).
- 템플릿 README가 실내용을 덮어써서 전면 재작성: 실 기능 4종 요약, 실제 Quick Start,
  mermaid 토폴로지, 게이트 안내, 정직성 고지("실창을 늘리지 못한다") 포함.
  이모지 헤더 제거(aislop 톤 룰 우선).
- /gi 이미지: hero(태양 게이트+3티어 궤도+압축 리본, 텍스트 제로) + og(1.91:1 크롭).
  가짜 다이어그램/UI 스크린샷류는 AI 슬롭 위험으로 배제 — 아키텍처는 mermaid 유지.

### 증거

- `bin/github doctor` P0=0 P1=0 P2=0 P3=0 PASS / `bin/github qa` publish-ready PASS
- 마스터 게이트 8서브게이트 `VERIFY PASS` (SOLGATE_SKIP_BIG=1)
- PREFIX-PONG(제네릭 라우팅) + install_gate PASS 실측
