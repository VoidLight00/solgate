---
type: postmortem
id: PM-20260721-01
project: solgate
date: 2026-07-21
severity: P1
duration: 75m
status: workaround
---

# PM-20260721-01: chatgpt.com A레코드 캐시 소실 + 죽은 IPv6 경로로 solgate 전 라우트 500

## 1. 요약

voidnews 델타 수집 중 solgate 경유 vgpt/vgpt1m(sol·terra) 전 라우트가 500으로 죽어 executor run이 중단됐다.
원인은 mDNSResponder 캐시에 chatgpt.com이 AAAA-only로 남고 IPv6 기본경로가 죽은 utun0을 향해, 시스템 리졸버 소비자 전부가 접속 불능이 된 것.
sudo 없이 `dns-sd -G v4`로 A레코드 재질의를 강제해 캐시를 복구하고 PONG 검증 후 run을 재개했다.

## 2. 증상

tmux pane(voidnews-sol)의 terra 세션이 서브에이전트 실패와 함께 유휴 정지:

```
API Error: 500 Error from provider(solgate,gpt-5.6-terra: 500):
{"error":{"message":"Post \"https://chatgpt.com/backend-api/codex/responses\":
dial tcp: lookup chatgpt.com: no such host","type":"server_error"}}
```

- `curl https://chatgpt.com` → 000 (exit 6 Could not resolve / exit 7 Couldn't connect)
- `nslookup chatgpt.com` → 104.18.32.47 정상 반환 (리졸버 직질의는 멀쩡)
- `curl https://www.google.com` → 200 (일반 인터넷 정상)

## 3. 타임라인

- 18:43 terra 델타 run 시작 → DELTA_STATUS 생성 후 수집 진행
- 19:38 가설: run 장기화 → 시도: 모니터 타임아웃 후 pane 실측 → 결과: FAIL — solgate 500 `no such host`로 run 중단 발견, 컨텍스트 88% 유휴
- 19:44 가설: DNS 전역 장애 → 시도: nslookup/직접 curl/CCR·solgate health → 결과: FAIL — nslookup은 되는데 curl만 실패, 게이트웨이는 정상 (모순 관찰)
- 19:46 가설: /etc/hosts 오염 → 시도: grep → 결과: FAIL — 깨끗함
- 19:47 가설: 시스템 리졸버 캐시 → 시도: `dscacheutil -q host` → 결과: PASS(진단) — chatgpt.com만 ipv6_address 2건뿐, A레코드 부재. IPv6 기본경로는 링크로컬만 가진 utun0로 블랙홀 (`curl -6 google` 000)
- 19:48 가설: 캐시 flush로 해결 → 시도: `dscacheutil -flushcache` + `sudo -n` → 결과: FAIL — 비sudo flush 무효, sudo는 password required
- 19:51 가설: mDNSResponder에 A 질의를 강제하면 캐시가 재생성된다 → 시도: `dns-sd -G v4 chatgpt.com` 3초 → 결과: PASS — 캐시에 ip_address 2건 등장, `curl https://chatgpt.com` 403(연결 정상)
- 19:53 시도: `vgpt1m terra -p 'PONG…'` 엔드투엔드 → 결과: PASS — PONG 출력, 라우트 복구 확정

## 4. 근본 원인

왜 500? → solgate(Go)가 chatgpt.com을 해석 못 함 → 왜? → getaddrinfo가 AAAA만 반환하고 v6 경로는 죽어 있음 → 왜 AAAA만? → mDNSResponder 캐시에서 chatgpt.com의 A레코드 세트만 소실(AAAA TTL만 잔존) → 왜 소실? → 미확정 — A/AAAA TTL 불일치 시점에 재질의가 실패(일시 네트워크 블립)했거나 negative cache로 추정 → 왜 치명적? → utun0이 링크로컬만 가진 채 IPv6 기본경로를 잡고 있어 v6 폴백이 블랙홀이었기 때문. 죽은 v6 경로는 여전히 남아 있어 status=workaround.

## 5. 관점 분석

- 기술: getaddrinfo(캐시 경유)와 dig(직질의)가 다른 답을 주는 이중 경로 + 죽은 IPv6 기본경로의 조합. 어느 한쪽만으로는 장애가 안 되는 2중 조건이었다.
- 프로세스: 모니터가 1시간 타임아웃으로만 발견 — pane의 `API Error: 5xx` 문자열을 즉시 잡는 감시가 처음부터 없었다 (사후 모니터에 추가 배선함).
- AI협업: executor(terra)는 지시대로 멈췄고 문제 없음. advisor가 solgate 로그가 아닌 pane scrollback에서 원인을 찾아 진단이 늦어졌다 — 라우트 장애 시 진단 체인(reference_vgpt_route_diagnostic)에 DNS 캐시 단계가 없었다.

## 6. 해결

sudo 불가 상황에서 무권한 A레코드 강제 재질의로 캐시 복구:

```
$ dns-sd -G v4 chatgpt.com
19:51:16.112  Add  40000003  0  chatgpt.com.  172.64.155.209  214
19:51:16.112  Add  40000002  0  chatgpt.com.  104.18.32.47    214
$ dscacheutil -q host -a name chatgpt.com
ip_address: 172.64.155.209
ip_address: 104.18.32.47
$ curl -s -o /dev/null -w '%{http_code}' https://chatgpt.com   # → 403 (연결 정상)
$ vgpt1m terra -p 'PONG이라고 한 단어만 출력하라'                 # → PONG
```

## 7. 재발 방지

- 감시 배선: voidnews-sol 모니터에 `API Error: 5[0-9][0-9]|no such host|dial tcp` 즉시 감지 추가 (세션 Monitor 스크립트, 본 노트 §5 프로세스 항목).
- 진단 절차 갱신: `~/.claude/projects/-Users-voidlight/memory/reference_vgpt_route_diagnostic.md`에 DNS 캐시 단계(`dscacheutil -q host` → `dns-sd -G v4`) 추가.

## 8. 다음 세션 룰 후보

"nslookup은 되는데 curl exit 6"이면 mDNSResponder 캐시 의심 — sudo 전에 `dns-sd -G v4 <host>` 무권한 복구를 먼저 시도한다.
