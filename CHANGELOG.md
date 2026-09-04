# Changelog

All notable changes to this project are recorded here.
Format: [Keep a Changelog](https://keepachangelog.com/), versioning: [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- GPT-6 Astra main model (`gpt-6-astra`) and rolling-context profile (`gpt-6-astra-1m`), available through `vgpt astra`, `vgpt1m astra`, and `vgpt astra1m`.
- Astra-specific estimated budgets: compact above 220k, retain roughly 140k of recent context, and cap the estimated outgoing request at 240k, including tool definitions. Smaller global settings remain effective.
- Astra model-retention and context-boundary mock coverage, plus installer and CCR registration for four physical and four virtual profiles.
- English and Korean README entry points, an Astra hero image, and an updated setup and operations guide.
- `gpt-5.6-terra-1m`, `gpt-5.6-luna-1m` 가상 모델과 CLI alias(`vgpt terra1m`, `vgpt luna1m`)
- Virtual-profile base models, summary candidates, and model-retention/fallback matrix tests.
- Deduplicated virtual-model discovery and matching CCR provider registration.

### Changed
- Astra main responses retain the selected model; upstream failures are returned without substituting Sol, Terra, or Luna. Rolling summaries use Terra/Luna candidates.
- Regular Astra launchers explicitly pass `--autocompact 220k` before user options. Existing Sol defaults and Opus/Sol, Sonnet/Terra, Haiku/Luna worker assignments remain unchanged.
- Documentation distinguishes portable tests, small live checks, and large-context checks. Virtual 1M is described as summary-based context, not a native or lossless one-million-token window.
- `vgpt1m`의 `/model` Opus/Sonnet/Haiku 슬롯을 각각 Sol/Terra/Luna virtual 1M profile로 배선하고 물리 `[330k]` picker와 분리
- 모델 문자열에 `solgate,` provider prefix와 단일 `[1m]` cap을 사용해 Default의 `[330k][1m]` 이중 라벨 제거
- rolling compression, fail-closed ceiling, context retry를 sol/terra/luna 1M profile 공통 엔진으로 일반화
- summary sidecall을 base self-call과 virtual recursion이 불가능한 profile별 후보 정책으로 변경
- `gpt-5.6-sol-1m`과 `vgpt1m` 기존 진입점은 호환 유지

## [Public hardening]

### Added
- 실제 payload 크기를 기준으로 `context_too_large`를 재현하는 SG-003 회귀 E2E
- Terra sticky route 검증과 `ctxRetries` 운영 통계
- VPN/Tailscale scoped DNS 장애 진단 가이드

### Changed
- 가상 1M 재압축을 직전 전송 추정치의 70%, 최대 3회 폐루프로 강화
- 설치·launchd 문서를 공개 설치기 label(`com.solgate.*`)과 정합화
- fallback matrix를 sol/luna 자동 전환, terra 명시 route 유지로 명문화

### Fixed
- 재압축이 같은 body를 다시 보내도 테스트가 통과하던 횟수 기반 mock의 fail-open 문제
- user 경계가 소진된 대형 CJK/assistant payload가 천장을 넘을 수 있던 절단 경로
- VPN DNS override 장애 포스트모템의 초기 원인 오판

[Unreleased]: https://github.com/VoidLight00/solgate/compare/main...HEAD
