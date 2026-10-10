# conatus_viva：月度相册视频生成管线（conatus 子工具版）设计文档

> 项目代号 **conatus_viva**（viva = 拉丁语「活的」，与 conatus 同源；语义 = 让静止照片活过来、开口说话）。包/目录沿用 conatus 家族 `conatus_<x>` 习惯；管线核位于 `lib/pipeline/`，对外工具名 `generate_monthly_video`，子 agent 显示名 `viva`。

> 状态：待评审 · 日期：2026-10-10
> 上游文档：`docs/万相图生视频方言配音方案_v1.0.md`（原文件名已随文档匿名化一并更名；本文档对其做了范围修订，见 §1）
> 关联仓库：[Fi2zz/conatus](https://github.com/Fi2zz/conatus)（Dart agent harness，git 依赖钉版引入）

## 1. 背景与范围修订

原方案书按「一次性公共内容库批产」估算成本与里程碑。评审确认后的实际目标是：

**每月自动整理用户当月相册照片，挑选合适的照片，生成带方言配音和字幕的 15–20 秒视频。**场景不限定特定人群，按通用用户设计以便横向拓展。

这是按用户、按月的个性化生成。相对 v1.0 的口径修订：

| 项 | v1.0 文档 | 本设计确认口径 |
|---|---|---|
| 生成对象 | 一次性公共内容库 | 按用户按月的个性化相册视频 |
| 形态 | 单照片 1 条 15s | 3–4 张照片逐张生成后拼接，总长 15–20s |
| 预算 | ≤3 元/条 | ≈3 元/人/月；前期内测，预留后期扩展 |
| 人物照 | 风险表对策（模糊） | **一律降级 Ken Burns，不走 i2v**（硬规则） |
| 选片 | 未写 | 规则初选 + 多模态判定；**允许用户自选照片** |
| 字幕 | 未写 | **SRT 轨，端上渲染**（文本用标准书面语） |
| 音画主从 | 未写 | **音轨先行**：TTS 出来测时长 → 各段取整秒 → 拼接，尾部静音补齐 |
| 音色 | 声音复刻 | 统一产品音色；实验期先用系统音色，后补复刻 |
| 本期交付 | M0–M3 里程碑 | **本仓库内 Dart 代码端到端实验**（本机合成视频）；后端 + 队列后置 |

**本期做**：可嵌入 conatus 的 `generate_monthly_video` 工具 + 本机实验 host + 六步确定性管线。
**本期不做**：后端队列、OSS/CDN 分发、Flutter 端播放与 SRT 渲染、方言映射随包下发、声音复刻流程、产品端主 agent 接线（本期仅 `--agent` 模式验证形态）。

## 2. 总体结构

- **壳 = conatus**：`Context` / `ToolRegistry` / 审批中间件 / `AgentLoop` / 会话日志。产品里主 agent 通过 `spawn_agent` 或直接工具调用触达本工具。
- **核 = `lib/pipeline/`**：确定性编排，零 LLM 决策编排（LLM 只作为步骤内部的被调用方）。核只依赖 `conatus_foundation` 的 `Tool` 基类，不依赖壳的其余部分——将来搬后端时把核连同状态机一起搬走。
- **编排形态（已确认）**：单工具，内部确定性编排；不是 LLM 自由编排的子 agent，也不在本期用 conatus_workflow 承载（C 草稿见 §6）。

### 代码布局

```
pubspec.yaml
  dependencies:
    conatus: {git: {url: https://github.com/Fi2zz/conatus.git, ref: v0.17.0}}
    args, http

bin/conatus_host.dart     # 实验 host：装配 Context + ToolRegistry + 百炼 LLM
                          #   默认：结构化参数直接调用工具
                          #   --agent：最小 AgentLoop 以自然语言任务调用工具

lib/pipeline/             # 纯 Dart，不 import flutter（将来可原样搬后端）
  monthly_video_tool.dart # GenerateMonthlyVideoTool extends conatus Tool
  artifacts.dart          # 工件读写 + 每步「产物存在即跳过」契约
  state.dart              # state.json 读写（状态机内核）
  dialect_map.dart        # 省/市 → 方言标签 → TTS 指令 静态映射
  bailian/
    llm.dart              # OpenAiCompatibleProvider 封装（qwen3.8-flash，文本 + 多模态）
    tts.dart              # SpeechSynthesizer（instruction 方言 + 情感标签）
    i2v.dart              # wan2.6-i2v-flash 异步任务（提交/轮询/下载转存）
    uploader.dart         # ImageUrlProvider：本地照片 → 可用 img_url
  steps/
    classify.dart         # 01 每张照片：has_person / 质量 / 动效建议 / 一句话描述
    select.dart           # 02 选 N 张
    script.dart           # 03 分段口播稿 + i2v 动效 prompt
    tts.dart              # 04 逐段方言音轨 + 实测时长
    render.dart           # 05 逐段成片：i2v 或 Ken Burns
    compose.dart          # 06 ffmpeg 拼接 + SRT
  ffmpeg.dart             # ffmpeg / ffprobe 子进程封装
```

### 工具契约

`generate_monthly_video`

- 参数：`photos`（**OSS URL 或本地路径数组，混用亦可**）、`dialect`、`count`（默认 4）、`content_id`（缺省时间戳）、`dry_run`
- `riskLevel: high`（花钱 + 云端处理用户照片等敏感个人信息；产品中触发审批，实验 host 用 `AutoApproval` 直通）
- 返回 JSON：状态、`final.mp4`/`final.srt` 路径、各段路由、实际花费估算

## 3. 配置与密钥

密钥全走环境变量，不落盘、不进 git：

- `DASHSCOPE_API_KEY` — 百炼 LLM / TTS / 万相 / DashScope 文件上传
- `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET` — 兜底方案用（DashScope 上传不通时启用）

`pipeline_config.json`（进 git，纯参数）：

```json
{
  "llm":   {"model": "qwen3.8-flash"},
  "tts":   {"model": "qwen-audio-3.1-tts-flash", "voice_id": null,
            "fallback_model": "qwen3-tts-flash", "fallback_voice": "<M0 从官方音色列表选定后填入>"},
  "i2v":   {"model": "wan2.6-i2v-flash", "resolution": "720P",
            "watermark": true, "seed": 42, "poll_seconds": 15, "max_wait_minutes": 10},
  "oss":   {"bucket": "<仅兜底方案启用时填入>", "endpoint": "", "prefix": "pipeline-exp/"},
  "video": {"target_count": 4, "min_clip_s": 2, "max_clip_s": 15}
}
```

- `voice_id: null` → 走 `fallback_model` 系统音色（实验期决定）；日后复刻完成只填 `voice_id`，管线代码不动。
- 方言 TTS 注意：`instruction`（Qwen-Audio-TTS 系）与 `instructions`（Qwen-TTS 系）参数名不同，封装层按模型自动选择；指令 ≤100 字符；音频 URL 24 小时有效，**先转存本地再继续**。

### host 装配

`bin/conatus_host.dart`：`Context` → `provideTools` → `provideLlm(OpenAiCompatibleProvider(baseUrl: 百炼 compatible-mode, model: qwen3.8-flash))` → `AutoApproval` → 注册 `GenerateMonthlyVideoTool`。

内部 LLM 调用（01 判定、03 写稿、05 动效 prompt）**统一走 qwen3.8-flash 单模型**（文本 + 多模态一体，具体模型 ID 以百炼控制台为准），不单独引入 qwen-vl。

## 4. 六步流水线

工件目录 `pipeline_out/<content_id>/`：

```
state.json
meta.json
00_inputs/                # 输入为 OSS URL 时的本地副本（ingest 步产物）
01_classify.json
02_select.json
03_script.json
04_audio/seg_i.wav + durations.json
05_clips/seg_i.mp4 + status.json
06_final.mp4 + 06_final.srt
```

**执行契约（A 的核心）**：每步开始前查自己的产物是否已存在且完整 → 存在则打印 skip 直接返回；否则执行、写盘、更新 `state.json`。任何一步失败，现场保留，重跑同一命令自动从断点继续。i2v 段一旦下载到 `05_clips/` 绝不重复付费。

**`--dry-run`**：跑到 04 之后停下，打印执行计划（几段 i2v、几段 Ken Burns、预计花费）。

### 00 ingest（输入归一）

- 输入为 OSS URL → 立即下载落盘 `00_inputs/`，下游（分类、i2v 发布前的中转、断点重跑）**一律使用本地副本**；URL 仅需在下载那一刻有效
- 输入为本地路径 → 直接使用，无需上传环节
- 时间元数据：URL 输入取对象 Last-Modified，取不到则 02 的自动选片退化为纯质量分排序

### 01 classify（qwen3.8-flash 多模态，逐张）

- 输入：照片文件（base64/临时 URL 传给多模态模型）
- 输出：`{has_person, quality(1-5), motion_hint, caption}`
- 降级：失败重试 1 次 → 仍失败标 `has_person=unknown`，**按人物处理（Ken Burns）**——保守方向同时规避人脸风险与无效花费

### 02 select

- `--photos` 手选 → 分类结果透传；自动 → 规则初选（去重 + 质量分取前 N + 时间分布均匀）
- 降级：合格照片不足 N → 有几张用几张（下限 1）

### 03 script（qwen3.8-flash）

- 输入入选照片的 `motion_hint/caption`
- 输出：每段 `{photo, line(书面语口播 ≈15-20 字), motion_prompt(仅 i2v 段)}`
- 全片合计 ≈60–80 字（对应 15–20s）
- `motion_prompt` = `motion_hint` + 模板合成，硬约束「主体保持静止，仅背景与光影微动」+ 固定 seed
- 口播文本为标准书面语（方言只存在于音轨）

### 04 tts（SpeechSynthesizer）

- 逐段合成：`instruction = 方言指令 + 温柔语气`，文本前缀 `[very slowly]`，wav / 24000Hz
- 输出：`04_audio/seg_i.wav` + ffprobe 实测时长
- 降级：方言指令异常 → 重试 1 次 → 该段降级**普通话**重合成；全程失败 → 整条任务失败（无音轨无法继续）

### 05 render

每段时长 = `ceil(该段音频秒数)`，钳制 [2, 15]：

- `has_person=false` → 万相 i2v：`resolution=720P`、`audio=false`、`shot_type=multi`、`prompt_extend=true`、`watermark=true`、固定 `seed`；15s 轮询；SUCCEEDED 后**立即下载转存本地**再继续
- `has_person=true/unknown` → ffmpeg zoompan Ken Burns，零成本
- 所有段统一归一化（同分辨率 / 帧率 / 编码）供拼接

降级：

| 情况 | 策略 |
|---|---|
| 审核失败（IPInfringementSuspect / DataInspectionFailed） | 不重试，该段降级 Ken Burns（记 `degraded`） |
| 任务失败 / 限流 | 重试 ×2（官方失败不计费） |
| 超时（默认 10 分钟） | 标 `failed`，人工介入 |
| 进程中断后重跑 | `task_id` 已持久化且 <24h → 恢复轮询，**绝不重新提交** |

注意：万相临时 `task_id` / `video_url` 仅保留 24 小时，转存本地是硬约束。

### 06 compose

- 逐段：视频 + 该段音轨（尾部补静音 / 超长截静音）→ 中间 mp4 → 按序 concat
- 输出：`06_final.mp4` + `06_final.srt`
- 验证：ffprobe 校验总时长，`|视频-音频| ≤ 0.2s`

**字幕（SRT）生成规则**：

- **文本来源**：03 的 `line`（标准书面语），与喂给 TTS 的文本同源，但**剔除控制标签**——`[very slowly]` 等情感标签只进 TTS，绝不进字幕
- **时间戳**：每段一条字幕；`start` = 前面各段视频时长累计，`end` = `start + 该段实测音轨秒数`（语音一结束字幕即消失，段尾静音不留悬挂字幕）
- **行拆分**：单段 ≈15–20 字即单行；超过两行屏显长度时拆为两条，按字符比例分配该段时间
- **格式**：UTF-8、LF、无 BOM，与 mp4 同名同目录（`06_final.srt`）
- **样式不在 SRT 里**：字号/位置/底色属端上渲染职责（§10 后续，Flutter 播放器决定）；本期实验用 VLC/mpv 加载同目录 SRT 人工核对

### 成本护栏

- 进入 05 前打印执行计划与预计花费
- `state.cost` 累计 `i2v_seconds_total` 与 `estimated_yuan`
- 成本结构：i2v 占 99%+（0.15 元/秒），Ken Burns 段免费

## 5. 图片 → 公网 URL（ImageUrlProvider，可插拔）

输入优先直接给 OSS URL（已确认可行）：ingest 步落本地副本后，05 提交 i2v 时可直接把该 URL 传给 `input.img_url`——前提是 URL 生命周期覆盖任务全程（1–5 分钟 + 重试窗口）。

**本地照片（实验期主路径）**：提交 i2v 前由 provider 临时发布为公网 URL：

```dart
abstract class ImageUrlProvider {
  Future<ImageUrl> publish(File photo); // 返回 url + 过期时间 + 释放句柄
}
```

- 实现 1（首选，已确认）：`DashScopeUploadProvider` — 官方文件上传接口拿临时 URL，零 OSS 依赖；**M0 第一步先验证该 URL 可被万相拉取**（文档未明确承诺，属首要未知项）
- 实现 2（兜底）：`OssSignedUrlProvider` — 签名上传实验桶；DashScope 不通或需要更长生命周期时切换，需 bucket + RAM 凭证
- 备选（后补）：本机隧道
- 生命周期约束：URL 须覆盖 i2v 任务全程（1–5 分钟）+ 重试窗口

## 6. C 草稿：状态机与持久化

（本期实现 `state.json` 读写与恢复语义；conatus_workflow / 后端队列映射为设计草稿，不实现。）

### state.json schema

```json
{
  "content_id": "demo-202610",
  "params": { "dialect": "henan", "count": 4, "config_snapshot": {} },
  "steps": {
    "classify": {"status": "succeeded", "attempts": 1, "t": ["start", "end"], "error": null},
    "select":   {"status": "succeeded", "attempts": 1},
    "script":   {"status": "pending"},
    "tts":      {"status": "pending"},
    "render":   {"status": "running", "attempts": 2,
                 "error": {"class": "rate_limit", "msg": "..."}},
    "compose":  {"status": "pending"}
  },
  "segments": [
    { "i": 0, "route": "i2v", "audio_s": 4.6, "duration_s": 5,
      "status": "submitted", "attempts": 1,
      "i2v": {"task_id": "xxx", "submitted_at": "..."},
      "cost_seconds": 5 }
  ],
  "cost": {"i2v_seconds_total": 15, "estimated_yuan": 2.25, "degraded_count": 1}
}
```

写入走「临时文件 + rename」原子发布（照抄 conatus JSON backend 做法）。

### 状态与迁移

- 步骤级：`pending → running → succeeded | failed`（`skipped` 由「工件存在」隐含）
- 段级（仅 05）：`pending → submitted → downloading → succeeded`，旁路 `failed` 与 `degraded`

### 错误分类与重试

| 错误类 | 例子 | 策略 |
|---|---|---|
| `transient` | 网络超时、5xx、限流 | 重试 ×2，指数退避 |
| `audit_reject` | IPInfringementSuspect / DataInspectionFailed | 不重试，该段 `degraded` → Ken Burns |
| `stale_task` | 进程中断后重跑 | `task_id` 持久化且 <24h → 恢复轮询，不重新提交 |
| `fatal` | 密钥错、参数非法、预算超限 | fail fast，不消耗重试 |

### 幂等契约

重跑同一命令 = 读 `state.json` + 查工件 → 跳过 `succeeded`、按上表恢复 `running`、执行 `pending/failed`。

### 向终态的映射（草稿）

- `steps`/`segments` ↔ `conatus_workflow` 的 `RunNode`（`pending → ready → running → completed|failed|skipped` 语义一一对应）；05 各段天然可做 DAG 扇出并行
- `state.json` ↔ `WorkflowRun`（JSON 可序列化，换 store 即可）
- 产品态进度展示 ↔ `conatus_tasks` TaskCenter 事件
- 后端队列期：`state.json` 即任务快照，worker 无状态、按 content_id 抢活

## 7. 验证方式

### 离线可测（`dart test`，零网络、零花费）

- 工件跳过契约：产物存在 → skip；破坏一个产物 → 只重跑该步
- 状态机迁移与 `stale_task` 恢复轮询语义
- 方言映射：命中 / 就近 / 普通话兜底链
- SRT 时间戳累计计算 + 控制标签（`[very slowly]` 等）不进字幕的剔除逻辑
- ffmpeg 命令拼装；全链路离线跑：脚本化假 LLM/TTS/i2v（i2v 假实现产 zoompan 视频）+ 真 ffmpeg 合成 `final.mp4 + final.srt`

### 真钱冒烟（M0 出口，≈2.25–3 元/次）

1. 3–4 张真实照片（人物 + 风景混合）跑全程
2. 检查清单：
   - 成片本机可播，总时长 15–20s，`|视频-音频| ≤ 0.2s`
   - 路由正确：人物段 = Ken Burns，风景段 = i2v
   - 方言音轨听感人工评审
   - SRT 逐段与语音对齐
   - 打印花费 ≈ i2v 秒数 × 0.15
   - 立即重跑同一命令：全部 skip、零新调用、零新花费
   - i2v 轮询中 kill 进程 → 重跑 → 恢复原 task_id 轮询，无新提交
   - `--agent` 模式跑通一次，产出同样结果

## 8. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| 真人照片 i2v 面部扭曲 | 高 | 人物照一律 Ken Burns（已定为硬规则），classify 的 unknown 也走此路径 |
| 15s 长镜头漂移 | 中 | shot_type=multi + prompt 限幅 + 固定 seed；段长被音轨钳制在 ≤15s |
| 部分方言指令效果弱 | 中 | M0 人工听感评审；不达标降级就近方言或普通话 |
| 21 种方言覆盖外的地区 | 中 | 普通话兜底（本期不考虑民族语言） |
| 临时 URL 24h 过期 | 低 | SUCCEEDED 后立即转存本地；「转存成功」才标段完成 |
| 限流 RPM 300 | 低 | 实验与内测规模远低于限流 |
| 系统音色方言覆盖仅 8 种 | 低 | 实验期先跑通；补复刻后填 `voice_id` 切换 |
| DashScope 上传接口返回的 URL 不被万相 img_url 接受 | 中 | **M0 第一验证项**：单图冒烟先跑通再建管线；不通立即切 OssSignedUrlProvider（兜底方案已设计） |

## 9. 依赖与环境

- Dart SDK ^3.12.2（本仓库现状），ffmpeg 9.0.1（本机已装）
- `conatus` git 依赖钉版（`ref: v0.17.0`，README 推荐用法；纯 Dart，无 Flutter 依赖）
- 环境变量：`DASHSCOPE_API_KEY`、`OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`
- 百炼 LLM 走 OpenAI compatible-mode 端点（conatus 仅支持 OpenAI 兼容线协议）

## 10. 后续（非本期）

1. 后端 + 异步队列（worker 无状态，`state.json` 即任务快照）
2. OSS/CDN 分发与 Flutter 端按方言拉取、SRT 播放
3. 声音复刻（enrollment）与统一产品音色上线
4. 方言映射表随包下发；用户自选照片的端上交互
5. conatus_workflow DAG 化（段级并行）与 TaskCenter 进度接入
