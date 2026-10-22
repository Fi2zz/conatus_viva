# 图片合成 / 视频合成 双类型生成 · 设计文档

> 状态：待评审 · 日期：2026-10-22
> 前置：`docs/superpowers/specs/2026-10-13-speaker-text-to-video-tool-design.md`（主讲人文生视频）
> 关联能力：万相 2.7 图像、千问图像 3.0、Z-Image、万相 3.0 视频

## 1. 背景与范围

当前桌面 app 只有视频一条主线：方言配音主讲人（`/api/t2v`）与视频编辑成本估算。模型靠
`--video-model` 和 `buildVideoClient` 里的 `model.startsWith('wan3')` 分流，没有图片能力，
也没有统一的模型清单。

本次把生成能力明确分成**两个类型**：

- **图片合成**（新增）：文生图、图生图/编辑、系列图。
- **视频合成**（新增通用入口）：文生视频；保留现有方言配音主讲人。

两类都走阿里云百炼。图片侧接入**万相图像 2.7** 与 **千问图像 3.0**，并补充 **Z-Image**
（低成本纯文生图）。

### 本期做

1. 四级平行 tab：`图片合成` / `文生视频` / `方言配音主讲人` / `视频编辑成本`。
2. 图片合成页：文生图、图生图·编辑、系列图三种子模式，本地上传参考图，成本确认闸门，
   结果网格预览与下载。
3. 通用文生视频页：提示词 + 模型 + 分辨率/比例/时长/音频，复用现有万相 3.0 t2v 能力。
4. 单一模型目录（kind + 能力 + 参数边界 + 单价），取代散落的模型名判断。
5. 新增 `/api/models`、`/api/images/*`、`/api/videos/*`。

### 本期不做

- 图片编辑的交互式框选（`bbox_list`）、调色盘 `color_palette` 的图形化配置。
- 相册流水线接入图片合成（照片仍走原有 i2v 路径）。
- OSS 上传通道（参考图走 base64 直传）。
- 任务历史列表 / 跨重启恢复（沿用主讲人模式的内存 run 记录）。

## 2. 模型目录与能力

单一事实来源：`lib/pipeline/generation_models.dart`。UI 与 server 都从
`GET /api/models` 读取，不在前端硬编码模型名或价格。

### 2.1 图片模型

| model id | family | 文生图 | 图生图/编辑 | 系列图 | 最大张数 | 最大参考图 | 分辨率 |
|---|---|---|---|---|---|---|---|
| `qwen-image-3.0-pro` | qwen3 | 支持 | 支持 | — | 6 | 3 | 512²–2048² |
| `qwen-image-3.0` | qwen3 | 支持 | 支持 | — | 6 | 3 | 512²–2048² |
| `wan2.7-image-pro` | wan27 | 支持 | 支持 | 支持 | 4（组图 12） | 9 | 1K/2K/4K（4K 仅文生图非组图） |
| `wan2.7-image` | wan27 | 支持 | 支持 | 支持 | 4（组图 12） | 9 | 1K/2K |
| `z-image-turbo` | zImage | 支持 | — | — | 1 | 0 | 最大 2048² |

- `qwen-image-3.0` 系列支持 `negative_prompt`；其他系列不传。
- 系列图只对 `wan27` 开放（`parameters.enable_sequential=true`），UI 对其他模型隐藏该子模式。
- `z-image-turbo` 的「批量」等价于多次单张调用，本期只允许 `n=1`，不提供系列图。

### 2.2 视频模型

| model id | 用途 | 分辨率单价档 |
|---|---|---|
| `wan3.0-video` | 通用文生视频（默认） | 480P / 720P / 1080P |
| `wan3.0-video-prime` | 高质文生视频 | 480P / 720P / 1080P |
| `wan2.6-i2v-flash` | 相册图生视频（既有，仅 CLI/管线） | 720P / 1080P |

通用文生视频页只暴露 `wan3.0-video` 与 `wan3.0-video-prime`；`wan2.6-i2v-flash` 需要首帧图片，
不属于文生视频。

## 3. 架构

```
React（frontend/src）
  ├─ ImageStudio.tsx   图片合成：三种子模式 + 结果网格
  ├─ TextToVideo.tsx   通用文生视频
  ├─ App.tsx           四个平行 tab + 共享轮询/费用确认
  └─ 只经 HTTP 访问本地 server，不直连百炼

Dart server（lib/server）
  ├─ api_router.dart      纯函数路由表（可离线单测）
  └─ pipeline_server.dart 已有路由 + 新增 images / videos / models

纯 Dart 生成层（lib/pipeline）
  ├─ generation_models.dart       模型目录：kind / 能力 / 边界 / 价格
  ├─ image_generation.dart        图片任务编排：校验 → 提交 → 轮询 → 下载 → job.json
  ├─ bailian/image_client.dart    抽象 + QwenImageClient / WanImageClient / ZImageClient
  ├─ bailian/image_job.dart       统一任务结果（images[] / usage）
  └─ text_to_video.dart           既有，通用文生视频复用
```

### 3.1 百炼接口映射

图片两个主力族共用同一套异步接口，提交与轮询逻辑因此可以共用：

| family | 提交 | 轮询 | 说明 |
|---|---|---|---|
| qwen3 | `POST /api/v1/services/aigc/image-generation/generation` | `GET /api/v1/tasks/{id}` | 请求头 `X-DashScope-Async: enable`；`input.messages[0].content` = 参考图对象 + `{text}`；结果在 `output.choices[].message.content[].image` |
| wan27 | 同上 | 同上 | 同样的 messages 结构；`parameters` 多 `enable_sequential` / `thinking_mode` / `n` / `size`（`1K`/`2K`/`4K` 或 `宽*高`） |
| zImage | `POST /api/v1/services/aigc/text2image/image-synthesis` | `GET /api/v1/tasks/{id}` | 老式结构：`input.prompt` + `parameters.size` + `n`；结果在 `output.results[].url` |

`ImageGenClient` 只暴露两件事：`submit(request) → taskId` 与 `parseTask(body) → ImageJob`。
族的差异全部封在两个方法里，轮询循环与落盘逻辑只有一份。

### 3.2 任务模型

```dart
class ImageRequest {
  final String model;      // 目录内的 id
  final ImageMode mode;    // t2i | i2i | series
  final String prompt;
  final String? negativePrompt;
  final String? size;      // "2048*2048" | "2K" | null=自动
  final int n;
  final int? seed;
  final List<String> refImages; // data URL，最多由目录约束
}
```

- 校验在 `image_generation.dart` 完成，早于任何网络请求，因此非法参数零计费。
- 参考图只接受 `data:image/{png,jpeg,webp};base64,...`，单张 ≤10MB，总请求体 ≤40MB。
- 提交后每 `image.poll_seconds`（默认 5 秒）轮询，超过 `image.max_wait_minutes`
  （默认 10 分钟）判失败。
- 成功后逐张下载到任务目录；下载失败的图计入 `failed`，不影响已成功图片的落盘。

## 4. HTTP API

### `GET /api/models`

```json
{
  "image": [
    {
      "id": "qwen-image-3.0-pro",
      "label": "千问图像 3.0 Pro",
      "family": "qwen3",
      "modes": ["t2i", "i2i"],
      "max_images": 6,
      "max_ref_images": 3,
      "supports_negative_prompt": true,
      "sizes": ["1024*1024", "1536*2688", "2688*1536"],
      "prices": { "2K": 0.5 }
    }
  ],
  "video": [
    {
      "id": "wan3.0-video",
      "label": "万相 3.0",
      "resolutions": ["480P", "720P", "1080P"],
      "prices": { "480P": 0.21, "720P": 0.42, "1080P": 0.84 },
      "duration_min": 2,
      "duration_max": 30,
      "supports_audio": true
    }
  ]
}
```

### 图片合成

| 方法 | 路径 | 说明 |
|---|---|---|
| `POST` | `/api/images` | 提交任务，返回 `202 {"id": "img-..."}` |
| `GET` | `/api/images/<id>` | 状态/日志/结果列表 |
| `GET` | `/api/images/<id>/<index>` | 下载第 index 张（`image/png`） |

请求体：

```json
{
  "model": "wan2.7-image-pro",
  "mode": "series",
  "prompt": "电影感组图，同一只橘猫的四季",
  "negative_prompt": "低清晰度",
  "size": "2K",
  "n": 4,
  "seed": 42,
  "refs": ["data:image/png;base64,..."]
}
```

状态响应：

```json
{
  "id": "img-20261022-101500-123",
  "status": "running",
  "logs": ["开始：模型 wan2.7-image-pro，模式 series，n=4"],
  "results": [{ "index": 1, "path": "/Users/x/conatus_viva/images/<id>/image-01.png" }],
  "cost": 2.0
}
```

### 通用文生视频

| 方法 | 路径 | 说明 |
|---|---|---|
| `POST` | `/api/videos` | 提交任务，返回 `202 {"id": "vid-..."}` |
| `GET` | `/api/videos/<id>` | 状态/日志/结果 |
| `GET` | `/api/videos/<id>/video` | 下载 mp4 |

请求体：`{model, prompt, resolution, ratio, duration, audio}`。校验沿用
`t2vMinDurationS..t2vMaxDurationS`，模型只接受目录中的文生视频模型。

### 兼容性

`/api/dialects`、`/api/edit-models`、`/api/t2v/*` 全部保持不变；原有的主讲人流程与测试不受影响。

## 5. 配置与计费

`pipeline_config.json` 新增（`pipeline_config.example.json` 同步）：

```json
{
  "image": {
    "poll_seconds": 5,
    "max_wait_minutes": 10,
    "default_model": "qwen-image-3.0-pro"
  },
  "pricing": {
    "image": {
      "qwen-image-3.0-pro": { "1K": 0.35, "2K": 0.5 },
      "qwen-image-3.0": { "1K": 0.2, "2K": 0.3 },
      "wan2.7-image-pro": { "1K": 0.35, "2K": 0.5, "4K": 1.0 },
      "wan2.7-image": { "1K": 0.2, "2K": 0.3 },
      "z-image-turbo": { "2K": 0.1 }
    },
    "video": {
      "wan3.0-video": { "480P": 0.21, "720P": 0.42, "1080P": 0.84 },
      "wan3.0-video-prime": { "480P": 0.45, "720P": 0.9, "1080P": 1.8 }
    }
  }
}
```

`image` 只管任务参数，`pricing` 只管单价，两者与相册管线既有的 `video` 段互不影响。

- 图片预估：`张数 × 该模型对应分辨率档单价`。
- 尺寸到档位：`size` 为 `1K`/`2K`/`4K` 时直接用；为 `宽*高` 时按面积判定——
  `面积 ≤ 2,250,000` 记 `1K`，`≤ 4,194,304` 记 `2K`，否则记 `4K`（与百炼
  `qima_*_1k/2k` 的计量口径一致）；未给 `size` 时按 `2K` 估算。
- 档位在该模型价格表里缺失时回落到最便宜档，并在日志里注明（避免高估让用户不敢点）。
- 视频预估：`秒数 × 该分辨率档单价`；`t2v.yuan_per_second` 继续作为旧入口回退值。
- 配置里的价格是**占位默认值**，控制台实际价格为准；UI 的费用确认文案必须带
  「以实际账单为准」。收到真实账单后只改配置，不改代码。
- 失败不计费：参数校验失败在本地返回 4xx；百炼任务失败时 `cost` 记为 0。

## 6. 前端

### 6.1 导航

`App.tsx` 的 `mode` 扩展为 `image | video | speaker | edit-cost`，四颗平行 tab：

`图片合成` ｜ `文生视频` ｜ `方言配音主讲人` ｜ `视频编辑成本`

### 6.2 图片合成页（`ImageStudio.tsx`）

- 子模式：`文生图` / `图生图·编辑` / `系列图`；切换到当前模型不支持的子模式时自动回退并提示。
- 字段：模型、提示词、反向提示词（仅 `supports_negative_prompt`）、尺寸、张数、种子、
  参考图上传（缩略图列表，可删除）。
- 参考图上传：`<input type="file" accept="image/*" multiple>` → `FileReader.readAsDataURL`
  → 前端校验数量/大小/类型 → 放进 `refs`。不上传临时文件到磁盘。
- 流程与现有主讲人页一致：填参 → 校验 → 页内费用确认（`张数 × 单价`）→
  `POST /api/images` → 1 秒轮询 → 结果网格。
- 结果网格：每张图内联展示，单独下载；全部完成后提供「下载全部」链接列表。
- 错误提示：4xx 显示 server 的 `error`；任务失败显示 `logs` 末行。

### 6.3 文生视频页（`TextToVideo.tsx`）

字段：模型、提示词、分辨率、宽高比、时长、是否保留音频。复用现有页内费用确认与轮询，
结果区 `<video>` 预览 + 下载。

### 6.4 共享件

抽出 `frontend/src/CostGate.tsx`（费用确认条）与 `frontend/src/useJob.ts`（轮询 hook），
供图片页与文生视频页复用。主讲人页本期保持原实现，避免无谓回归。

## 7. 错误处理

| 场景 | 行为 |
|---|---|
| 模型不在目录 / 子模式不支持 | `400`，文案指出该模型支持的模式 |
| 参考图数量或大小超限 | `400`，文案给出上限 |
| 张数/时长/尺寸越界 | `400`，文案给出区间 |
| 缺 `DASHSCOPE_API_KEY` | `200` 任务立即 `failed`，文案与主讲人页一致（提示设置环境变量） |
| 百炼返回 `FAILED` | 任务 `failed`，保留服务端 `code` / `message`，`cost=0` |
| 轮询超时 | 任务 `failed`，提示「超时，可在控制台核对任务」 |
| 单张下载失败 | 该张标记失败，其余照常完成 |

## 8. 测试

全部离线，`dart test` / `npm test` 不触网：

- `test/pipeline/generation_models_test.dart`：目录完整性（kind、能力、价格档）、
  非法组合拒绝、价格档回落。
- `test/pipeline/image_client_test.dart`：qwen3 / wan27 / zImage 三套请求体快照；
  两种响应结构的解析（`choices[].message.content[].image` 与 `results[].url`）。
- `test/pipeline/image_generation_test.dart`：MockClient 走完提交→轮询→下载；
  `n` 与 `cost` 计算；参考图超限在发起请求前失败。
- `test/server/api_router_test.dart`：新增路由与优先级（`/api/images/<id>/<n>` 必须先于
  `/api/images/<id>`）。
- `test/server/image_api_test.dart`：注入 fake runner 的端到端（202 → 轮询 → 下载字节）。
- `frontend/src/imageCost.test.ts`：张数 × 档位单价、档位回落。

## 9. 落地顺序

1. 模型目录 + 配置（纯数据，零网络）。
2. 图片 client 与任务编排（含测试）。
3. server 路由与 `/api/models`。
4. 前端两个新页 + 共享件。
5. README、`pipeline_config.example.json`、成本文档更新。

## 10. 风险与待验证

- `z-image-turbo` 的异步接口与参数以其官方文档为准；适配器已隔离，最坏情况只影响该模型，
  其余四个模型不受牵连。实施第一步先核对文档再写该适配器。
- 配置中的单价是占位值，可能偏离控制台账单；UI 已明确标注，后续只改配置。
- 图片任务记录与主讲人一致保存在内存：应用重启后结果文件仍在，但状态查询会 404。
