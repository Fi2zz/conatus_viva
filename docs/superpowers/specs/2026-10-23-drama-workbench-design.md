# 短剧工作台 · 全流程设计

> 状态：待评审 · 日期：2026-10-23
> 视觉与交互基准：`prototype/short-drama-console.html`（不参与构建，不修改）
> 关联：`docs/superpowers/plans/2026-10-23-storyboard-render-plan.md`（计划单只读版）
> 关联能力：图片合成、文生视频、图生视频、方言配音主讲人、视频编辑成本

## 1. 背景与目标

### 1.1 现状

当前 app 是六个平行入口：图片合成、文生视频、图生视频、方言配音主讲人、视频编辑成本、短剧工作台。
前五个各自完成一次操作，短剧工作台只读 `07_plan.json`，两者之间没有上下文传递：

- 分镜表只能由 CLI 生成，工作台不能创作或修改。
- 定妆、首帧、镜头视频、配音、合成都要在别的页面做完再自己搬回来。
- 没有剧集级状态、断点续跑、产物失效与跨集复用。
- 付费操作分散，预算只覆盖 i2v 一项，无法回答「这一集到底花了多少、还要花多少」。

### 1.2 终态目标

应用只有一个入口「短剧工作台」，覆盖一集短剧的完整链路：

```
故事文本 → 拆片/故事 → 分镜表 → 计划单与预算
        → 定妆 → 画面（首帧/静帧/微动/i2v/t2v）
        → 声音（逐句角色配音 + 可选主讲人）
        → 剪辑（竖屏合成/混音/字幕/编辑成本）
        → 打包（成片/SRT/封面/前 3 秒多版本）
```

- 多剧多集；角色定妆全季复用。
- 所有付费动作先估算、再确认；估算与执行共用服务端同一份报价。
- 产物存在且输入未变即跳过；输入变化标 stale，不自动重扣费。
- 每个工序都能看到真实产出、真实成本、真实缓存命中，不编造状态。
- CLI 不再是必需入口；P3 结束后删除旧 CLI 与旧只读端点。

### 1.3 本期（P1）范围

P1 只交付「骨架 + 创作闭环」，不新增图片/视频/TTS 的编排：

1. 多剧多集存储与 `/api/drama/*` 基础接口。
2. 按原型实现工作台三栏界面与工序舞台。
3. 拆片、故事、分镜三步真实可用：粘贴故事 → LLM 拆片 → 编辑故事/节拍/角色 → LLM 生成分镜草稿 → 表格编辑 → 保存并生成计划单。
4. 五个既有能力提成可嵌入组件，进驻对应工序（通用工具形态），旧 tab 从 `App.tsx` 删除；内嵌工具仍会发起真实生成并沿用现有费用闸门，但 P1 不把结果写进剧集资产。
5. 费用闸门、预算展示、空态/错误态/未接入态。

### 1.4 P1 明确不做

- 不做定妆/首帧/镜头视频/配音/合成的自动编排与产物持久化（P2/P3）。
- 不做批次队列、跨集缓存复用、画布实验区、封面/前 3 秒多版本（P4）。
- 不改相册六步管线（`lib/pipeline/steps/**`）的既有语义。
- 不删除旧 CLI 与旧计划单端点（P3 删除）。
- 不新增第三方依赖。

### 1.5 成功标准

- 能新建剧与集、粘贴故事、LLM 拆片、生成并编辑分镜、保存后得到确定性计划单。
- 五个能力在工作台内可达且行为与旧 tab 一致，没有功能回退。
- 工作台展示的工序状态、成本、缓存全部来自服务端真实数据。
- `make analyze` 零告警，`make test-dart` 全绿，`npm test && npm run lint && npm run build` 通过，`web_build/` 已重建。

## 2. 决策摘要

| ID | 决策 | 取值 |
|---|---|---|
| D-01 | 单一入口 | 终态只保留「短剧工作台」；P1 即删除五个旧 tab，五项能力改为工序内嵌组件 |
| D-02 | 架构 | 新增短剧领域层（`lib/pipeline/drama/`）与 `/api/drama/*`；相册管线不改 |
| D-03 | 流程起点 | 故事文本；拆片/故事两步可编辑，分镜由 LLM 草稿 + 人工表格编辑 |
| D-04 | 剧集范围 | 多剧多集；角色定妆与节拍模板属于剧级，全季复用 |
| D-05 | 声音 | 正片逐句角色配音；主讲人整片口播作为可选导读/花絮 |
| D-06 | 执行节奏 | 分步审批；每个付费动作过费用闸门；可选批量跑完剩余 |
| D-07 | 预算 | 双层：`total_budget_yuan` 全片闸门 + `i2v_budget_yuan` 计划单分配 |
| D-08 | 价格来源 | 只来自 `generation_models.dart` 与 `pipeline_config.json`；LLM/TTS 无目录价时标「未估价」 |
| D-09 | 幂等 | 产物 + `source_hash` 同时匹配才跳过；输入变化标 stale，不自动重跑、不删旧产物 |
| D-10 | 状态 | 工序状态由产物与 `state.json` 推导，Dart 端单一事实源；前端不自己编状态 |
| D-11 | 画布 | 节点状态全部来自真实 state；实验区 P4 前不出现 |
| D-12 | 迁移 | 旧 `07_plan.json` 不自动扫描；提供一次性导入入口；旧端点/CLI 在 P3 删除 |
| D-13 | 竖屏 | 生成用 720×1280，输出画布 1080×1920；ffmpeg 参数化，不改相册默认参数 |
| D-14 | 失败语义 | 图片按成功张数计费；视频失败不自动重试；合成失败零费用可重试 |

## 3. 信息架构与界面

### 3.1 工序与能力映射

| 工序 key | 名称 | 做什么 | 能力 | P1 | P2 | P3 |
|---|---|---|---|---|---|---|
| `split` | 01 拆片 | 源文本 → 梗概/节拍/角色建议 | LLM | ✅ | | |
| `story` | 02 故事 | 编辑 logline、梗概、节拍、角色 | LLM 草稿 | ✅ | | |
| `cast` | 03 定妆 | 角色形象图，全季复用 | 图片合成 | 工具进驻 | ✅ 持久化 | |
| `board` | 04 分镜 | 可编辑分镜表 → 计划单 | 纯函数 + 表格 | ✅ | | |
| `frame` | 05 画面 | 首帧、静帧、微动、i2v/t2v | 图片合成/图生视频/文生视频 | 工具进驻 | ✅ 编排 | |
| `voice` | 06 声音 | 逐句配音、方言、时间轴；主讲人导读 | 方言配音主讲人 | 工具进驻 | | ✅ |
| `edit` | 07 剪辑 | 竖屏合成、混音、字幕、编辑成本 | 视频编辑成本 + ffmpeg | 成本对比 | | ✅ |
| `pack` | 08 打包 | 成片、SRT、封面、前 3 秒多版本 | 图片/视频 + 导出 | | | ✅ |

### 3.2 布局

全屏三栏，视觉 token 取自原型：深暖底、橙红强调、衬线标题、等宽数字。

```
┌ 顶栏：品牌 / 剧名+元信息 / 集数 / 视图切换 / 总预算 / 缓存命中 ┐
├ 左栏 232px ───────┬ 中间舞台 ─────────────────┬ 右栏检视 ~300px ┤
│ 8 工序 + 成本/摘要 │ 产线视图 / 画布视图       │ 镜头或工序详情   │
├───────────────────┴──────────────────────────┴─────────────────┤
└ 底栏：本集成本 / 工时 / 素材数 / 前 3 秒 / 导出 / 出片 ─────────┘
```

- **顶栏**：剧名、`竖屏 9:16 · 方言 · 类型 · 集数`、集选择器、`产线视图/画布视图`、总预算条、缓存命中。缓存没有真实数据时显示 `—`。
- **左栏**：每项显示状态点、累计成本、产出摘要；选中态橙红渐变。底部「批次队列」P4 才出现。
- **舞台**：按工序切换内容，不是固定时间轴。时间轴、人审卡、成本构成只在有真实数据的工序出现。
- **右栏**：选中镜头显示首帧、台词、时长、路由、本镜成本、缓存键、改动历史、动作；选中工序显示产出、累计成本、缓存、下游影响。动作按钮直接标价。
- **底栏**：本集实际成本/预算、工时、可测素材、前 3 秒数量、导出投放包、出片。没有真实数据的指标显示 `—`；工时在 P1 按本次会话编辑计时，离开工作台即清零，不伪装成跨会话统计。
- **响应式**：宽度 < 940px 隐藏右栏；< 760px 左栏折叠为横向工序条。

### 3.3 工序舞台

| 工序 | P1 舞台内容 |
|---|---|
| 拆片 | 源文本编辑 + 「拆片」按钮 + 提取结果 diff（梗概/节拍/角色建议） |
| 故事 | logline、梗概、节拍列表（可增删改排序）、角色表（voice_id/方言/描述） |
| 定妆 | 角色卡 + 内嵌 `ImageStudio`（通用工具形态） |
| 分镜 | 分镜表、合计时长/成本、计划单摘要、i2v 预算与剩余、warning 列表 |
| 画面 | 内嵌 `ImageStudio` / `VideoStudio`（t2v、i2v），P2 换成逐镜编排与时间轴 |
| 声音 | 台词列表 + 内嵌 `SpeakerStudio`，P3 换成逐句配音与音频条 |
| 剪辑 | 内嵌 `EditCostEstimator`，P3 换成合成时间轴、字幕、成片 |
| 打包 | P1 显示「未接入」，P3 接成片/SRT/封面/多版本 |

P1 的内嵌工具仍是「独立任务」：生成结果只在工具内预览/下载，**不自动回填**角色或镜头，也不改变工序状态；P2/P3 才把结果写入剧/集资产并参与失效计算。这样既不丢能力，也不制造假完成。

### 3.4 诚实边界

- 未接入工序显示「未接入」和服务端能力标记，不显示假进度、假队列、假缓存。
- 画布节点状态全部来自 `state.json` 与产物；没有 state 的节点显示「未运行」。
- 费用闸门展示服务端 `estimate` 的逐项明细；无法估价的项单独列出，必须勾选「知悉按实际账单计费」才能继续。
- 不使用 `window.confirm/alert`，全部页面内确认。

## 4. 领域模型与存储

### 4.1 目录布局

```
pipeline_out/drama/series/<series_id>/
  series.json
  cast/<cast_id>/<hash>.png
  episodes/<episode_id>/
    episode.json
    storyboard.json
    plan.json
    state.json
    assets/frames/<shot_id>/<variant_id>.png
    assets/clips/<shot_id>.mp4
    assets/audio/<shot_id>.wav
    assets/presenter/<id>.mp4
    assets/covers/<variant>.png
    out/final.mp4
    out/final.srt
    out/package.json
```

- `pipeline_out/` 继续 gitignored；不提交任何产物。
- 资源只按 ID 派生路径；不接受前端传入的任意路径。

### 4.2 `series.json`

```json
{
  "series_id": "jietiao",
  "title": "借条",
  "logline": "一张旧借条把两个家庭重新拖回堂屋。",
  "dialect": "henan",
  "frame": "1080x1920",
  "content_type": "manju",
  "planned_episodes": 80,
  "defaults": {
    "total_budget_yuan": 120,
    "i2v_budget_yuan": 20,
    "max_i2v_seconds": 0,
    "cast_image_model": "wan2.7-image",
    "frame_image_model": "wan2.7-image",
    "clip_video_model": "wan2.6-i2v-flash",
    "t2v_model": "wan3.0-video",
    "resolution": "720P"
  },
  "beat_template": [
    { "id": "hook", "label": "钩子", "summary": "开场直接给冲突", "weight": 3 },
    { "id": "turn", "label": "反转", "summary": "证据翻面", "weight": 6 }
  ],
  "cast": {
    "erniu": {
      "name": "二舅",
      "description": "五十岁，短寸，旧夹克，眼神逼人",
      "voice_id": "qwen-tts-voice-id",
      "dialect": "henan",
      "avatar": {
        "path": "cast/erniu/9f2c.png",
        "source_hash": "sha256:...",
        "model": "wan2.7-image",
        "cost_yuan": 0.5,
        "approved": true
      }
    }
  }
}
```

- `defaults` 中的模型必须存在于目录；目录缺失时回退到目录默认模型并写 warning，不崩溃。
- `avatar.path` 相对于剧目录；`approved=false` 的定妆不算完成。

### 4.3 `episode.json`

```json
{
  "episode_id": "ep07",
  "series_id": "jietiao",
  "number": 7,
  "title": "堂屋对峙",
  "source": {
    "kind": "story",
    "text": "二舅拿着借条闯进堂屋……"
  },
  "story": {
    "logline": "二舅逼债，小满翻出第二张借条。",
    "synopsis": "……",
    "beats": [
      { "id": "hook", "label": "钩子", "summary": "借条拍桌", "target_s": 3 }
    ],
    "source_hash": "sha256:...",
    "prompt_version": 1,
    "model": "qwen3.8-flash"
  },
  "settings": {
    "dialect": "henan",
    "frame": "1080x1920",
    "total_budget_yuan": 120,
    "i2v_budget_yuan": 20,
    "max_i2v_seconds": 0,
    "target_duration_s": 90
  }
}
```

- `source.text` 是唯一故事输入；支持纯故事梗概或分场剧本，不做格式强校验。
- `story.source_hash` 在「拆片结果应用」时写入；源文本变化后与当前 hash 不一致，拆片工序回到待处理。
- `story.beats` 默认从 `series.beat_template` 复制；用户可改。
- `target_duration_s` 只用于分镜草稿提示与偏差 warning，不参与计费。

### 4.4 `storyboard.json`

在既有 `Storyboard` schema 上增加可选 `shots[].visual`（画面提示词）：

```json
{
  "content_id": "ep07",
  "title": "堂屋对峙",
  "dialect": "henan",
  "frame": "1080x1920",
  "budget_yuan": 20,
  "cast": {
    "erniu": { "name": "二舅", "voice_id": "qwen-tts-voice-id", "dialect": "henan" }
  },
  "shots": [
    {
      "id": "s01",
      "kind": "speak_off",
      "framing": "over_shoulder",
      "speaker": "erniu",
      "line": "你欠我的，今天该还了。",
      "duration_s": 3.0,
      "priority": "hook",
      "prop": "借条",
      "motion": "缓慢推近",
      "visual": "堂屋逆光，二舅把借条拍在八仙桌上，竖屏中景"
    }
  ]
}
```

- 继续使用 `storyboard.dart` 的解析与 canonical roundtrip；新增字段缺省为 `null`。
- `plan.json` 继续使用 `RenderPlan` schema；计划单不掺运行状态。

### 4.5 `state.json`

```json
{
  "series_id": "jietiao",
  "episode_id": "ep07",
  "storyboard_hash": "sha256:...",
  "plan_hash": "sha256:...",
  "steps": {
    "frame": { "status": "failed", "attempts": 1, "error": "镜头 s04 超时" }
  },
  "shots": {
    "s01": {
      "frame": {
        "status": "succeeded",
        "variants": [
          {
            "id": "v1",
            "path": "assets/frames/s01/v1.png",
            "source_hash": "sha256:...",
            "model": "wan2.7-image",
            "cost_yuan": 0.5
          }
        ]
      },
      "clip": {
        "status": "succeeded",
        "route": "i2v",
        "path": "assets/clips/s01.mp4",
        "duration_s": 3.0,
        "source_hash": "sha256:...",
        "model": "wan2.6-i2v-flash",
        "resolution": "720P",
        "cost_yuan": 0.45
      },
      "audio": {
        "status": "succeeded",
        "path": "assets/audio/s01.wav",
        "duration_s": 2.4,
        "source_hash": "sha256:...",
        "voice_id": "qwen-tts-voice-id",
        "cost_yuan": null
      },
      "review": { "status": "pending", "note": null }
    }
  },
  "active_run": null,
  "cost": { "actual_yuan": 0.95, "estimated_remaining_yuan": 2.3 },
  "warnings": []
}
```

- `status`：`pending | running | succeeded | failed | stale | skipped | interrupted`。
- 定妆是剧级资产，记录在 `series.json` 的 `cast[].avatar`，不重复写进每集 `state.json`；本集成本只算本集增量，定妆成本按剧级摊销展示。
- `cost.actual_yuan` 只累计本集成功产物；`cost.estimated_remaining_yuan` 由服务端估算。
- `active_run` 同时只允许一个；日志保留最近 200 行。

### 4.6 ID 与路径安全

- `series_id` / `episode_id` / `cast_id` / `shot_id`：`^[A-Za-z0-9_-]{1,64}$`。
- 路径只由上述 ID 拼接；读取静态资源时解析 `realpath` 后必须落在该集目录内。
- 非法 ID → 400；目录不存在 → 404；路径逃逸 → 400。

### 4.7 工序状态推导

`deriveSteps(series, episode, storyboard, plan, state)` 返回每个工序的
`{key, status, cost_yuan, summary, detail, wired}`：

| 工序 | 完成条件 |
|---|---|
| `split` | `source.text` 非空、`story.beats` 非空，且 `story.source_hash == hash(source.text)` |
| `story` | `logline`、`synopsis` 非空，剧级角色表至少一人 |
| `cast` | 分镜至少一镜，且分镜引用的每个 speaker 都有 `approved` 定妆图 |
| `board` | 分镜非空且 `plan_hash == hash(storyboard + settings)` |
| `frame` | 分镜至少一镜，且每个镜头都有 `clip.succeeded`（i2v/t2v 或本地 kenburns/micro） |
| `voice` | 有台词且 speaker 非空的镜头全部 `audio.succeeded`；无台词镜头 `skipped`；全片无台词时工序为 `skipped`；主讲人可选 |
| `edit` | `out/final.mp4` 与 `out/final.srt` 存在且 `compose_hash` 匹配 |
| `pack` | `out/package.json` 存在 |

- `state.steps[key].status == running/failed/interrupted` 时覆盖推导结果。
- P1/P2 未接入的工序 `wired=false`，状态显示「未接入」，`run` 端点返回 501。

### 4.8 幂等与失效

- 每个产物记录 `source_hash`：把该产物真正依赖的输入规范化（map key 递归排序）后算 SHA-256。
- 跳过条件：`status == succeeded`、文件存在且非空、`source_hash` 与当前计算值一致。
- 失效条件：任一不等 → `stale`；不删除旧文件、不自动重跑。
- 典型失效链：
  - 改 `line` → 该镜 `audio`、`clip`、`edit` 失效；计划时长可能变化。
  - 改 `visual` / `motion` / `kind` / `priority` → 该镜 `frame`、`clip`、`edit` 失效。
  - 改角色 `voice_id` / `dialect` → 该角色所有 `audio` 失效；时长变化再触发计划与下游失效。
  - 改画幅 → 所有画面产物与 `edit` 失效。
  - 改预算 → 计划重算；某镜 `i2v_seconds` 变化时该镜 `clip` 失效。
  - 改定妆图 → 引用该角色的 `frame`、`clip`、`edit` 失效。
- 计划单永远可以免费重算；UI 显示「N 项产物已过期 / 预计增量费用」。

### 4.9 成本口径

- 图片、视频单价只来自 `generation_models.dart` 与 `pipeline_config.json` 的 `pricing.*`；前端不存价格。
- 预算两层：
  - `total_budget_yuan`：全片闸门，校验 `actual + estimate ≤ total`。
  - `i2v_budget_yuan`：传给 `buildRenderPlan`，决定 i2v 秒数分配。
- 估算项：定妆图、首帧/静帧、i2v/t2v、主讲授视频。
- 未估价项：LLM、TTS。展示「以实际账单为准」，不计入预算估算；费用闸门要求勾选知悉。
- 合成与 kenburns/micro 是本地 ffmpeg，费用 0。
- 视频编辑成本只做横向对比，不产生费用，不计入本集成本。

### 4.10 并发与原子性

- 所有 JSON 原子写：写 `<file>.tmp` 后 rename；资源文件同样先写临时名再 rename。
- 同一集同时只允许一个写任务；忙时 409 `episode_busy`。
- 进程重启后，`running` 状态改为 `interrupted`；不自动续跑，用户在 UI 显式重试。
- 读请求永远看到完整旧文件或完整新文件。

## 5. 服务端接口

### 5.1 路由结构

`api_router.dart` 只增加一个分支：

```dart
if (path.startsWith('/api/drama/')) return ApiRoute.drama;
```

`DramaController` 内部用纯函数 `parseDramaRoute(method, pathSegments)` 做二级路由，
返回 `DramaRoute` 枚举或 `null`；这样路由表可以离线单测，且不会让 `ApiRoute` 膨胀。

### 5.2 剧集与创作

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/drama/series` | 剧列表（含集数、最近修改） |
| POST | `/api/drama/series` | 新建剧 |
| GET | `/api/drama/series/<sid>` | 剧详情 + 集列表 |
| PUT | `/api/drama/series/<sid>` | 改剧信息、角色、节拍模板、默认值 |
| DELETE | `/api/drama/series/<sid>` | 删除剧（无活跃任务时） |
| POST | `/api/drama/series/<sid>/episodes` | 新建集（可从节拍模板起） |
| GET | `/api/drama/series/<sid>/episodes/<eid>` | 整包读取 |
| PUT | `/api/drama/series/<sid>/episodes/<eid>` | 存源文本/故事/设置；改设置时若已有分镜则重算计划单 |
| DELETE | `/api/drama/series/<sid>/episodes/<eid>` | 删除集 |
| PUT | `/api/drama/series/<sid>/episodes/<eid>/storyboard` | 存分镜表并自动重算计划单 |
| POST | `/api/drama/series/<sid>/episodes/<eid>/plan` | 免费重算计划单 |
| POST | `/api/drama/series/<sid>/episodes/<eid>/estimate` | 只算费用，不执行 |
| POST | `/api/drama/series/<sid>/episodes/<eid>/story:extract` | LLM 拆片，返回草稿 |
| POST | `/api/drama/series/<sid>/episodes/<eid>/storyboard:draft` | LLM 生成分镜，返回草稿 |

**整包读取响应**：

```json
{
  "series": { "...": "Series" },
  "episode": { "...": "Episode" },
  "storyboard": { "...": "Storyboard" },
  "plan": { "...": "RenderPlan" },
  "state": { "...": "EpisodeState" },
  "steps": [
    { "key": "split", "status": "succeeded", "cost_yuan": 0, "summary": "12 拍", "wired": true }
  ],
  "capabilities": {
    "cast": false, "frame": false, "voice": false, "edit": false, "pack": false
  }
}
```

- `plan` 不存在时返回 `null`，不返回伪造对象。
- `state` 不存在时返回默认空状态（8 工序 `pending`、无产物、无成本），不返回 `null`。
- `steps` 永远按 8 工序顺序返回。

### 5.3 生成与产物（P2/P3）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `.../steps/<cast\|frame\|voice\|edit\|package>:run` | 异步启动，202 `{run_id}` |
| POST | `.../shots/<shot_id>:run` | 单镜重跑，body `{target: "frame"\|"clip"\|"audio"\|"all", force?}` |
| GET | `.../runs/<run_id>` | 状态、日志、逐项结果、实际费用 |
| POST | `.../runs/<run_id>:cancel` | 尽力取消；在途付费调用不承诺退款 |
| GET | `.../assets/<relative_path>` | 只读产物；按扩展名返回 `image/png`、`video/mp4`、`audio/wav`，禁止目录列表 |
| GET | `.../out/<file>` | 成片/SRT/导出包 |
| POST | `.../package` | 生成打包清单（P3） |

- `run` 前先走 `estimate`；预算不足直接 409，不创建 run。
- 运行顺序执行；每完成一项立即持久化 state 与成本。
- 单镜失败不中断整批，除非鉴权/配置错误——这些在任何付费调用前失败。
- 轮询 `runs/<id>`，1 秒一次；不引入 SSE。
- 视频失败不自动重试；图片可重试；合成失败零费用可重试。

### 5.4 费用估算

`POST .../estimate`：

```json
{
  "step": "frame",
  "shot_ids": ["s01", "s04"],
  "force": false
}
```

响应：

```json
{
  "items": [
    {
      "kind": "clip",
      "id": "s04",
      "model": "wan2.6-i2v-flash",
      "quantity": 3,
      "unit": "second",
      "price_yuan": 0.15,
      "subtotal_yuan": 0.45,
      "estimated": true
    }
  ],
  "total_estimated_yuan": 0.45,
  "unpriced": [
    { "kind": "tts", "id": "s01", "reason": "tts_pricing_unavailable" }
  ],
  "budget": { "total_yuan": 120, "actual_yuan": 1.2, "remaining_yuan": 118.8 }
}
```

- `estimate` 是唯一报价来源；前端只展示，不重算。
- 已缓存/未过期的项默认不出现在 items 中；`force: true` 时包含并标明。
- LLM/TTS 进 `unpriced`，不伪装成 0。

### 5.5 LLM 创作

- `DramaLlm` 接口：

```dart
abstract interface class DramaLlm {
  Future<Map<String, dynamic>> chatJson({
    required String system,
    required String user,
  });
}
```

- 默认实现包 `QwenClient`，模型取 `cfg.llmModel`；测试注入 fake。
- `kDramaPromptVersion = 1` 写入 `episode.story.prompt_version`。
- 拆片输出 `{logline, synopsis, beats, cast_new, cast_updates}`；**不自动覆盖**已有角色，UI 展示 diff 后应用。LLM 输出只作为草稿，必须经 schema 校验并由用户显式保存后才成为事实源。
- 分镜输出符合 `Storyboard` schema 的 JSON；服务端校验后返回 `{storyboard, warnings}`。
- 非法 JSON/字段错误：带错误信息重试一次；仍失败返回 422，附具体字段与一条可读建议。
- 校验规则：
  - 镜头 id 唯一、非空；缺失时服务端按顺序补 `s01...` 并写 warning。
  - `speaker` 不在 cast → warning，不阻塞。
  - 未知 `kind` / `priority` → 沿用现有降级 + warning。
  - 时长总和对 `target_duration_s` 偏差 >20% → warning。
- LLM 与 TTS 价格未知：`estimate` 标记 `unpriced`；费用闸门显示「以实际账单为准」并要求勾选。

### 5.6 错误码

| HTTP | code | 场景 |
|---|---|---|
| 400 | `invalid_id` / `invalid_body` / `path_escape` | ID 非法、JSON 结构错、路径逃逸 |
| 404 | `not_found` | 剧/集/文件不存在 |
| 409 | `episode_busy` / `budget_exceeded` | 已有写任务；估算超预算 |
| 413 | `body_too_large` | 请求体超限 |
| 422 | `schema_invalid` | LLM 返回不可修复 |
| 501 | `not_wired` | 该工序尚未接入 |
| 502 | `upstream_unavailable` | 百炼错误 |
| 500 | `internal` | 未分类错误 |

- 响应统一 `{ "error": "中文可读信息", "code": "...", "details": {...}? }`。
- 不返回堆栈、不记录、不回显任何密钥。

## 6. 生成编排（P2/P3）

### 6.1 工序执行器

| 执行器 | 输入 | 动作 | 产物 |
|---|---|---|---|
| `CastRunner` | series.cast | 文生图生成角色形象；可多版本 | `cast/<id>/<hash>.png` |
| `FrameRunner` | shot.visual + 定妆图 | 文生图或图生图生成首帧/静帧 | `assets/frames/<shot>/vN.png` |
| `ClipRunner` | frame + shot.motion + plan | i2v / t2v / 本地 kenburns/micro | `assets/clips/<shot>.mp4` |
| `VoiceRunner` | line + cast.voice_id | 逐句 TTS；ffprobe 测时长 | `assets/audio/<shot>.wav` |
| `PresenterRunner` | 主题 + 方言 | 复用主讲人管线 | `assets/presenter/<id>.mp4` |
| `EditRunner` | clips + audio | 竖屏合成、混音、字幕 | `out/final.mp4`、`out/final.srt` |
| `PackageRunner` | final + 素材 | 清单与导出 | `out/package.json` |

- i2v 用 `wan2.6-i2v-flash` / 720P；t2v 用目录内模型 / 720P；分辨率来自设置且必须在目录内。
- `kenburns` / `micro` 走本地 ffmpeg，零费用；`micro` 用更小的缩放/位移参数。
- 每个执行器都是「纯规划 + 注入 runner」结构，测试不碰网络。

### 6.2 音频先行

1. 所有台词先合成音频并测时长。
2. `reconcileDurations`：镜头 `duration_s` 取实测音频时长（0.1 秒精度）；无台词镜头保持原时长。
3. 时长变化超过阈值时，UI 明确提示「计划与已有画面将失效」，用户确认后：
   - 更新 `storyboard.json`；
   - 重算 `plan.json`；
   - 受影响 `clip` / `edit` 标 stale。
4. 不静默改时长，不静默重跑付费产物。

### 6.3 竖屏合成

- 新增参数化 ffmpeg 助手，默认保持现有 1280×720 行为，短剧显式传 `1080x1920`：
  - `normalizeArgsFor({width, height, fps})`
  - `kenBurnsArgsFor({width, height, durationS, out})`
  - `muxArgs` / `concatArgs` 复用。
- 每个镜头：视频归一化 → 与音频精确对齐（不足补静音、超出截断）→ concat → 生成同名 SRT。
- 合成后用 ffprobe 校验总时长与音轨存在；失败零费用可重试。
- 不烧录字幕，SRT 与 mp4 同目录同名，交给播放器。

### 6.4 失败与降级

- 图片：按成功张数计费；单张失败可重试，失败项标 `failed`。
- 视频：失败可能已计费；不自动重试，UI 提示先核对账单。
- TTS：失败可重试；不产生音频产物不算完成。
- 合成：本地失败零费用，可直接重试。
- 降级：只有用户在检视面板显式选择「降级为静帧」或预算规划给出降级时才发生；不静默降级。
- 鉴权/配置缺失：在任何付费调用前 fail fast，提示设置 `DASHSCOPE_API_KEY`。

## 7. 前端架构

### 7.1 组件树

```
App
└─ ShortDrama（工作台壳）
   ├─ WorkbenchHeader
   ├─ StepRail
   ├─ StageRouter
   │  ├─ SplitStage
   │  ├─ StoryStage
   │  ├─ CastStage        → ImageStudio
   │  ├─ BoardStage       → StoryboardTable + PlanSummary
   │  ├─ FrameStage       → ImageStudio / VideoStudio
   │  ├─ VoiceStage       → SpeakerStudio
   │  ├─ EditStage        → EditCostEstimator
   │  └─ PackStage
   ├─ Inspector
   ├─ FooterMeters
   └─ CostGate
```

- 不引入状态库；`useEpisodeBundle(seriesId, episodeId)` 负责拉取、保存、轮询。
- 轮询只在 `state.active_run != null` 时开启；卸载时清理。
- 请求序号守卫沿用现有 `ShortDrama.tsx` 的做法，避免并发加载串台。
- 保存采用显式「保存」按钮 + 未保存标记；不做隐式自动保存，避免分镜表写坏。
- 分镜表校验在纯函数 `validateStoryboard` 中，组件只展示错误。
- 成本、预算、时间轴计算放纯函数模块，组件不持有计费规则。

### 7.2 既有组件改造

- `ImageStudio`：增加可选 `initialPrompt`、`contextLabel`、`onJobComplete`；默认行为不变。
- `VideoStudio`：增加可选 `initialPrompt`、`initialFirstFrame`、`contextLabel`、`onJobComplete`。
- `SpeakerStudio`：从 `App.tsx` 内联逻辑提取为独立组件，行为不变。
- `EditCostEstimator`：原样复用。
- 旧 tab 从 `App.tsx` 删除；四个组件仍可独立渲染与测试。

### 7.3 分镜表

- 列：镜号、类型、景别、角色、台词、时长、优先级、成本。
- 行内编辑；支持新增、删除、上移/下移。
- 底部显示：镜头数、总时长、计划 i2v 秒数、预估成本、预算剩余。
- 保存时：
  1. 前端 `validateStoryboard` 做必填/唯一/范围校验；
  2. PUT 分镜表；
  3. 服务端重算计划单；
  4. 返回最新 bundle 与失效摘要。
- 时长留空表示按台词估算；用户填 0/负数/NaN 时前端直接报错，不提交。

### 7.4 费用闸门

- 展示：分项表、可估价合计、未估价项、当前实际花费、剩余预算。
- 超预算：确认按钮禁用，提示提高预算或减少镜头。
- 有未估价项：必须勾选「知悉未估价项按实际账单计费」。
- 确认后调用 run；失败展示服务端中文错误，不吞异常。

## 8. 分期实施

### P1 骨架 + 创作闭环

- 新增 `lib/pipeline/drama/{ids,series,episode,state,store,steps,cost,llm,controller}.dart`。
- `storyboard.dart` 增加 `visual` 可选字段与 roundtrip 测试。
- `api_router.dart`、`pipeline_server.dart` 接线；注入 drama root、fake llm seam。
- 前端：`shortDrama/api.ts`、`model.ts`、`Workbench` 组件、分镜表、故事编辑、费用闸门、CSS。
- `App.tsx` 去 tab；提取 `SpeakerStudio`；`ImageStudio`/`VideoStudio` 增加可选上下文 props。
- `make web` 并提交 `web_build/`。
- 不做：真实编排、TTS、合成、批次、实验区。

### P2 定妆 + 画面

- `CastRunner` / `FrameRunner` / `ClipRunner`；`estimate` / `run` / `runs` 端点。
- 竖屏 ffmpeg 参数化；本地 kenburns/micro。
- 工作台：逐镜生成、重跑、降级、时间轴缩略图、真实缓存命中、批量运行。
- 离线测试：fake runner + ffmpeg fixture。

### P3 声音 + 剪辑 + 出片

- `VoiceRunner`（逐句 TTS）、`PresenterRunner`、`EditRunner`、`PackageRunner`。
- 音频先行时长回写与失效确认。
- 竖屏合成、混音、SRT、成片预览与下载。
- 剪辑工序内嵌 `EditCostEstimator`。
- 删除 `bin/short_drama.dart`、`planner_cli.dart`、旧 `/api/short-drama/plans/*` 与对应测试（或迁移到新路径）。

### P4 系列化（后续）

- 批次队列、跨集素材缓存复用、画布实验区、封面/前 3 秒多版本、投放包。

## 9. 测试策略

### 9.1 Dart 离线

- `ids_test`：合法/非法 ID、大小写、长度、路径逃逸。
- `store_test`：建剧/集、原子写、读回 canonical、删除、目录不存在、并发冲突。
- `episode_test`：源文本/故事/设置校验、节拍模板复制、非法值。
- `state_test`：状态迁移、`interrupted` 恢复、日志上限、成本累计。
- `plan_test`：storyboard → plan 确定性、visual 透传、预算边界。
- `steps_test`：8 工序推导、wired 标记、过期/缓存判定。
- `cost_test`：图片/视频/主讲人估算、未估价项、预算超限。
- `llm_test`：fake LLM 返回合法/非法 JSON、重试一次、422、cast diff 不覆盖。
- `controller_test`：路由解析、CRUD、409/404/400/501、body 上限、路径安全。
- `api_router_test`：`/api/drama/*` 只落到 drama 分支，其他路由不变。

### 9.2 前端

- `model.test.ts`：bundle 解析、工序视图、预算百分比、格式化、时间轴。
- `storyboard.test.ts`：必填/唯一/时长范围/优先级、保存前校验。
- `cost.test.ts`：只展示服务端估算，不重算价格。
- `npm run lint`、`npm run build`、`npm test`。

### 9.3 手工

- `make run` → 新建剧/集 → 粘贴故事 → 拆片 → 生成分镜 → 编辑 → 保存 → 计划单与预算正确。
- 切换 8 工序，确认未接入工序显示「未接入」，无假数据。
- 窗口缩到 900px，确认右栏隐藏、布局不破。
- P2/P3 各加一条小额度真实生成检查，先看估算再确认。

## 10. 迁移与清理

- 不自动迁移旧 `pipeline_out/<id>/07_plan.json`。
- 空状态提供「导入旧计划单」：选择 `07_plan.json`，创建 `series/<content_id>` 与一集 `ep07`，分镜表按计划单逆向生成（只填可用字段），不伪造提示词。该入口 P1 可选，缺失不影响 P1 验收。
- 旧端点与 CLI 在 P1–P2 保留，P3 删除；删除前确保新测试不依赖。
- `prototype/` 保持只读。

## 11. 风险与缓解

| 风险 | 缓解 |
|---|---|
| LLM 分镜不稳定 | 强 schema + 一次纠错重试 + 可编辑表兜底 |
| 前端/后端费用漂移 | 只信服务端 `estimate`；前端不存价格 |
| 音频改变时长导致连锁失效 | 显式确认 + 统一 hash 失效 + 增量费用提示 |
| 竖屏 ffmpeg 与相册默认冲突 | 参数化助手，默认值不变，ffprobe 断言 |
| 去 tab 造成能力回退 | P1 嵌入现有组件并逐项对照功能清单 |
| 文件写入越界 | 严格 ID、realpath 校验、只写 drama 根目录 |
| 付费重复扣费 | 产物 + hash 跳过；视频失败不自动重试；重启不自动续跑 |

## 12. Definition of Done（P1）

- [x] 新建剧/集、读取整包、保存故事/分镜、计划单重算全部可用。
- [x] 工作台三栏与 8 工序按原型落地；未接入工序无假状态。
- [x] 五个旧 tab 删除，五项能力从工序可达且行为不回退。
- [x] 费用闸门展示服务端估算；未估价项要求勾选。
- [x] `make analyze` 零告警；`make test-dart` 全绿。
- [x] `npm test && npm run lint && npm run build` 通过；`make web` 已提交。
- [x] 不新增依赖；不提交 `pipeline_out/`、`.env`、密钥。

## 13. 2026-10-26 修订（P2 / 设置入口）

本节覆盖前文与之冲突的表述：

- **密钥入口**：桌面端密钥只来自设置页写入的 macOS Keychain；无原生通道的平台回退到用户目录 0600 文件。**不再读取 `.env`**，进程环境仅 CLI/CI 显式注入。`.env.example` 删除，`make setup` 只创建 `pipeline_config.json`。
- **设置 API**：`GET /api/settings` 只返回配置状态；`PUT /api/settings` 省略字段=不变、空串=清除；保存后更新运行中的 config，不回显密钥。
- **estimate 请求**：只接受 `{step, cast_ids?, shot_ids?, target?, force?}`，`step ∈ story|storyboard|cast|frame`；旧的 `targets` 格式删除。
- **P2 产物路径**：`cast/<cast_id>/<hash>/image-01.png`、`assets/frames/<shot_id>/<hash>/image-01.png`、`assets/clips/<shot_id>/<hash>.mp4`；hash 不一致即 `stale`。
- **定妆采用**：生成后 `approved=false`；用户点「采用」写回 `series`，`cast` 工序才完成。
- **P2 路由范围**：画面只消费计划单已有的 `i2v` / `kenburns` / `micro`；t2v 不新增自动路由，仍保留在通用工具。
- **预算**：总预算与 i2v 预算不足时，run 在任何付费调用前返回 409 `budget_exceeded`。
- **验收**：先完成 P1 验收记录；P2 离线全绿后做一次小额真实跑（约 ¥0.85），需用户确认，不把密钥写入仓库或日志。

## 14. P2 验收结果（2026-10-26）

- [x] 定妆生成、采用、剧级资产落盘。
- [x] 画面首帧 + i2v / 本地 kenburns、micro，竖屏 1080×1920。
- [x] hash 缓存、force 重跑、stale 失效、批次部分失败不回滚。
- [x] run / runs / assets 端点，预算与并发 409，路径逃逸 400。
- [x] 设置页 → macOS Keychain → 运行时 config 链路。
- [x] 离线全绿；真实 smoke 通过（估算 ¥0.85，实际 ¥0.85）。
- [x] 未接入 voice / edit / pack 仍为 501 / 「未接入」。
- [x] 详细记录：`docs/superpowers/plans/2026-10-26-p2-acceptance.md`。
