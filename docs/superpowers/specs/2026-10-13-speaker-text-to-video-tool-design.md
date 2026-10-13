# 方言配音主讲人 · 文生视频工具（Recut v1）设计文档

> 状态：待评审 · 日期：2026-10-13
> 前置：`docs/superpowers/specs/2026-10-10-monthly-album-video-pipeline-design.md`（相册流水线）
> 关联提交：`480dd09 feat(speaker): add dialect voiceover speaker web tool`

## 1. 背景与范围

`480dd09` 之后的未提交改动把产品形态改成了「Flutter 壳启动本地 Dart server + WebView 承载 React UI」。但 React UI（`frontend/`）被实现成了**相册流水线**（上传照片 → 数量上限 → 出片 + SRT），与「方言配音主讲人」的真实需求不符。

评审确认的真实需求：

> 做一个工具：**卡通图片作为主讲人，叠加到画面左下角**；参数为 **时长、方言类型、主题文字**；生成后给出**下载链接**。

**本期做**（文生视频）：
- React 表单改为 时长 / 方言类型 / 主题文字（去掉照片上传）。
- Dart server 新增文生视频 API（去掉照片 run API）。
- 复用现有 `万相 3.0` 文生视频能力（`generateTextToVideo` + `t2vPrompt`）。
- 新增 ffmpeg 合成步：把卡通主讲人以「圆角卡牌」形式叠加到成片左下角。
- 生成前展示**费用确认**，确认后真跑；完成后给出下载链接。

**本期不做**（明确后置）：
- 独立方言 TTS + LLM 口播稿（本期方言只通过提示词注入影响原生音频）。
- SRT 字幕轨。
- 照片/相册模式（相册流水线库保留，仅从本工具 server 摘除）。

## 2. 总体结构

保留现有壳：`lib/main.dart`（Flutter）启动本地 `lib/server/` Dart server，WebView 承载 React 构建产物。改的是 UI 语义与 server API。

```
React 表单 ──POST /api/t2v──▶ Dart server(PipelineServer)
  (时长/方言/主题)                ├─ prompt = t2vPrompt(主题, 方言)         [复用 host.dart]
                                  ├─ 万相3.0 generateTextToVideo(audio=on)  [复用 text_to_video.dart]
                                  ├─ ffmpeg overlay 圆角卡牌 左下角          [新增]
                                  └─ final.mp4 ──GET .../video──▶ 下载链接
```

### 分层与边界
- `lib/pipeline/**` 保持纯 Dart（不 import flutter），可整体搬后端。
- `lib/server/**` 纯 Dart；只依赖 `lib/pipeline/**` 与 `dart:io`。
- `lib/main.dart` 是唯一 Flutter 层：物化打包资源、传路径给 server。
- `frontend/**` 只经 HTTP 与 server 交互，不直连百炼。

## 3. 参数与 UI（`frontend/src/App.tsx`）

| 参数 | 控件 | 约束 |
|---|---|---|
| 时长 | slider | 2–30 秒（万相 3.0 上限），默认 5 |
| 方言类型 | dropdown | 21 项，来自 `GET /api/dialects` |
| 主题文字 | textarea | 直接作为视频提示词；非空校验 |

流程：
1. 填参 → 点「生成」→ **费用确认弹窗**（显示 `时长 × 单价` 预估）。
2. 确认 → `POST /api/t2v` → 轮询 `GET /api/t2v/:id` 显示日志与状态。
3. `completed` → 内联 `<video>` 预览 + 下载链接（指向 `GET /api/t2v/:id/video`）。

## 4. Server API（`lib/server/`）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/dialects` | 保留；返回方言列表，并附带文生视频单价与时长上下限供前端预估 |
| POST | `/api/t2v` | body `{duration, dialect, theme}` → `{id}`，异步启动一次生成 |
| GET | `/api/t2v/:id` | `{id, status, logs, error?, video_path?}` |
| GET | `/api/t2v/:id/video` | 成片 mp4（`Content-Disposition: attachment`） |

- **移除**照片相关：`POST /api/runs`（multipart + 照片落盘）及其 `video`/`srt` 文件路由。相册流水线库本身不动。
- 路由分派集中在 `api_router.dart`（纯函数、可离线单测）。
- `PipelineServer` 增加可注入的 `t2v` 生成函数 seam，测试用假实现、不联网。

## 5. 生成与主讲人叠加

### 5.1 生成
- 提示词 = `t2vPrompt(theme, dialect)`（方言指令如「请用河南话表达。」追加到提示词）。
- `generateTextToVideo(client, prompt, durationS, outFile, ...)`，`audio: cfg.t2vAudio`（默认 on，保留原生口播音频）。
- 模型 = `cfg.t2vModel`（`wan3.0-video`），分辨率/宽高比取 `cfg.t2v*`。

### 5.2 主讲人叠加（新增）
- 素材：`assets/images/speaker_avatar.jpg`（卡通形象，浅底）。
- 处理：缩放至视频高度约 **26%** → 圆角（细白边可后补；圆角用 alpha mask 实现）→ 叠加到**左下角**，边距约画面宽/高的 **4%**。
- 音轨保持原样（`-c:a copy`），时长不变。
- 纯参数构造函数置于 `lib/pipeline/ffmpeg.dart`（如 `overlayAvatarArgs`），单测断言参数；配一个本机 ffmpeg fixture 集成测试。
- 素材路径：`main.dart` 像 `web_build/` 一样把打包资源物化到临时目录，将绝对路径传给 `startPipelineServer`。

## 6. 费用门禁

- 单价来自配置 `t2v.yuan_per_second`（默认占位值，**待核实真实单价**），经 `/api/dialects` 下发。
- 前端在提交前弹确认框，显示 `时长 × 单价`，文案标注「预估，以实际账单为准」。
- 未确认不发送 `POST /api/t2v`（前端门禁；server 不做二次确认）。

## 7. 错误处理

- 后置 pipeline `PipelineError` 分 `audit_reject`（内容审核）与 `transient`（可重试，已在管线内退避 ×2）；失败写入 `GET /api/t2v/:id` 的 `error` 并在 UI 展示。
- 缺 `DASHSCOPE_API_KEY`：server 启动/生成时给出明确中文提示，不崩溃。
- ffmpeg 失败：`FfmpegException.stderr` 透传到 run 的 `error`。

## 8. 测试

- `test/server/api_router_test.dart`：新路由映射与优先级。
- `test/server/pipeline_server_test.dart`：注入假 t2v 生成器，断言状态流转与下载响应，不联网。
- `test/pipeline/ffmpeg_test.dart`：`overlayAvatarArgs` 参数断言；fixture 集成测试验证输出存在且音轨保留。
- 前端：`npm run build`（`tsc -b && vite build`）+ `npm run lint`（oxlint）。
- 全量：`dart analyze lib bin test` 零告警。

## 9. 影响文件

- 前端：`frontend/src/App.tsx`、`frontend/src/App.css`（必要时拆少量组件）。
- Server：`lib/server/api_router.dart`、`lib/server/pipeline_server.dart`、`lib/server/start.dart`。
- 管线：`lib/pipeline/ffmpeg.dart`（新增叠加参数）；可能新增 `lib/pipeline/avatar_overlay.dart`。
- 壳：`lib/main.dart`（物化头像资源并传路径）。
- 配置：`pipeline_config.json`、`pipeline_config.example.json`（新增 `t2v.yuan_per_second`）。
- 测试：上述 test 文件。

## 10. 待确认假设

1. 时长范围 **2–30 秒**（万相 3.0 上限）——已确认。
2. `wan3.0-video` **每秒单价**未知，用配置占位默认值，待用户核实填真值。
3. 成片保留**原生音频**（`t2vAudio=true`）。
4. 移除本工具 server 的照片端点；相册流水线库（CLI）不受影响。
5. 主讲人以**圆角卡牌/PiP**形式叠加（非抠图/非圆形头像）——已确认。
