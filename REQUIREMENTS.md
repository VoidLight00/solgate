# solgate — Requirements (SSoT)

> 단일 진실. 게이트는 이 표의 각 SR을 exit code로 검증한다.
>
> solgate = GPT-6 Astra와 GPT-5.6 sol/terra/luna 각각 위에 **가상 1M 컨텍스트**를 만드는 로컬 프록시.
> 초과분은 profile별 다른 물리 모델로 청크 롤링 요약하고, 최근 구간은 원문 유지.
> 물리 법칙: 어떤 프록시도 모델 실창을 못 늘린다 — 이건 압축 계층이지 마법이 아니다.
> 오래된 턴은 요약본이 된다(무손실 아님).

## 토폴로지

```
Claude Code(astra-1m / sol-1m / terra-1m / luna-1m, 라벨 [1m])
  → CCR :3456 (Anthropic→OpenAI 변환)
  → solgate :8321 (이 프로젝트 — 압축 계층)
  → profile physical base: gpt-6-astra / gpt-5.6-sol / terra / luna
요약 사이드콜: base와 다른 물리 모델 후보를 순서대로 사용(virtual ID·self-call 금지)
```

## 요구사항

| id | requirement | gate |
|---|---|---|
| SR1 | OpenAI 호환 `/v1/chat/completions` 프록시 (stream/non-stream 모두 바이트 패스스루) | e2e_small_gate.sh |
| SR2 | `/v1/models`에 `gpt-6-astra-1m` 및 `gpt-5.6-{sol,terra,luna}-1m` 4종(context_length 1000000)을 중복 없이 주입하고 upstream 목록 보존. 설명은 profile별 요약 시작 추정치를 표시 | service_gate.sh + unit_gate.sh |
| SR3 | messages·tools 합계 추정 토큰이 profile별 COMPACT_TRIGGER 이하이고 해당 상한 이내인 요청은 messages 무변형 패스스루 | unit_gate.sh |
| SR4 | 기존 GPT-5.6 가상 profile은 추정 300k 초과에서 압축하고 최근 ~200k를 유지. Astra 가상 profile은 추정 220k 초과에서 압축하고 최근 ~140k 유지. 오래된 구간은 ~40k 청크로 나누어 base와 다른 물리 summary 후보로 요약. summary에는 virtual ID와 base self-call 금지 | unit_gate.sh + e2e_compact_gate.sh(기존 Sol live) |
| SR5 | 가상 profile의 압축 후 최종 추정 ≤ 해당 HARD_CEILING 보장(Astra 240k, 기존 GPT-5.6 330k; 더 작은 전역값 우선). 요약 실패 시 결정론 절단으로 강등(세션 생존) — 해당 profile 상한 초과 전송 금지. user 경계 소진 시에도 fail-closed(본문 비율 절단→앞절단). 업스트림 400 `context_too_large` 시 직전 실제 전송 추정치의 0.7배로 최대 3회 재압축하고, 실제 크기가 줄지 않으면 즉시 원래 오류를 반환(SG-003) | unit_gate.sh(+ctxretry/ctxwindow e2e) |
| SR6 | 청크 요약 캐시: sha256 키, 메모리+디스크(`~/.solgate/cache`) persist. 같은 prefix 재요약 금지 (2회차 요청 cacheHits 증가) | e2e_compact_gate.sh |
| SR7 | 컷/청크 경계 프로토콜 무결성: 원문 유지 구간은 반드시 user 메시지로 시작(orphan tool 메시지·끊긴 tool_call 쌍 금지). leading system 메시지는 항상 원문 유지 | unit_gate.sh |
| SR8 | 로그(`~/.solgate/logs`)에 대화 원문 저장 금지 — 메타데이터(추정치·청크수·캐시히트·상태코드)만 | unit_gate.sh(grep) + secrets_gate.sh |
| SR9 | 127.0.0.1 바인드 전용 + launchd 상주(`com.solgate.gateway`) | service_gate.sh |
| SR10 | 토큰 추정은 CJK 인식(한글≈1tok/char, 기타≈1/3.6) — 한국어 과소추정으로 천장 초과 금지 | unit_gate.sh |
| SR11 | CCR provider에 물리 4종+가상 4종 총 8개 모델 배선. 기존 Sol 기본값과 sol/terra/luna picker 호환 유지. `vgpt astra`는 Astra `[240k]`와 명시적 `--autocompact 220k`(사용자 옵션보다 앞), `vgpt astra1m` 및 `vgpt1m astra`는 Astra 가상 `[1m]`. Astra 선택은 메인 모델만 바꾸며 Opus=Sol·Sonnet=Terra·Haiku=Luna 분담은 유지. 각 슬롯은 물리 세션이면 물리 profile, 가상 세션이면 가상 profile 사용 | wiring_gate.sh + install_gate.sh |
| SR12 | 쿼터/한도 자동 폴백: 429·usage_limit_reached·model_cooldown·auth_unavailable 시 sol은 terra→luna, luna는 terra→sol 순으로 전환하고 응답 첫머리에 `[solgate fallback] <from> → <to> (사유, 리셋시각)` 문구를 주입(stream/non-stream 모두). 명시적 worker route인 terra는 sticky라 다른 모델로 자동 전환하지 않는다. 폴백 불가 에러는 그대로 반환. gpt-5.6 물리 3종도 solgate 경유 | unit_gate.sh(tests/fallback.e2e.test.mjs, mock) + wiring_gate.sh |
| SR13 | luna upstream은 기본적으로 주 업스트림을 사용한다. 구버전 엔진의 luna `auth_unavailable` 버그가 감지될 때만 setup이 검증된 CLIProxyAPI 사이드카(:8331)를 설치하고 `SOLGATE_UPSTREAM_LUNA`로 분리한다. 주 엔진이 수정되면 별도 사이드카 없이 자동 설치 | install_gate.sh + service_gate.sh |
| SR14 | Astra 물리/가상 base 고정: 429 등 오류를 다른 모델로 숨기지 않음. Astra 가상 profile에만 COMPACT_TRIGGER 220k, KEEP_RECENT 140k, HARD_CEILING 240k를 적용하며 더 작은 전역 값은 보존. tools 추정치도 상한에서 차감. summaryCandidates는 terra/luna. 기존 모델 설정 불변. Astra 경계 검증은 localhost mock이며 라이브 대형 문맥 지원을 증명하지 않음 | unit_gate.sh(tests/astra-boundaries.e2e.test.mjs + virtual-models + unit) |

## 상수 (server.mjs 상단, env 오버라이드 가능)

| 이름 | 값 | 근거 |
|---|---|---|
| PORT | 8321 | 로컬 미사용 포트 |
| UPSTREAM | http://127.0.0.1:8317 | VibeProxy |
| UPSTREAM_MODEL | gpt-5.6-sol | 실모델 |
| VIRTUAL_CONTEXT | 1000000 | 네 가상 profile의 공개 컨텍스트 선언 |
| SUMMARY_POLICY | astra→terra/luna, sol→terra/luna, terra→luna/sol, luna→terra/sol | base self-call·virtual recursion 방지 |
| HARD_CEILING | 330000 | 실창 372k − 헤드룸 (2026-07-10 288k 단건 실측 통과) |
| COMPACT_TRIGGER | 300000 | 이하 무변형 |
| KEEP_RECENT | 200000 | 최근 원문 예산 |
| CHUNK_TOKENS | 40000 | 요약 청크 크기 |
| SUMMARY_BUDGET | 60000 | profile summary 합계 초과 시 같은 summary 후보 정책으로 계층 재요약 |

Astra 가상 profile은 위 전역값과 자체 한도(트리거 220000, 최근 140000, 상한 240000) 중 각각 작은 값을 사용한다. 로컬 Codex 메타데이터의 기본 `context_window=272000`과 `max_context_window=872000`은 관측값이며 이 OAuth 경로의 확장 창 작동 증명이 아니다. 토큰 계산은 문자 기반 추정으로 실제 토크나이저와 다르다. 240k는 추정 전송 예산이고 실제 입력 길이·도구 정의·출력 예산에 따라 upstream이 거부할 수 있다. 기존 `context_too_large` 재압축 재시도를 유지하며, 무손실 1M이나 특정 물리 창을 보장하지 않는다.

## 실패 모드 정책

- 요약 사이드콜 실패: 1회 재시도 → 실패 시 해당 청크를 결정론 절단(`[earlier context unavailable: N messages dropped]` 마커)으로 강등. 세션은 살리고 stats.degraded 카운트. (ponytail: 가용성 우선, 천장 초과 전송만 절대 금지)
- upstream 5xx/네트워크: 그대로 패스스루(우리가 삼키지 않음).
