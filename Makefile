# solgate — Makefile (github harness 생성)
.DEFAULT_GOAL := help
GH := github

.PHONY: help init readme images doctor version release qa

help: ## 사용 가능한 타깃 표시
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n",$$1,$$2}'

init: ## 저장소 스캐폴드(README/LICENSE/커뮤니티/CHANGELOG)
	$(GH) init . --tier full

readme: ## README 재생성
	$(GH) readme .

images: ## /gi 이미지 프롬프트 생성
	$(GH) images . --kind all

doctor: ## 저장소 건강 진단
	$(GH) doctor .

version: ## 다음 버전 산정 (conventional commits)
	$(GH) version .

release: ## 릴리스 계획(기본 dry-run)
	$(GH) release .

qa: ## 발행 준비 검증
	$(GH) qa .
