# Changelog

이 프로젝트의 주요 변경사항을 기록합니다.
형식: [Keep a Changelog](https://keepachangelog.com/), 버전: [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
