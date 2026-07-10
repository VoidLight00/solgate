# solgate — Failure Log

> 실패할 때마다 1행. 같은 실패 재발 방지용 게이트를 추가하고 여기 기록.

| date | id | symptom | root cause | fix | gate added |
|---|---|---|---|---|---|
| 2026-07-10 | SG-001 | compact 게이트 PASS인데 stats.degraded=13 — 요약이 전부 절단 마커로 강등된 채 통과 | ① gpt-5.6-luna가 cli-proxy-api 7.2.54에서 `auth_unavailable`(sol·terra는 정상 — luna 카탈로그 override_header 특수처리 의심) ② 강등 마커를 캐시에 저장해 실패가 영구 오염 ③ 게이트가 degraded를 안 봄 | SUMMARY_MODEL 기본값 terra로 전환 + 강등 마커 캐시 저장 금지 + 오염 캐시 purge | e2e_compact_gate.sh에 degraded 증가 = FAIL 추가 |
| 2026-07-10 | SG-001b | (SG-001 근인 확정) luna `auth_unavailable`은 VibeProxy 내장 엔진 7.2.54의 구버전 버그 — 카탈로그의 luna `config.override_header`(07-09 추가)를 처리 못함. 7.2.58(커밋 26d45fd)에서 수정 확인(격리 인스턴스 :8390 실측 — auth 통과, 실 업스트림 응답 도달) | VibeProxy 앱 바이너리는 수정하지 않고(서명 무결성) CLIProxyAPI 7.2.58 사이드카 `com.voidlight.cpap-sidecar` :8331 상주 + CCR provider `cpapside`로 luna만 라우팅. VibeProxy 엔진 7.2.58+ 내장 시 사이드카 제거 | 배선은 wiring 정신으로 custom-router SIDECAR_MODELS 주석에 회수 조건 명시. solgate 요약 모델은 terra 유지(solgate upstream=8317 구엔진이라 luna 불가) |
