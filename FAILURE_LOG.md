# solgate — Failure Log

> 실패할 때마다 1행. 같은 실패 재발 방지용 게이트를 추가하고 여기 기록.

| date | id | symptom | root cause | fix | gate added |
|---|---|---|---|---|---|
| 2026-07-10 | SG-001 | compact 게이트 PASS인데 stats.degraded=13 — 요약이 전부 절단 마커로 강등된 채 통과 | ① gpt-5.6-luna가 cli-proxy-api 7.2.54에서 `auth_unavailable`(sol·terra는 정상 — luna 카탈로그 override_header 특수처리 의심) ② 강등 마커를 캐시에 저장해 실패가 영구 오염 ③ 게이트가 degraded를 안 봄 | SUMMARY_MODEL 기본값 terra로 전환 + 강등 마커 캐시 저장 금지 + 오염 캐시 purge | e2e_compact_gate.sh에 degraded 증가 = FAIL 추가 |
