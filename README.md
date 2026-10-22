# conatus_viva — 图片 / 视频两类生成与月度相册流水线

输入一组照片（本地路径或 URL）和方言地区，端到端产出 15–20 秒的相册视频：多模态选片、口播文案、方言配音、万相图生视频、字幕合成。全程断点续跑、不重复扣费。

桌面 app 把生成能力分成两类：**图片合成**（万相图像 2.7 / 千问图像 3.0 / Z-Image）
与**视频合成**（万相 3.0 文生视频、方言配音主讲人），另有视频编辑成本对比。

核心是纯 Dart 管线（`lib/pipeline/`，不依赖 Flutter），三种使用形态：

- **CLI**：`bin/conatus_host.dart`（实验入口，本文主要用法）
- **conatus 工具**：[conatus](https://github.com/Fi2zz/conatus) 的 `generate_monthly_video`（高风险操作走审批）
- **Flutter 桌面 app**：「方言配音主讲人」——内嵌 HTTP server + React 前端（WebView 壳），见下文专章

## 常用命令（Makefile）

```bash
make            # 列出全部命令
make setup      # 从示例创建 .env / pipeline_config.json（已存在则跳过）
make deps       # flutter pub get + 前端 npm ci
make web        # 构建前端到 web_build/
make run        # 构建前端并启动 macOS 桌面 app
make test       # analyze + 离线 Dart 测试 + 前端测试/lint
make clean      # flutter clean + 删除前端 node_modules
```

`make test-dart` 只跑可离线的 Dart 套件；`test/server/web_build_assets_test.dart`
依赖本机 Flutter SDK 与 `dart test` 的版本匹配，单独排除。

## 快速开始

```bash
# 1. 配置：复制模板，按需填写 workspace_id（百炼业务空间 ID，控制台可查）
cp pipeline_config.example.json pipeline_config.json

# 2. 密钥（只走环境变量，不落任何文件）
export DASHSCOPE_API_KEY=sk-...

# 3. 干跑：只到配音，返回分段路由与成本预估，不渲染
dart run bin/conatus_host.dart --photos /path/to/照片目录 --dialect 河南 --dry-run

# 4. 正式出片（i2v 按秒计费，≈0.15 元/秒）
dart run bin/conatus_host.dart --photos /path/to/照片目录 --dialect 河南 --content-id my-album
```

产出在 `pipeline_out/<content-id>/`：`06_final.mp4` + `06_final.srt`，中间产物（分类、文案、音轨、分段视频、`state.json`）全部落盘。中断后重跑同一条命令即从断点继续，已成功的步骤自动跳过。

### 文生视频（万相 3.0）

不需要照片，直接给一段提示词即可出片（模型、尺寸、时长、音频均可覆盖）：

```bash
dart run bin/conatus_host.dart --text-to-video "一只猫在草地上奔跑" \
  --video-model wan3.0-video --video-duration 8
# 产出：pipeline_out/videos/<content-id 或时间戳>/video.mp4

# 方言 + 字幕（字幕由你提供文本，每行一条，按总时长均分）
dart run bin/conatus_host.dart --text-to-video "大爷在胡同里遛鸟" --dialect 北京 \
  --subtitle-text $'哟，吃了么您呐\n没事儿遛遛弯儿'
# 额外产出同目录 video.srt（不烧录，交给播放器端上渲染）
```

## CLI 参数

| 参数 | 说明 |
|---|---|
| `--photos` | 逗号分隔的路径/URL，或一个目录（自动取图片，排序） |
| `--dialect` | 方言地区（如 河南、上海；未覆盖地区回落普通话）。相册模式作为 TTS 方言指令；文生视频模式则把「请用××话表达。」拼进提示词 |
| `--count, -n` | 入选照片数上限（默认 4） |
| `--content-id` | 内容 ID（缺省按时间生成）；同 ID 重跑 = 断点续跑 |
| `--dry-run` | 只跑到配音，返回成本预估，不渲染 |
| `--mute` | 跳过配音，静音音轨出片（字幕照常） |
| `--video-model` | 视频模型：`wan2.6-i2v-flash`（默认，等同配置 `i2v.model`）/ `wan3.0-video` / `wan3.0-video-prime`；`wan3*` 走万相 3.0 接口（图片作为首帧 `media[type=first_frame]`，无 `shot_type`） |
| `--text-to-video` | 文生视频：提示词。切到独立出片模式（无需 `--photos`/`--dialect`），用万相 3.0 只传 `prompt`（不传 `media`）生成 mp4 |
| `--video-resolution` / `--video-ratio` / `--video-duration` | 文生视频的分辨率 / 宽高比 / 时长（2–30 秒或 `-1` 智能）；缺省取配置 `t2v.*` |
| `--video-audio` | 文生视频是否保留原生音频（`--no-video-audio` 关闭；缺省取配置 `t2v.audio`） |
| `--video-out` | 文生视频输出文件路径（缺省 `pipeline_out/videos/<id>/video.mp4`） |
| `--subtitle-text` / `--subtitle-file` | 文生视频字幕（互斥）：文本每行一条 cue、按总时长均分；`.srt` 文件原样复制。输出到 mp4 同目录同名 `.srt` |
| `--prefer-provider` | 图片供给方式：`base64`（默认，直传免上传）/ `dashscope` / `oss` |
| `--agent` | 把参数包成自然语言任务交给 agent loop 执行 |

运行中进度打在 stderr（`[mm:ss]` 前缀），stdout 只输出结果 JSON。

## 图片合成与通用文生视频（桌面 app）

桌面 app 顶部四个平行 tab：**图片合成** / **文生视频** / **方言配音主讲人** / **视频编辑成本**。

### 图片合成

三种子模式：文生图、图生图·编辑、系列图（仅万相 2.7）。

| 模型 | 文生图 | 图生图 | 系列图 | 最大张数 | 参考图上限 |
|---|---|---|---|---|---|
| `qwen-image-3.0-pro` | ✅ | ✅ | — | 6 | 3 |
| `qwen-image-3.0` | ✅ | ✅ | — | 6 | 3 |
| `wan2.7-image-pro` | ✅ | ✅ | ✅ | 4（组图 12） | 9 |
| `wan2.7-image` | ✅ | ✅ | ✅ | 4（组图 12） | 9 |
| `z-image-turbo` | ✅ | — | — | 1 | — |

- **图生图·编辑支持多条任务**：每条 = 提示词 + 1 张被编辑图片 + 0–N 张参考图（参考图上限 = 模型上限 − 1）；一次提交依次执行，每条出一张图、按条计费，失败条目不影响其它条目。
- 参考图从本地上传，前端转 base64 直传，单张 ≤10MB，不依赖 OSS。
- 计费按**成功张数**：`张数 × 该分辨率档单价`；失败或超时不计费。
- 结果落在 `~/conatus_viva/images/<id>/image-XX.png`，页内网格预览与逐张下载。

### 通用文生视频

提示词 + 模型（`wan3.0-video` / `wan3.0-video-prime`）+ 分辨率 / 宽高比 / 时长 / 音频，
复用万相 3.0 t2v 能力；成片在 `~/conatus_viva/videos/<id>/video.mp4`，页内预览与下载。

## 方言配音主讲人（Flutter 桌面 app）

`lib/main.dart` 是桌面壳：启动内嵌 HTTP server，WebView 加载打包进来的 React 前端。填主题、选方言、定时长（2–30 秒），生成带卡通主讲人（左下角头像叠加）的方言口播视频，页内预览并下载 mp4。

```bash
# 密钥：app 从打包的 .env 读 DASHSCOPE_API_KEY（Finder 双击启动也有；
# 进程环境变量优先于 .env）
cp .env.example .env && $EDITOR .env

flutter run -d macos   # 也有 windows/ 工程
```

产出落在 `~/conatus_viva/speaker/<content-id>/`（GUI 经 `open` 启动时 cwd 是 `/`，所以故意用绝对路径）：`raw.mp4`（万相原始输出）+ `video.mp4`（叠加主讲人后的成片）。

### 前端开发回路

`frontend/` 是 React 19 + Vite 8 + TypeScript（oxlint 做 lint）：

```bash
cd frontend
npm run dev    # HMR 开发
npm run build  # 输出到 ../web_build/（vite outDir），Flutter 打包的静态资源
npm run lint   # oxlint
```

app 启动时 `lib/server/web_build_assets.dart` 把打包的 `web_build/` 物化到本地目录，由内嵌 server 托管给 WebView。

### 内嵌 HTTP API

`lib/server/`（`pipeline_server.dart` + `api_router.dart`）暴露：

| 路由 | 用途 |
|---|---|
| `GET /api/dialects` | 方言下拉选项（来自 `kDialectTable` 去重） |
| `GET /api/models` | 图片 / 视频模型目录（能力 + 配置后单价） |
| `POST /api/images` | 提交图片任务（模型 / 模式 / 提示词 / 张数 / 参考图） |
| `GET /api/images/<id>` | 图片任务状态、日志、结果与费用 |
| `GET /api/images/<id>/<n>` | 下载第 n 张图片 |
| `POST /api/videos` | 提交通用文生视频（模型 / 提示词 / 分辨率 / 时长 / 音频） |
| `GET /api/videos/<id>` | 视频任务状态与费用 |
| `GET /api/videos/<id>/video` | 下载成片 mp4 |
| `POST /api/t2v` | 提交一次主讲人文生视频生成（主题 + 方言 + 时长） |
| `GET /api/t2v/<id>` | 查询生成状态/结果元数据 |
| `GET /api/t2v/<id>/video` | 下载成片 mp4 |

路由分发是纯函数 `apiRouteFor(method, path)`（`api_router.dart`），不绑 socket 即可单测。

## 管线结构

```
lib/pipeline/
  config.dart        配置加载（pipeline_config.json + 环境变量密钥）
  dialect_map.dart   省市 → 方言指令映射（兜底普通话）
  state.dart         state.json 状态机（原子写、24h 任务恢复、成本核算）
  artifacts.dart     工件目录布局（产物存在即跳过）
  ffmpeg.dart        ffprobe 测时长 + 命令拼装（Ken Burns / 归一化 / 拼接 / 静音）
  generation_models.dart 图片/视频模型目录（kind + 能力 + 价格档）
  image_generation.dart  图片任务编排（校验 → 提交 → 轮询 → 下载 → 计费）
  bailian/           百炼客户端：llm（分类/文案）、tts（配音）、i2v（万相2.6）、wan30_video（万相3.0）、video_client（按模型名选 client）、image_client（图片三族）、uploader（图片供给）
  steps/             六步流水线：ingest → classify/select → script → tts → render → compose
  orchestrator.dart  编排器（步级幂等 + dry-run 停点 + --mute）
  speaker_video.dart 主讲人文生视频（t2v + ffmpeg 头像叠加，桌面 app 用）
  monthly_video_tool.dart  conatus 工具封装（高风险，走审批）
lib/server/
  pipeline_server.dart 内嵌 HTTP server（方言选项 / t2v 生成 / 状态查询 / 视频下载）
  api_router.dart     /api/* 纯函数路由分发
  web_build_assets.dart  把打包的 web_build/ 物化到本地目录
lib/speaker_tool/     主讲人工具的模型层（方言选项、表单、头像、.env 封装）
bin/conatus_host.dart      实验 CLI
frontend/             React 前端（方言配音主讲人 UI），构建产物在 web_build/
```

人物照片硬规则走 Ken Burns（ffmpeg zoompan），不提交万相；风景照走 i2v，审核拒答自动降级 Ken Burns 且零计费。i2v 默认用 `wan2.6-i2v-flash`，可用 `--video-model` 切到万相 3.0（`wan3.0-video` / `wan3.0-video-prime`）——两个模型族各有独立 client，靠模型名分流，2.6 的请求结构不受影响。

## 配置说明（pipeline_config.json）

不入库（含 workspace_id），模板见 `pipeline_config.example.json`：

- `workspace_id`：百炼业务空间 ID；非空时 LLM/TTS/i2v 端点全部切到 `https://<id>.cn-beijing.maas.aliyuncs.com`，留空走默认 `dashscope.aliyuncs.com`
- `tts.voice_id`：null → 用 `fallback_model`（qwen3-tts-flash）+ `fallback_voice`（系统音色 Cherry）；填 qwen-audio 音色 ID → 走方言指令通道（`请用河南话表达。`）
- `i2v`：模型/分辨率/水印/种子/轮询参数，全部显式钉死防默认抬价
- `t2v`：文生视频（万相 3.0）参数——模型/分辨率/宽高比/时长/是否保留原生音频/水印/种子/轮询/`yuan_per_second`（费用预估单价，默认 0.42），CLI `--text-to-video` 的默认来源
- `image`：图片任务的轮询间隔、超时与默认模型
- `pricing`：`image.<model>.<档位>`（元/张）与 `video.<model>.<分辨率>`（元/秒）；为**配置占位默认值**，以控制台账单为准

OSS 回退（`--prefer-provider oss`）另需环境变量 `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET` 及配置里的 `oss.bucket` / `oss.endpoint`。

## 成本预估

按**视频秒数 × 单价**计费，**失败不计费**（也不占用免费额度）。两种口径：

- **纯生成（相册 i2v、文生视频 / 主讲人，无输入视频）**：只按输出秒数计费，`费用 = 输出秒数 × 单价`。
- **视频局部修改（编辑类，如 `wan2.7-videoedit`）**：`计费时长 = 输入视频秒数 + 输出视频秒数`，**输入和输出都计费**（一条 N 秒素材、输出等长 ≈ `2N × 单价`）。

华北2（北京）单价（元/秒）：

| 模型 | 480P | 720P | 1080P |
|---|---|---|---|
| `wan2.6-i2v-flash`（无声，默认 i2v） | — | 0.15 | 0.25 |
| `wan3.0-video`（默认 t2v） | 0.3（限时7折 0.21） | 0.6（限时7折 0.42） | 1.2（限时7折 0.84） |
| `wan3.0-video-prime` | 0.45 | 0.9 | 1.8 |
| `wan2.7-videoedit` | — | 0.6 | 1.0 |

- 前端 / CLI 的费用预估由配置 `t2v.yuan_per_second` 驱动，`预估 = 时长 × 单价`；默认 **0.42**（`wan3.0-video` 720P 限时7折，原价 0.6）。页内生成确认会显示「单价 ¥0.42/秒 × N 秒」。
- 免费额度仅**华北2（北京）** 有：`wan3.0` 系列 30 秒、编辑类 50 秒、i2v 50 秒（均按输入+输出合计，失败不占用）。
- 注意默认分辨率是 **1080P**（显式传 720P 才走低价档）；`wan3.0` 声音开关不额外加价。
- 完整单价、速查表（按 2/5/10/15/30 秒）、地区差异与计费口径见 [`docs/万相视频生成与编辑成本核算_v1.0.md`](docs/万相视频生成与编辑成本核算_v1.0.md)。以控制台实际账单为准。

> 页面顶部「视频编辑成本」模式可横向对比三个编辑模型的预估费用。

## 测试

```bash
dart test                # test/pipeline/ + test/server/，全程离线（MockClient + 本机 ffmpeg fixture）
dart analyze lib bin test  # 零告警基线
```

## 文档

- 设计 spec：`docs/superpowers/specs/2026-10-10-monthly-album-video-pipeline-design.md`
- 实施计划：`docs/superpowers/plans/2026-10-10-conatus-viva-pipeline.md`
- 图片/视频双类型 spec / 计划：`docs/superpowers/specs/2026-10-22-image-and-video-generation-split-design.md`、`docs/superpowers/plans/2026-10-22-image-and-video-generation-split.md`
- 主讲人工具 spec / 计划：`docs/superpowers/specs/2026-10-13-speaker-text-to-video-tool-design.md`、`docs/superpowers/plans/2026-10-13-speaker-text-to-video-tool.md`
- M0 冒烟记录：`docs/superpowers/plans/m0-smoke-report.md`
- 方言配音方案：`docs/万相图生视频方言配音方案_v1.0.md`
- 视频局部修改可行性：`docs/视频局部修改可行性方案_v1.0.md`
- 成本核算（单价与计费口径）：`docs/万相视频生成与编辑成本核算_v1.0.md`
