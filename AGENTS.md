# AGENTS.md — conatus_viva 项目指南

> 给编码 agent 的仓库说明。**开始任何改动前先读本文件**；与 README 冲突时以本文件为准
> （README 面向用户，本文件面向实现者）。

## 1. 项目概述

- **是什么**：图片 / 视频生成工具。Flutter 桌面壳（macOS / Windows）+ React 前端（WebView）+
  内嵌 Dart HTTP server；核心能力在**纯 Dart 管线**里，可脱离 Flutter 用 CLI 跑。
- **三种使用形态**：CLI（`bin/conatus_host.dart`）、`conatus` 工具
  （`generate_monthly_video`，高风险走审批）、Flutter 桌面 app。
- **已有能力**：照片 → 15–20 秒方言相册视频（多模态选片、口播文案、方言 TTS、万相 i2v、
  字幕合成）；图片合成（文生图 / 图生图 / 系列图）；通用文生视频（万相 3.0）；
  方言配音主讲人；视频编辑成本对比。
- **进行中**：短剧方向（分镜表 → 渲染计划单 → 画布工作台），设计在
  `prototype/short-drama-console.html`，实施计划在
  `docs/superpowers/plans/2026-10-23-storyboard-render-plan.md`，上游改动在 `docs/upstream/`。
- **包名**：`flutter_wanxiang`（源码里 `import 'package:flutter_wanxiang/...'`，不是 conatus_viva）。

## 2. 仓库结构

| 路径 | 职责 | 约束 |
|---|---|---|
| `bin/` | CLI 入口（`conatus_host.dart`） | 薄入口，逻辑放 `lib/pipeline/` |
| `lib/pipeline/` | 纯 Dart 管线（可 CLI 跑） | **禁止 import Flutter** |
| `lib/pipeline/bailian/` | 百炼客户端（llm / tts / i2v / wan30 / image / uploader） | 只加协议适配，不放业务规则 |
| `lib/pipeline/steps/` | 六步流水线：ingest → classify/select → script → tts → render → compose | 步级幂等，产物存在即跳过 |
| `lib/server/` | 内嵌 HTTP server（`apiRouteFor` 纯函数路由） | 只绑 loopback |
| `lib/speaker_tool/` | 主讲人工具的模型层（表单 / 头像 / .env） | 可依赖 Flutter |
| `frontend/` | React 19 + TS + Vite 8 + oxlint + vitest | 只经 HTTP 与 server 交互 |
| `web_build/` | 前端构建产物（**入库**） | 改前端后必须 `make web` 并提交 |
| `test/pipeline/`、`test/server/` | 离线测试 | 禁止真实网络 |
| `docs/superpowers/{specs,plans}/` | 设计 / 实施计划（`YYYY-MM-DD-*.md`） | 先设计后实现 |
| `docs/upstream/` | 对 conatus 的反提交账本与补丁 | 见 §8 |
| `prototype/` | 交互线框（单文件 HTML，无依赖） | 不进构建 |
| `pipeline_out/` | 运行产物 | **gitignored，禁止提交** |

依赖方向：`bin` / `server` → `pipeline`；`frontend` → HTTP → `server`。反方向禁止。

## 3. 硬性约束（违反会被 review 打回）

1. `lib/pipeline/**`、`lib/server/**` 禁止 `import 'package:flutter/...'`（纯 Dart，可整体搬后端）。
2. 单价 / 计费口径只能来自 `pipeline_config.json` 与 `lib/pipeline/generation_models.dart`；
   新代码不得硬编码价格。付费操作前必须过费用确认（前端 `CostGate` / CLI dry-run）。
3. 模型能力与单价是**单一事实源**：`generation_models.dart`。新增模型先改目录，再改 UI / server；
   不在前端或 server 里按模型名写分支。
4. `state.json` 幂等与「产物存在即跳过」契约不可绕过；重跑同 `content-id` 必须从断点续跑，
   已成功步骤不重复扣费。
5. 「失败不计费」语义保持：审核拒答降级 Ken Burns 且零计费；重试 / 降级不得破坏该语义。
6. 密钥只走环境变量（`DASHSCOPE_API_KEY`；OSS 回退另需 `OSS_ACCESS_KEY_ID` /
   `OSS_ACCESS_KEY_SECRET`）。`.env`、`pipeline_config.json`、`pipeline_out/` 不入库；
   **禁止打印、记录、回显任何 key**。
7. HTTP server 只绑 `InternetAddress.loopbackIPv4`；不得改成 `0.0.0.0`，不得暴露公网。
8. 前端只经本地 HTTP server 访问百炼能力；不得直连厂商 API；不得用 `window.confirm/alert`
   （`npm run check:dialogs` 会拦）。
9. `web_build/` 是入库产物：任何 `frontend/` 改动都必须 `make web` 并把生成的 `web_build/` 一并提交。
10. 测试必须离线：用 `MockClient` / 本机 ffmpeg fixture，禁止真实网络与真实计费调用。

## 4. 常用命令

```bash
make                 # 列出全部目标
make setup           # 从示例创建 .env / pipeline_config.json（已存在则跳过）
make deps            # flutter pub get + 前端 npm ci
make web             # 构建前端到 web_build/
make run             # 构建前端并启动 macOS 桌面 app
make analyze         # dart analyze lib bin test（零告警基线）
make test-dart       # 离线 Dart 测试（不含 web_build_assets_test）
make test-web        # 前端 vitest + oxlint + 原生对话框检查
make test            # analyze + test-dart + test-web
make clean           # flutter clean + 删除 node_modules

# 单测
dart test test/pipeline/storyboard_test.dart
dart test test/pipeline            # 纯离线子集

# CLI（先 dry-run，不花钱）
dart run bin/conatus_host.dart --photos /path/to/照片 --dialect 河南 --dry-run
dart run bin/conatus_host.dart --text-to-video "一只猫在草地上奔跑" --video-duration 8

# 前端开发
cd frontend && npm run dev      # HMR
cd frontend && npm test         # vitest
cd frontend && npm run lint     # oxlint
```

## 5. 代码组织与风格

- **Dart**：中文注释 / 中文文档；文件头写清职责与契约；函数短小、早返回；不吞异常——
  错误统一走 `PipelineError` + `ErrorClass`（`transient` 可重试 / `fatal` 立即失败）。
- **新增能力**：先加纯函数 / 数据模型（可单测），再接 IO 与 UI；模型目录、价格、能力边界
  优先进 `generation_models.dart` / `edit_models.dart`。
- **server**：新路由先加 `apiRouteFor` 的纯函数分支与单测，再在 `pipeline_server.dart` 接线。
- **前端**：定价 / 计算逻辑放纯函数模块（参考 `imageCost.ts` / `editCost.ts`），便于 vitest；
  组件不持有业务计费规则；类型用独立 `type` 导入。
- **格式**：跟随周边代码风格；可对改动文件跑 `dart format`，但**不要格式化整仓**（制造无关 diff）。
- **依赖**：不新增第三方依赖，除非任务明确要求并说明理由。
- **文档**：面向用户的说明写 README；设计与计划写 `docs/superpowers/`；研究 / 方案写 `docs/`。

## 6. 测试策略

| 层级 | 位置 | 关注点 |
|---|---|---|
| 单元 / 离线 | `test/pipeline/`、`test/server/` | 纯逻辑、协议解析、幂等与降级语义（MockClient + ffmpeg fixture） |
| 前端 | `frontend/src/*.test.ts` | 成本估算等纯函数（vitest） |
| 手工 / 真机 | 仅在明确要求时 | 真实生成先 `--dry-run`，再小额度试 |

- 基线：`make analyze` 零告警 + `make test-dart` + `make test-web`。
- `test/server/web_build_assets_test.dart` 依赖本机 Flutter 与 `dart test` 版本匹配，
  不在 `make test-dart` 里；单独跑失败时先确认 SDK 版本，别改业务代码。
- 改动前先跑一次基线；失败时先判断是否自己引入，别顺手修无关红线。

## 7. Agent 工作流（必须遵守）

1. **读**：README → 本文件 → 相关 spec / plan；先 `git status` 看清 WIP。
2. **定界**：优先新增文件，避免改动他人未提交的 WIP；一个提交只做一件事。
3. **实现**：先纯函数 / 局部改动，再接 IO 与 UI；不扩大范围，不做「顺手优化」。
4. **验证**：`make analyze` + 对应测试；改前端跑 `npm test && npm run lint`；改前端必须
   重新 `make web` 并提交 `web_build/`。
5. **提交**：Conventional Commits + 中文描述 + scope，例如：
   `feat(image-edit): 图生图支持多条提示词` / `fix(web): ...` / `test(pipeline): ...` /
   `docs(upstream): ...`；功能 / 修复 / 重构分开提交。
6. **汇报**：说明改了什么、验证结果、没做什么、遗留风险。

计划文档命名 `docs/superpowers/plans/YYYY-MM-DD-<topic>.md`，设计文档
`docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`。短剧方向的实现按
`docs/superpowers/plans/2026-10-23-storyboard-render-plan.md` 执行。

## 8. 短剧方向与 conatus 上游

- 线框：`prototype/short-drama-console.html`（单文件，直接浏览器打开）。
- 实施计划：`docs/superpowers/plans/2026-10-23-storyboard-render-plan.md`
  （分镜表 → 渲染计划单，纯离线、不碰 ffmpeg / conatus）。
- **conatus 依赖**：`pubspec.yaml` 里以 git tag 固定（当前 `v0.17.0`）；开发期需要本地改动时用
  `dependency_overrides` 指 `../conatus`，**不要 fork 或复制一份 conatus 代码**。
- **反提交规则**（详见 `docs/upstream/ledger.md`）：
  - 领域词不进上游（短剧 / 镜头 / 方言 / 人民币 / 百炼 / ffmpeg 留在 viva）；
  - 只消费通用 seam，本地绕行必须在账本挂一行；
  - 补丁放 `docs/upstream/patches/`，先验证再提；
  - conatus 各包 sdk 下限不同（如 `conatus_workflow` 是 3.6，legacy 格式），
    **`dart format` 必须在 conatus 仓库内跑**，不要在仓库外用全局格式化。
- 上游当前状态以 `docs/upstream/README.md` 为准（已合并 / 待合分支写在那里）。

## 9. 已知边界与坑

- **默认 1080P 会抬价**：i2v / t2v 要显式传 `720P` 才走低价档；i2v 默认时长 5 秒。
- **watermark 默认开启**（`i2v.watermark: true`），合规需要，别默认关。
- ffmpeg / ffprobe 必须在 `PATH`；字幕不烧录进画面，输出同名 `.srt` 交播放器渲染。
- macOS WKWebView 不支持 `<input type=file>`：参考图 / 图片选择走原生 `NSOpenPanel`
  （见 `lib/speaker_tool` 与前端对应代码），不要退回 file input。
- 视频编辑类模型要求输入视频是**公网 URL 或 `oss://`**，不支持 base64；调用前需先上传。
- 没有 lip-sync / 对口型模型：短剧对白镜头靠构图与画外音规避，不要引入「口型同步」假设。
- server 无鉴权，靠 loopback 隔离；不要为了联调把它暴露到局域网或公网。
- `pipeline_out/` 是运行产物（含 state.json 与 mp4），**禁止提交**。

## 10. 提交前检查清单

- [ ] `git status` 只包含本次预期文件（没有误加 WIP / `pipeline_out/` / `.env` / 密钥）
- [ ] `make analyze` 零告警
- [ ] 改动的 Dart 测试通过（`make test-dart` 或对应单测）
- [ ] 改前端：`npm test && npm run lint` 通过，且已 `make web` 并提交 `web_build/`
- [ ] 新增模型 / 单价已进 `generation_models.dart` 或配置，没有硬编码
- [ ] 文档 / README / 计划文档已同步（必要时）
- [ ] 提交信息符合 Conventional Commits + 中文描述 + scope

## 11. 不确定时

采用**最小改动**，先说明假设再动手；涉及付费语义、幂等契约、密钥、公开网络暴露的改动，
先问再改。不要为了「跑通」绕过 `state.json`、CostGate 或 loopback 约束。
