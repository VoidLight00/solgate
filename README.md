# solgate

gpt-5.6-sol(실창 372k input) 위에 **가상 1M 컨텍스트**를 만드는 로컬 프록시.
전체 방법서(토폴로지·사용법·재현 절차·트러블슈팅)는 **[docs/GUIDE.md](docs/GUIDE.md)** 가 정본이다.
300k 초과 대화의 오래된 구간을 gpt-5.6-luna 청크 요약으로 접고, 최근 ~200k는 원문 유지한다.
물리 창을 늘리는 게 아니라 압축 계층이다 — 오래된 턴은 요약본(무손실 아님).

```
Claude Code(vgpt1m, [1m]) → CCR :3456 → solgate :8321 → VibeProxy :8317 → gpt-5.6-sol
                                     요약 사이드콜 ↘ gpt-5.6-luna
```

## 사용

- `vgpt1m` — 가상 1M 세션 (zshrc)
- `vgpt` — 물리 372k 세션 (sol[330k], solgate 미경유)
- 상태: `curl http://127.0.0.1:8321/solgate/stats`
- 상주: launchd `com.voidlight.solgate` (KeepAlive)

## 검증 (HARD 게이트)

```bash
bash gates/verify_solgate.sh ~/projects/solgate          # 전체 (대형 compaction e2e 포함, 토큰 소모 큼)
SOLGATE_SKIP_BIG=1 bash gates/verify_solgate.sh ~/projects/solgate  # 대형 e2e만 스킵
```

사양 SSoT: `REQUIREMENTS.md` (SR1~SR11). 실패 기록: `FAILURE_LOG.md`.
로그/캐시: `~/.solgate/{logs,cache}` — 로그에 대화 원문 저장 금지(SR8).

## 작업 기록

Claude와의 빌드/변경 세션은 `docs/BACKLOG.md`에 세션 단위로 append한다
(목표 → 결정 → 실측 증거 → 남은 것). 산문 주장 없이 증거만 기록.
