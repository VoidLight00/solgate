---
type: postmortem
id: PM-20260721-01
project: solgate
date: 2026-07-21
severity: P1
duration: 1d
status: resolved
---

# PM-20260721-01: VPN DNS override와 AAAA-only 시스템 해석으로 solgate 전 라우트 500

## 1. 요약

장문 자동화 작업 중 solgate 경유 sol·terra 라우트가 500으로 중단됐다.
직접 DNS 질의는 A 레코드를 반환했지만, VPN/Tailscale DNS override가 macOS 시스템 resolver의 우선순위를 바꿔 애플리케이션의 `getaddrinfo`에는 AAAA만 남았다. 해당 IPv6 경로가 도달 불가능해 ChatGPT OAuth 업스트림 전체가 실패했다.
초기에는 `dns-sd -G v4`가 일시적으로 캐시를 회복시켰지만 Wi-Fi 전환 뒤 재발했다. 최종적으로 해당 장비에서 Tailscale DNS 수락을 끄고(`tailscale set --accept-dns=false`) ISP resolver 우선순위를 복원해 해결했다. 조직에서 tailnet DNS가 필요한 환경은 이 조치를 그대로 적용하지 말고 DNS 관리자와 split-DNS 정책을 조정해야 한다.

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

왜 500? → solgate 업스트림 프로세스가 `chatgpt.com`을 해석하지 못함 → 왜? → 애플리케이션이 사용하는 macOS 시스템 resolver에는 AAAA만 반환되고 해당 IPv6 경로는 도달 불가능했음 → 왜 직접 `dig`/`nslookup`과 달랐나? → VPN/Tailscale DNS override가 MagicDNS resolver를 높은 우선순위에 두어 scoped DNS와 시스템 `getaddrinfo`가 서로 다른 응답 경로를 사용했음 → 왜 재발했나? → `dns-sd -G v4`는 캐시만 일시적으로 회복했으며 Wi-Fi 전환 뒤 DNS 우선순위가 다시 적용됐기 때문. 최종 근인은 단순 A 레코드 TTL 문제가 아니라 **VPN DNS override + 시스템 resolver의 AAAA-only 상태 + 도달 불가능한 IPv6 경로**의 결합이었다.

## 5. 관점 분석

- 기술: getaddrinfo(캐시 경유)와 dig(직질의)가 다른 답을 주는 이중 경로 + 죽은 IPv6 기본경로의 조합. 어느 한쪽만으로는 장애가 안 되는 2중 조건이었다.
- 프로세스: 모니터가 1시간 타임아웃으로만 발견 — pane의 `API Error: 5xx` 문자열을 즉시 잡는 감시가 처음부터 없었다 (사후 모니터에 추가 배선함).
- AI협업: executor(terra)는 지시대로 멈췄고 문제 없음. advisor가 solgate 로그가 아닌 pane scrollback에서 원인을 찾아 진단이 늦어졌다 — 라우트 장애 시 진단 체인(reference_vgpt_route_diagnostic)에 DNS 캐시 단계가 없었다.

## 6. 해결

초기 우회는 sudo 없이 A 레코드를 다시 질의해 캐시를 회복하는 것이었다. 이 조치는 Wi-Fi 전환 뒤 재발해 영구 해결이 아니었다.

최종 해결은 문제가 발생한 장비에서 Tailscale DNS 수락을 끄고 시스템 resolver 우선순위를 복원하는 것이었다:

```
$ tailscale set --accept-dns=false
$ scutil --dns                       # ISP/로컬 resolver 우선순위 확인
$ dscacheutil -q host -a name chatgpt.com
ip_address: 104.18.32.47
$ curl -s -o /dev/null -w '%{http_code}' https://chatgpt.com   # 403 = 연결 정상
```

이 명령은 tailnet DNS 이름 해석이 필요한 조직 환경의 동작을 바꿀 수 있다. 그런 환경에서는 무조건 실행하지 말고 split-DNS 또는 resolver 우선순위를 관리자와 조정한다.

## 7. 재발 방지

- 애플리케이션 DNS 장애 진단은 `dig` 하나로 끝내지 않고 `scutil --dns`와 `dscacheutil -q host`를 함께 확인한다.
- VPN/Tailscale 사용자는 Wi-Fi 전환 전후 resolver 우선순위가 달라지는지 확인한다.
- `API Error: 5xx`, `no such host`, `dial tcp`를 장기 작업의 즉시 실패 신호에 포함한다.

## 8. 재사용 가능한 진단 순서

`nslookup` 또는 `dig`는 정상인데 애플리케이션만 `no such host`라면 다음 순서로 확인한다.

1. `scutil --dns`로 scoped resolver와 우선순위를 확인한다.
2. `dscacheutil -q host -a name <host>`로 애플리케이션과 가까운 시스템 해석 결과를 확인한다.
3. VPN/Tailscale DNS를 일시 해제했을 때 증상이 사라지는지 비교한다.
4. 변경 전 조직 DNS 의존성을 확인하고, 영구 변경 뒤 실제 업스트림 요청까지 검증한다.
