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
