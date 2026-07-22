# solgate — Requirements (SSoT)

> 단일 진실. 게이트는 이 표의 각 SR을 exit code로 검증한다.
>
> solgate = gpt-5.6-sol(실창 372k input) 위에 **가상 1M 컨텍스트**를 만드는 로컬 프록시.
> 초과분은 청크 롤링 요약(gpt-5.6-luna)으로 접고, 최근 구간은 원문 유지.
> 물리 법칙: 어떤 프록시도 모델 실창을 못 늘린다 — 이건 압축 계층이지 마법이 아니다.
> 오래된 턴은 요약본이 된다(무손실 아님).

## 토폴로지

```
Claude Code(vgpt1m, 라벨 [1m])
  → CCR :3456 (Anthropic→OpenAI 변환)
  → solgate :8321 (이 프로젝트 — 압축 계층)
  → VibeProxy :8317 (ChatGPT OAuth)
  → gpt-5.6-sol (실창 372k)
요약 사이드콜: solgate → VibeProxy :8317 → gpt-5.6-luna
```

## 요구사항

| id | requirement | gate |
|---|---|---|
| SR1 | OpenAI 호환 `/v1/chat/completions` 프록시 (stream/non-stream 모두 바이트 패스스루) | e2e_small_gate.sh |
| SR2 | `/v1/models`에 가상 모델 `gpt-5.6-sol-1m`(context_length 1000000) 주입, upstream 목록 보존 | service_gate.sh |
| SR3 | 추정 토큰 ≤ COMPACT_TRIGGER(300k) 요청은 messages 무변형 패스스루 | unit_gate.sh |
| SR4 | 추정 토큰 > 300k 요청은 자동 압축: 오래된 구간을 ~40k 청크로 나눠 luna 요약, 최근 ~200k 원문 유지 | unit_gate.sh + e2e_compact_gate.sh |
| SR5 | 압축 후 최종 추정 ≤ HARD_CEILING(330k) 보장. 요약 실패 시 결정론 절단으로 강등(세션 생존) — 330k 초과 전송은 어떤 경로로도 금지. user 경계 소진 시에도 fail-closed(본문 비율 절단→앞절단). 업스트림 400 `context_too_large` 시 직전 실제 전송 추정치의 0.7배로 최대 3회 재압축하고, 실제 크기가 줄지 않으면 즉시 원래 오류를 반환(SG-003) | unit_gate.sh(+ctxretry/ctxwindow e2e) |
| SR6 | 청크 요약 캐시: sha256 키, 메모리+디스크(`~/.solgate/cache`) persist. 같은 prefix 재요약 금지 (2회차 요청 cacheHits 증가) | e2e_compact_gate.sh |
| SR7 | 컷/청크 경계 프로토콜 무결성: 원문 유지 구간은 반드시 user 메시지로 시작(orphan tool 메시지·끊긴 tool_call 쌍 금지). leading system 메시지는 항상 원문 유지 | unit_gate.sh |
| SR8 | 로그(`~/.solgate/logs`)에 대화 원문 저장 금지 — 메타데이터(추정치·청크수·캐시히트·상태코드)만 | unit_gate.sh(grep) + secrets_gate.sh |
| SR9 | 127.0.0.1 바인드 전용 + launchd 상주(`com.solgate.gateway`) | service_gate.sh |
| SR10 | 토큰 추정은 CJK 인식(한글≈1tok/char, 기타≈1/3.6) — 한국어 과소추정으로 천장 초과 금지 | unit_gate.sh |
| SR11 | CCR provider `solgate` + zshrc `vgpt1m` → `gpt-5.6-sol-1m[1m]` 배선 | wiring_gate.sh |
| SR12 | 쿼터/한도 자동 폴백: 429·usage_limit_reached·model_cooldown·auth_unavailable 시 sol은 terra→luna, luna는 terra→sol 순으로 전환하고 응답 첫머리에 `[solgate fallback] <from> → <to> (사유, 리셋시각)` 문구를 주입(stream/non-stream 모두). 명시적 worker route인 terra는 sticky라 다른 모델로 자동 전환하지 않는다. 폴백 불가 에러는 그대로 반환. gpt-5.6 물리 3종도 solgate 경유 | unit_gate.sh(tests/fallback.e2e.test.mjs, mock) + wiring_gate.sh |
| SR13 | luna upstream은 기본적으로 주 업스트림을 사용한다. 구버전 엔진의 luna `auth_unavailable` 버그가 감지될 때만 setup이 검증된 CLIProxyAPI 사이드카(:8331)를 설치하고 `SOLGATE_UPSTREAM_LUNA`로 분리한다. 주 엔진이 수정되면 별도 사이드카 없이 자동 설치 | install_gate.sh + service_gate.sh |

## 상수 (server.mjs 상단, env 오버라이드 가능)

| 이름 | 값 | 근거 |
|---|---|---|
| PORT | 8321 | 로컬 미사용 포트 |
| UPSTREAM | http://127.0.0.1:8317 | VibeProxy |
| UPSTREAM_MODEL | gpt-5.6-sol | 실모델 |
| VIRTUAL_ID | gpt-5.6-sol-1m | 노출 id |
| HARD_CEILING | 330000 | 실창 372k − 헤드룸 (2026-07-10 288k 단건 실측 통과) |
| COMPACT_TRIGGER | 300000 | 이하 무변형 |
| KEEP_RECENT | 200000 | 최근 원문 예산 |
| CHUNK_TOKENS | 40000 | 요약 청크 크기 |
| SUMMARY_MODEL | gpt-5.6-luna | 빠른 요약 사이드콜 |
| SUMMARY_BUDGET | 60000 | 요약 합계 초과 시 계층 재요약 |

## 실패 모드 정책

- 요약 사이드콜 실패: 1회 재시도 → 실패 시 해당 청크를 결정론 절단(`[earlier context unavailable: N messages dropped]` 마커)으로 강등. 세션은 살리고 stats.degraded 카운트. (ponytail: 가용성 우선, 천장 초과 전송만 절대 금지)
- upstream 5xx/네트워크: 그대로 패스스루(우리가 삼키지 않음).
