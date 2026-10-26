SHELL := /bin/bash
FRONTEND := frontend
DART_TEST_CMD := dart test test/pipeline \
	test/server/pipeline_server_test.dart \
	test/server/api_router_test.dart \
	test/server/image_api_test.dart \
	test/server/video_api_test.dart \
	test/server/short_drama_api_test.dart \
	test/server/drama_api_test.dart \
	test/server/settings_api_test.dart

.DEFAULT_GOAL := help

.PHONY: help setup deps web run analyze test test-dart test-web lint check-dialogs clean

help: ## 列出可用命令
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

setup: ## 从示例创建 pipeline_config.json（已存在则跳过）
	@if [ -f pipeline_config.json ]; then echo "pipeline_config.json 已存在，跳过"; else \
		cp pipeline_config.example.json pipeline_config.json; echo "已创建 pipeline_config.json —— 可按需填写 workspace_id / pricing"; fi

deps: $(FRONTEND)/node_modules ## 安装 Dart 与前端依赖
	flutter pub get

$(FRONTEND)/node_modules: $(FRONTEND)/package-lock.json
	cd $(FRONTEND) && npm ci

web: $(FRONTEND)/node_modules ## 构建前端到 web_build/（Flutter 打包的静态资源）
	cd $(FRONTEND) && npm run build

run: web ## 构建前端并启动 macOS 桌面 app
	flutter run -d macos

analyze: ## dart analyze（零告警基线）
	dart analyze lib bin test

test-dart: ## 离线 Dart 测试（跳过低代码的 web_build_assets_test）
	$(DART_TEST_CMD)

test-web: $(FRONTEND)/node_modules ## 前端单测 + oxlint + 原生对话框检查
	cd $(FRONTEND) && npm test
	cd $(FRONTEND) && npm run lint
	cd $(FRONTEND) && npm run check:dialogs

lint: ## 前端 lint（oxlint）
	cd $(FRONTEND) && npm run lint

check-dialogs: ## 确认前端没有 window.confirm/alert
	cd $(FRONTEND) && npm run check:dialogs

test: analyze test-dart test-web ## 全量离线校验

clean: ## 清理构建产物与前端依赖
	flutter clean
	rm -rf $(FRONTEND)/node_modules
