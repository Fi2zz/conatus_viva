# conatus_viva 月度相册视频管线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 conatus_viva 仓库内实现 `generate_monthly_video` 工具：输入照片（本地路径或 OSS URL）与方言标签，端到端产出 15–20 秒方言配音 + SRT 字幕的成片，全程可断点重跑、不重复付费。

**Architecture:** conatus 提供壳（Context/ToolRegistry/审批/AgentLoop），`lib/pipeline/` 是核——六步确定性流水线（ingest → classify → select → script → tts → render → compose），每步产物落盘到 `pipeline_out/<content_id>/`，`state.json` 记录状态与错误分类，重跑 = 跳过 succeeded、恢复 running。LLM/TTS/万相全部走百炼。

**Tech Stack:** Dart 3.12（纯 Dart，`lib/pipeline/` 不 import flutter）、conatus（git 依赖）、`package:http`（含 `http/testing.dart` MockClient 做离线测试）、本机 ffmpeg 9.0。

**Spec:** `docs/superpowers/specs/2026-10-10-monthly-album-video-pipeline-design.md`

**与 spec 的一处澄清（评审注意）：** spec 代码布局把 `bailian/llm.dart` 注为「OpenAiCompatibleProvider 封装」，但 spec §2 同时要求「核只依赖 conatus_foundation 的 Tool 基类」。本计划取后者：`bailian/llm.dart` 用 `package:http` 直连百炼 OpenAI 兼容端点；conatus 的 `OpenAiCompatibleProvider` 只在 `bin/conatus_host.dart`（壳侧，`--agent` 模式）使用。核因此可整体搬去后端。

## Global Constraints

- Dart SDK `^3.12.2`；`lib/pipeline/**` 与 `bin/**` 一律 `import 'package:flutter/...'` 禁止（纯 Dart）。
- conatus 依赖：`conatus: {git: {url: https://github.com/Fi2zz/conatus.git, ref: v0.17.0}}`。
- 密钥只走环境变量：`DASHSCOPE_API_KEY`、`OSS_ACCESS_KEY_ID`、`OSS_ACCESS_KEY_SECRET`；任何测试不得读真实密钥。
- 模型与参数（spec §3/§4，测试须断言）：LLM `qwen3.8-flash`；TTS `qwen-audio-3.1-tts-flash`（`voice_id` 为空时降级 `qwen3-tts-flash` 系统音色）；i2v `wan2.6-i2v-flash`、`resolution=720P`、`audio=false`、`watermark=true`、`seed=42`、`poll_seconds=15`、`max_wait_minutes=10`。
- 每段时长 = `ceil(该段音频秒数)`，钳制 `[2,15]`；成片总长 15–20s；成本 = i2v 秒数 × 0.15 元。
- 人物照路由硬规则：`has_person` 为 `true` 或 `unknown` → Ken Burns（ffmpeg zoompan），绝不提交 i2v。
- 错误分类与重试：`transient` 重试 ×2 指数退避；`audit_reject` 不重试、该段 `degraded`→Ken Burns；`stale_task`（task_id 已持久化且 <24h）恢复轮询、绝不重新提交；`fatal` fail fast。
- TTS：指令参数 `qwen-audio-*` 用 `instruction`、`qwen3-*` 用 `instructions`；指令 ≤100 字符 = 方言指令 + 温柔语气；文本前缀 `[very slowly]`。
- SRT：文本剔除 `[...]` 控制标签；`start` = 前段视频时长累计，`end = start + 该段音频秒数`（上限为段视频时长）；UTF-8、LF、无 BOM；>40 字拆两条按字符比例分时。
- 幂等：重跑同命令 = 跳过 `succeeded`、恢复 `running`、执行 `pending/failed`；`state.json` 写入必须临时文件 + rename 原子发布。
- 文档/代码注释/提交信息匿名化：不出现「老人/适老/长辈/银发/子女」等人群限定词。
- 测试统一用 `dart test test/pipeline/<file> -r expanded`（若 `dart test` 解析失败则改 `flutter test`）；每任务结束 `dart analyze lib bin test` 零告警。

## Review Focus

以下五类是 spec 隐含但最容易在实现中被破坏的输入/条件，各归属任务的测试必须钉住：

1. **DashScope 上传的 URL 可能不被万相 `img_url` 接受**（spec §5 首要未知项）→ 预期：M0 首个动作是单图冒烟，不通则切 `OssSignedUrlProvider`；归属 Task 16 的手动清单（Task 11 的测试钉住 provider 可切换性）。
2. **i2v 提交后进程中断 → 重跑重新提交 = 重复付费 + 24h URL 过期** → 预期：恢复轮询已持久化的 task_id，零新提交；归属 Task 12 的 resume 测试。
3. **i2v 默认参数悄悄抬价/改规格（默认 1080P、audio=true）** → 预期：请求体显式携带 `resolution=720P`、`audio=false`、`duration=段秒数`；归属 Task 12 的请求体断言测试。
4. **`[very slowly]` 等控制标签漏进字幕** → 预期：SRT 文本只含口播正文；归属 Task 13 的 SRT 测试。
5. **音画总时长偏差 >0.2s** → 预期：compose 后 ffprobe 校验，超差抛错不产出；归属 Task 13 的校验测试。

---

### Task 1: 脚手架——依赖、配置加载

**Files:**
- Modify: `pubspec.yaml`
- Create: `pipeline_config.json`、`lib/pipeline/config.dart`、`test/pipeline/config_test.dart`

**Interfaces:**
- Consumes: 环境变量 `DASHSCOPE_API_KEY`（不读断言，仅提供 getter）
- Produces:
  - `class PipelineConfig`：`static Future<PipelineConfig> load({File? file, Map<String,String>? env})`
  - 字段（不可变）：`String llmModel`、`String ttsModel`、`String ttsFallbackModel`、`String? ttsVoiceId`、`String? ttsFallbackVoice`、`String i2vModel`、`String i2vResolution`、`bool i2vWatermark`、`int i2vSeed`、`int i2vPollSeconds`、`int i2vMaxWaitMinutes`、`String ossBucket`、`String ossEndpoint`、`String ossPrefix`、`int targetCount`、`int minClipS`、`int maxClipS`、`String baseUrl`（默认 `https://dashscope.aliyuncs.com/compatible-mode/v1`）
  - `String requireApiKey()`：env 无 `DASHSCOPE_API_KEY` 时抛 `ConfigException`

- [ ] **Step 1: 写失败测试**

`test/pipeline/config_test.dart`：

```dart
test('loads pipeline_config.json with spec defaults', () async {
  final c = await PipelineConfig.load(file: File('pipeline_config.json'), env: {});
  expect(c.llmModel, 'qwen3.8-flash');
  expect(c.ttsModel, 'qwen-audio-3.1-tts-flash');
  expect(c.i2vModel, 'wan2.6-i2v-flash');
  expect(c.i2vResolution, '720P');
  expect(c.i2vWatermark, isTrue);
  expect(c.i2vSeed, 42);
  expect(c.targetCount, 4);
});
test('requireApiKey throws without env var', () async {
  final c = await PipelineConfig.load(file: File('pipeline_config.json'), env: {});
  expect(() => c.requireApiKey(), throwsA(isA<ConfigException>()));
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/config_test.dart -r expanded`
Expected: FAIL（`PipelineConfig` 未定义）

- [ ] **Step 3: 改 `pubspec.yaml` 并实现**

`dependencies` 增加：`conatus`（git ref v0.17.0）、`args: ^2.6.0`、`http: ^1.2.0`；`dev_dependencies` 增加 `test: ^1.26.0`。执行 `flutter pub get`。
`pipeline_config.json` 按 spec §3 的 JSON 原样落盘（`voice_id: null`、`oss` 字段留空字符串占位）。
`lib/pipeline/config.dart`：`ConfigException implements Exception`；`PipelineConfig.load` 用 `dart:convert` 解析文件（文件不存在抛 `ConfigException`），`env` 缺省为 `Platform.environment`，只被 `requireApiKey`/OSS 凭证 getter 使用。字段缺省值 = spec §3 JSON。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/config_test.dart -r expanded`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add pubspec.yaml pubspec.lock pipeline_config.json lib/pipeline/config.dart test/pipeline/config_test.dart
git commit -m "feat(config): 依赖与 pipeline_config 加载"
```

---

### Task 2: 方言映射表

**Files:**
- Create: `lib/pipeline/dialect_map.dart`
- Test: `test/pipeline/dialect_map_test.dart`

**Interfaces:**
- Produces:
  - `class DialectSpec { final String label; final String instruction; }`（`instruction` 含句号，如 `请用河南话表达。`）
  - `DialectSpec resolveDialect(String region, {Map<String, DialectSpec>? table, Map<String,String>? nearby})`
  - 兜底链：`table[region]` 命中 → `nearby[region]` 就近 → `DialectSpec('mandarin', '请用普通话表达。')`

- [ ] **Step 1: 写失败测试**

```dart
test('hits henan instruction from spec list', () {
  expect(resolveDialect('河南').label, 'henan');
  expect(resolveDialect('河南').instruction, '请用河南话表达。');
});
test('falls back to nearby then mandarin', () {
  expect(resolveDialect('三沙', nearby: {'三沙': DialectSpec('hainan-ish', '请用海南话表达。')}).label, 'hainan-ish');
  expect(resolveDialect('somewhere-unknown').label, 'mandarin');
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/dialect_map_test.dart -r expanded` → FAIL

- [ ] **Step 3: 实现映射表**

内置 spec §3.2 的 21 种方言：省名/直辖市 → 标签 + `请用XX话表达。`（广东→`cantonese`/`请用广东话表达。`、四川→`sichuan` 等，标签用拼音或习用英文）。表以 `const Map<String, DialectSpec>` 覆盖省与主要城市名（如 `郑州市` → 前缀匹配到 `河南`）。就近表 `nearby` 参数留默认空实现，产品侧后续注入。

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/dialect_map.dart test/pipeline/dialect_map_test.dart
git commit -m "feat(dialect): 省市到方言指令映射与兜底链"
```

---

### Task 3: 错误分类与 state.json 状态机

**Files:**
- Create: `lib/pipeline/errors.dart`、`lib/pipeline/state.dart`
- Test: `test/pipeline/state_test.dart`

**Interfaces:**
- Produces:
  - `enum ErrorClass { transient, auditReject, staleTask, fatal }`
  - `class PipelineError implements Exception { final ErrorClass cls; final String message; final String? remoteCode; }`
  - `enum StepStatus { pending, running, succeeded, failed }`
  - `enum SegmentStatus { pending, submitted, downloading, succeeded, failed, degraded }`
  - `class ContentState`：`factory ContentState.load(String dir)`（文件不存在 → 全步骤 pending 的新实例）、`void save()`（原子：写 `.tmp` 后 rename）、`StepState step(String name)`、`List<SegmentState> segments`、`CostInfo cost`、`String contentId`、`Map<String,String> params`
  - `class StepState { StepStatus status; int attempts; List<String> t; PipelineError? error; }`
  - `class SegmentState { int i; String route /* 'i2v'|'kenburns' */; double audioS; int durationS; SegmentStatus status; int attempts; String? taskId; String? submittedAt; int costSeconds; }`
  - 段迁移方法：`SegmentState.markSubmitted(taskId)`、`markDownloading()`、`markSucceeded()`、`markDegraded(reason)`（route 改写为 `kenburns`、`costSeconds=0`）、`markFailed(ErrorClass, msg)`
  - **`SegmentState.resumableTask({required DateTime now})`**：`taskId != null && submittedAt 距 now < 24h` → 返回 taskId，否则 null（`stale_task` 判定的唯一入口）

- [ ] **Step 1: 写失败测试**

```dart
test('step status transitions and atomic save/load roundtrip', () { /* pending→running→succeeded，save 后 load 状态一致 */ });
test('audit reject marks segment degraded with zero cost', () { /* markDegraded → status degraded, route kenburns, costSeconds 0 */ });
test('resumableTask returns id within 24h and null after', () { /* submittedAt=23h59m → id；24h01m → null */ });
test('corrupt state.json throws PipelineError fatal', () { /* 写入非法 JSON → load 抛 fatal */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**

`ContentState.save()` 必须先写 `state.json.tmp` 再 `rename`（spec §6 原子发布）。`ContentState.load` 对损坏文件抛 `PipelineError(ErrorClass.fatal, ...)`。`cost` 字段由 `render` 步累计 `i2vSecondsTotal` 与 `estimatedYuan = seconds * 0.15`。

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/errors.dart lib/pipeline/state.dart test/pipeline/state_test.dart
git commit -m "feat(state): 错误分类与 state.json 状态机"
```

---

### Task 4: 工件目录与「产物存在即跳过」契约

**Files:**
- Create: `lib/pipeline/artifacts.dart`
- Test: `test/pipeline/artifacts_test.dart`

**Interfaces:**
- Produces:
  - `class Workdir { Workdir(String baseDir, String contentId); final String dir; File file(String rel); Directory dirOf(String rel); bool exists(String rel); }`
  - 工件相对路径常量（`ArtifactPaths`）：`state = 'state.json'`、`meta = 'meta.json'`、`inputsDir = '00_inputs'`、`classify = '01_classify.json'`、`select = '02_select.json'`、`script = '03_script.json'`、`audioDir = '04_audio'`、`durations = '04_audio/durations.json'`、`clipsDir = '05_clips'`、`renderStatus = '05_clips/status.json'`、`finalVideo = '06_final.mp4'`、`finalSrt = '06_final.srt'`
  - `bool stepDone(Workdir w, String artifactRel)`：文件存在且非空 → true

- [ ] **Step 1: 写失败测试**

```dart
test('workdir paths follow spec layout', () { /* dir == base/content_id，finalVideo == '06_final.mp4' */ });
test('stepDone false for missing and empty file, true for content', () { /* 三段断言 */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**（纯路径与存在性逻辑，无 IO 之外行为；`Workdir` 构造时 `createSync(recursive: true)`）

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/artifacts.dart test/pipeline/artifacts_test.dart
git commit -m "feat(artifacts): 工件目录布局与跳过契约"
```

---

### Task 5: ffmpeg/ffprobe 封装

**Files:**
- Create: `lib/pipeline/ffmpeg.dart`
- Test: `test/pipeline/ffmpeg_test.dart`

**Interfaces:**
- Produces:
  - `class FfmpegException implements Exception { final int exitCode; final String stderr; }`
  - `Future<double> mediaDurationSeconds(File media)`（ffprobe `-show_entries format=duration -v quiet -of csv=p=0`）
  - `Future<void> runFfmpeg(List<String> args)`（非 0 抛 `FfmpegException`，含 stderr）
  - 命令拼装（纯函数，返回 `List<String>`）：
    - `List<String> kenBurnsArgs({required File img, required int durationS, required File out})` → zoompan 到 1280x720 / fps 24 / h264 yuv420p
    - `List<String> normalizeArgs({required File in, required File out})` → scale+pad 1280x720、fps 24、h264、aac 保持无声
    - `List<String> muxArgs({required File video, required File audio, required double audioS, required int durationS, required File out})` → 音频 `atrim` 到 `durationS`、尾部 `apad`、`-c:v copy -c:a aac -b:a 128k`
    - `List<String> concatArgs({required List<File> parts, required File out})` → concat demuxer、`-c copy`

- [ ] **Step 1: 写失败测试**

```dart
test('mediaDurationSeconds parses ffprobe output', () async { /* 用 runFfmpeg 生成 3s 测试片后断言 ≈3.0 ±0.1（本机有 ffmpeg） */ });
test('kenBurnsArgs pins 720p/24fps/zoompan duration', () { /* 拼装结果含 'scale=1280:720'、'fps=24'、duration=3 */ });
test('muxArgs trims and pads audio to clip duration', () { /* 含 atrim/apad/aac */ });
test('runFfmpeg throws FfmpegException on bad input', () { /* 对不存在文件 → 抛 */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**（`Process.run('ffmpeg', args)` / `ffprobe`，PATH 查找；不吞 stderr）

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/ffmpeg.dart test/pipeline/ffmpeg_test.dart
git commit -m "feat(ffmpeg): 媒体时长探测与命令拼装"
```

---

### Task 6: 百炼 LLM 客户端（OpenAI 兼容直连）

**Files:**
- Create: `lib/pipeline/bailian/llm.dart`
- Test: `test/pipeline/llm_test.dart`

**Interfaces:**
- Consumes: `PipelineConfig`（Task 1）
- Produces:
  - `class QwenClient { QwenClient({required String apiKey, required String baseUrl, http.Client? client, String model = 'qwen3.8-flash'}); }`
  - `Future<String> chat({required String system, required String user, List<File>? images, int maxRetries = 2})` — images 以 data URL（base64）进 OpenAI content 数组 `{'type':'image_url','image_url':{'url':'data:image/jpeg;base64,...'}}`
  - `Future<Map<String, dynamic>> chatJson({...})` — 要求模型输出纯 JSON（system 里声明），剥 ```json 围栏后 `jsonDecode`；解析失败按 `transient` 重试
  - HTTP 错误映射（spec §6）：429/5xx/网络异常 → `PipelineError(transient)`；401/400 → `fatal`；重试间隔 1s/2s

- [ ] **Step 1: 写失败测试**（用 `package:http/testing.dart` 的 `MockClient`）

```dart
test('chat sends qwen3.8-flash with image content array', () async { /* 捕获请求：body['model']=='qwen3.8-flash'；user content 是数组且含 image_url data: 前缀；Authorization Bearer */ });
test('429 retried then succeeds', () async { /* 第一次 429、第二次 200 → 返回值正确，计数 2 */ });
test('401 maps to fatal PipelineError', () async { /* throws ErrorClass.fatal，且只请求 1 次 */ });
test('chatJson strips markdown fence and parses', () async { /* 返回 '```json\n{"a":1}\n```' → {'a':1} */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**（`dart:convert` 组包、`http.Client` 注入便于测试；图片读 `File.readAsBytesSync` 后 base64）

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/bailian/llm.dart test/pipeline/llm_test.dart
git commit -m "feat(llm): qwen3.8-flash 兼容端点客户端与错误映射"
```

---

### Task 7: 00 ingest——输入归一为本地副本

**Files:**
- Create: `lib/pipeline/steps/ingest.dart`
- Test: `test/pipeline/ingest_test.dart`

**Interfaces:**
- Consumes: `Workdir`（Task 4）、`QwenClient` 无关（本步纯 IO）
- Produces:
  - `class IngestedPhoto { final String id; /* 稳定短名 seg 序号用 */ final File file; final DateTime? capturedAt; final String source; /* 'local'|'url' */ }`
  - `Future<List<IngestedPhoto>> runIngest({required List<String> photos, required Workdir work, http.Client? client})`
  - 行为：`http(s)://` 开头 → 下载到 `00_inputs/<序号>_<文件名>`，`capturedAt` 取响应 `Last-Modified`（无则 null）；本地路径 → 直接 `File` 引用并拷贝软链与否不强制；输入为空 → `PipelineError(fatal)`；URL 下载失败 → `transient`

- [ ] **Step 1: 写失败测试**

```dart
test('url input downloaded into 00_inputs with last-modified', () async { /* MockClient 返回固定 jpeg 字节 + Last-Modified 头 → 文件存在、capturedAt 解析 */ });
test('local path passes through without copy requirement', () async { /* 本地临时文件 → file.path 原样 */ });
test('empty photos list is fatal', () async { /* throws ErrorClass.fatal */ });
test('re-run with existing copies is idempotent', () async { /* 已有 00_inputs 文件 → 不再发请求（MockClient 计数 0） */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/steps/ingest.dart test/pipeline/ingest_test.dart
git commit -m "feat(ingest): URL 与本地照片归一为本地副本"
```

---

### Task 8: 01 classify + 02 select

**Files:**
- Create: `lib/pipeline/steps/classify.dart`、`lib/pipeline/steps/select.dart`
- Test: `test/pipeline/classify_select_test.dart`

**Interfaces:**
- Consumes: `QwenClient.chatJson`（Task 6）、`IngestedPhoto`（Task 7）、`PipelineConfig.targetCount`
- Produces:
  - `class PhotoInfo { final String id; final bool hasPerson; /* unknown 折叠为 true */ final int quality; /* 1..5 */ final String motionHint; final String caption; final bool personUnknown; }`
  - `Future<List<PhotoInfo>> runClassify({required List<IngestedPhoto> photos, required QwenClient llm})` — system prompt 固定要求输出 `{"has_person":bool,"quality":1-5,"motion_hint":str,"caption":str}`；单图失败重试 1 次后 `has_person=true, personUnknown=true`（spec §4-01 保守降级）
  - `List<PhotoInfo> selectPhotos({required List<PhotoInfo> all, required List<IngestedPhoto> order, int count, bool userPicked})` — `userPicked=true` 时全部透传；否则：内容哈希去重（sha1 同则视为重复）→ 按 `quality` 降序 → 取前 N；`capturedAt` 可得时保证时间分布（首、中、尾优先）；不足 N 有几张用几张

- [ ] **Step 1: 写失败测试**（MockClient 构造返回固定 JSON 的 `QwenClient`）

```dart
test('classify parses fields and folds unknown into person route', () async { /* 模拟 llm 抛错 2 次 → hasPerson true, personUnknown true */ });
test('select dedupes identical content and takes top N by quality', () { /* 5 张含 1 对同内容 → 选 4 中无重复 */ });
test('userPicked bypasses ranking', () { /* 顺序原样 */ });
test('fewer photos than count uses what exists', () { /* 2 张 count=4 → 2 */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/steps/classify.dart lib/pipeline/steps/select.dart test/pipeline/classify_select_test.dart
git commit -m "feat(select): 多模态判定与选片规则"
```

---

### Task 9: 03 script——分段口播与动效 prompt

**Files:**
- Create: `lib/pipeline/steps/script.dart`
- Test: `test/pipeline/script_test.dart`

**Interfaces:**
- Consumes: `QwenClient.chatJson`（Task 6）、`List<PhotoInfo>`（Task 8）
- Produces:
  - `class SegmentScript { final String photoId; final String line; /* ≤20 字书面语，无控制标签 */ final String? motionPrompt; /* 仅非人物段 */ }`
  - `class VideoScript { final List<SegmentScript> segments; final int totalChars; }`
  - `Future<VideoScript> runScript({required List<PhotoInfo> selected, required QwenClient llm})` — system prompt 要求：每段一句、标准书面语、合计 60–80 字、JSON 数组输出；非人物段的 `motion_prompt` 由 `motionHint` + 固定模板合成，模板含**硬约束句**「主体保持静止，仅背景与光影缓慢变化」（spec §4-03）；解析后校验段数 = 照片数、单段 ≤40 字，违规按 `transient` 重试 1 次

- [ ] **Step 1: 写失败测试**

```dart
test('script produces one line per photo with total 60-80 chars', () async { /* Mock 返回 4 段 → 断言 count 与 totalChars 区间 */ });
test('person photo gets null motionPrompt, scenery gets template with static-subject constraint', () { /* motionPrompt 含 '主体保持静止' */ });
test('lines contain no control tags', () { /* 无 [xxx] 匹配 */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/steps/script.dart test/pipeline/script_test.dart
git commit -m "feat(script): 分段口播与动效 prompt 生成"
```

---

### Task 10: 方言 TTS 客户端 + 04 tts 步骤

**Files:**
- Create: `lib/pipeline/bailian/tts.dart`、`lib/pipeline/steps/tts_step.dart`
- Test: `test/pipeline/tts_test.dart`

**Interfaces:**
- Consumes: `DialectSpec`（Task 2）、`PipelineConfig`（Task 1）、`ffmpeg.mediaDurationSeconds`（Task 5）
- Produces:
  - `class TtsClient { TtsClient({required String apiKey, http.Client? client}); }`
  - `Future<TtsAudio> synth({required String text, required String model, String? voiceId, String? fallbackVoice, required String instruction})` — `POST {wsBase}/api/v1/services/audio/tts/SpeechSynthesizer`（`wss://` 对应的 https 形式 `https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer`）；body：`model`、`input:{text: '[very slowly]' + text, voice: voiceId ?? fallbackVoice, format:'wav', sample_rate:24000}` + `model.startsWith('qwen-audio') ? {'instruction': ...} : {'instructions': ...}`（Global Constraints 参数名规则）
  - `class TtsAudio { final File wav; final double seconds; }`
  - `Future<List<TtsAudio>> runTtsStep({required VideoScript script, required DialectSpec dialect, required PipelineConfig cfg, required TtsClient tts, required Workdir work, required ContentState state})` — 逐段落 `04_audio/seg_<i>.wav` + `durations.json`；方言合成失败（`transient` 重试 1 次后仍败）→ 该段指令降级 `请用普通话表达。` 重合成；普通话也失败 → `PipelineError(fatal)`；音频 URL 若先返回再下载，必须立即转存后才推进（spec §4 24h 约束）

- [ ] **Step 1: 写失败测试**

```dart
test('qwen-audio model sends instruction param, qwen3 sends instructions', () async { /* 两个模型各捕获一次 body */ });
test('text prefixed with [very slowly] and wav 24000 requested', () { /* body.input.text.startsWith('[very slowly]') */ });
test('dialect failure falls back to mandarin then succeeds', () async { /* 第一段 500 → 第二次请求 instruction=='请用普通话表达。' */ });
test('durations.json written with measured seconds', () async { /* Mock 返回生成的 wav 字节 → ffprobe 时长写入 */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**（wav 字节由 `http` 响应体直接写文件；测试用 MockClient 返回 `ffmpeg -f lavfi -i sine` 生成的 fixture wav 字节）

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/bailian/tts.dart lib/pipeline/steps/tts_step.dart test/pipeline/tts_test.dart
git commit -m "feat(tts): 方言音轨合成与普通话降级"
```

---

### Task 11: ImageUrlProvider——DashScope 上传优先、OSS 兜底

**Files:**
- Create: `lib/pipeline/bailian/uploader.dart`
- Test: `test/pipeline/uploader_test.dart`

**Interfaces:**
- Consumes: `PipelineConfig`（Task 1）
- Produces:
  - `class ImageUrl { final String url; final DateTime expiresAt; }`
  - `abstract class ImageUrlProvider { Future<ImageUrl> publish(File photo); String get name; }`
  - `class DashScopeUploadProvider implements ImageUrlProvider` — `POST https://dashscope.aliyuncs.com/api/v1/uploads`（multipart `file`），响应取可访问 URL
  - `class OssSignedUrlProvider implements ImageUrlProvider` — 签名上传实验桶（`OSS_ACCESS_KEY_*` + bucket/endpoint 来自配置）
  - `ImageUrlProvider pickProvider({required String prefer, required PipelineConfig cfg, required http.Client client})` — `prefer: 'dashscope'`（默认）| `'oss'`；Review Focus #1 的切换开关

- [ ] **Step 1: 写失败测试**

```dart
test('DashScopeUploadProvider parses upload response url', () async { /* MockClient multipart 响应 {"url": "..."} → ImageUrl.url */ });
test('provider selection switches on prefer flag', () { /* 'oss' → OssSignedUrlProvider 实例 */ });
test('upload failure maps to transient', () async { /* 500 → ErrorClass.transient */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**（OSS 签名用 `package:http` 直接发 PUT + HMAC-SHA1 签名头，不引 OSS SDK；本期实现以测试可离线验证为准，真实签名验证留给 Task 16）

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/bailian/uploader.dart test/pipeline/uploader_test.dart
git commit -m "feat(uploader): 可插拔图片 URL 发布与提供方切换"
```

---

### Task 12: 万相 i2v 客户端 + 05 render

**Files:**
- Create: `lib/pipeline/bailian/i2v.dart`、`lib/pipeline/steps/render.dart`
- Test: `test/pipeline/i2v_render_test.dart`

**Interfaces:**
- Consumes: `ContentState`（Task 3）、`ffmpeg`（Task 5）、`ImageUrlProvider`（Task 11）、`TtsAudio.seconds`（Task 10）、`SegmentScript`（Task 9）
- Produces:
  - `enum I2vStatus { running, succeeded, failed }`
  - `class I2vTask { final String taskId; final I2vStatus status; final Uri? videoUrl; final String? errorCode; }`
  - `class I2vClient { I2vClient({required String apiKey, http.Client? client}); }`
    - `Future<I2vTask> submit({required String imgUrl, required String prompt, required int durationS})` — `POST .../video-synthesis` + header `X-DashScope-Async: enable`；body **必须显式**含 `model`、`input:{img_url,prompt}`、`parameters:{resolution:'720P', duration:<int>, audio:false, prompt_extend:true, shot_type:'multi', watermark:true, seed:<cfg>}`（Review Focus #3）
    - `Future<I2vTask> poll(String taskId)` — `GET .../tasks/{taskId}`；响应 `output.task_status` 映射；错误码含 `IPInfringementSuspect|DataInspectionFailed` → `errorCode` 保留（供 render 判 `audit_reject`）
  - `Future<void> runRenderStep({required List<SegmentScript> scripts, required List<TtsAudio> audios, required List<PhotoInfo> photos, required Workdir work, required ContentState state, required I2vClient i2v, required ImageUrlProvider urls, required PipelineConfig cfg})`
    - 每段：`durationS = clamp(ceil(audio.seconds), cfg.minClipS, cfg.maxClipS)`
    - 路由：`hasPerson || personUnknown` → `kenBurnsArgs` 直出 `05_clips/seg_<i>.mp4`；否则 i2v
    - i2v 流程：`state.resumableTask()` 有值 → **直接 poll**（不 submit）；submit 后立刻 `markSubmitted(taskId)` 落盘 → 每 `poll_seconds` 轮询至 `max_wait_minutes` → succeeded 立即下载到本地 `05_clips/seg_<i>.mp4` 后 `markSucceeded`
    - `audit_reject` → `markDegraded` + Ken Burns 补渲染；`transient` 重试 ×2；下载成功才计 `costSeconds = durationS`
    - 全部段输出后统一 `normalizeArgs` 归一化 1280x720/24fps，写 `05_clips/status.json`

- [ ] **Step 1: 写失败测试**（MockClient 全程离线；视频字节用 ffmpeg 预生成的 fixture）

```dart
test('submit body pins 720P audio=false duration watermark seed', () async { /* 捕获 body 逐字段断言 */ });
test('person segment never calls submit (kenBurns only)', () async { /* MockClient 计数 submit==0 */ });
test('resume polls existing task_id without resubmitting', () async { /* state 预置 taskId+submittedAt=1h前 → poll 计数>0, submit==0（Review Focus #2） */ });
test('stale task older than 24h triggers fresh submit', () async { /* submittedAt=25h前 → submit==1 */ });
test('audit reject degrades to kenburns with zero cost', () async { /* errorCode=IPInfringementSuspect → status degraded, route kenburns, clip 存在 */ });
test('segments normalized to 1280x720/24fps', () { /* normalizeArgs 被调用/输出文件可 ffprobe 断言 */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**（轮询期间每次状态变化都要 `state.save()`——进程随时可能被 kill）

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/bailian/i2v.dart lib/pipeline/steps/render.dart test/pipeline/i2v_render_test.dart
git commit -m "feat(render): 万相异步任务、恢复轮询与 Ken Burns 降级"
```

---

### Task 13: 06 compose + SRT

**Files:**
- Create: `lib/pipeline/steps/compose.dart`、`lib/pipeline/srt.dart`
- Test: `test/pipeline/srt_test.dart`、`test/pipeline/compose_test.dart`

**Interfaces:**
- Consumes: `ffmpeg`（Task 5）、`SegmentState.durationS`、`TtsAudio.seconds`、`SegmentScript.line`
- Produces:
  - `lib/pipeline/srt.dart`（纯函数，可独立测试）：
    - `String stripControlTags(String line)` — 移除 `\[([^\]]*)\]`（Review Focus #4）
    - `List<SrtEntry> buildSrt({required List<SegmentInput> segs})`，`SegmentInput { String line; double startVideoS; double videoDurationS; double audioS; }`
    - `class SrtEntry { int index; Duration start; Duration end; String text; }`
    - 规则：`start = startVideoS`、`end = min(start + audioS, start + videoDurationS)`；`>40` 字拆两条按字符比例分时；每条 end ≤ 下一条 start（自动校验）
    - `String renderSrt(List<SrtEntry> e)` — `HH:MM:SS,mmm` 格式、`\n` 行分隔、末尾单换行、**无 BOM**
  - `Future<File> runComposeStep({required Workdir work, required ContentState state, required List<SegmentScript> scripts, required List<TtsAudio> audios, ...})` — 逐段 `muxArgs` → `06_concat/seg_i.mp4` → `concatArgs` → `06_final.mp4`；写 `06_final.srt`；`ffprobe` 校验 `|视频总长-音频总长| ≤ 0.2s`，超差抛 `PipelineError(fatal, 'av_mismatch')`（Review Focus #5）

- [ ] **Step 1: 写失败测试**

```dart
test('stripControlTags removes [very slowly] keeps sentence', () { /* '[very slowly]今天天气很好' → '今天天气很好' */ });
test('entry end uses audio length capped by video length', () { /* audio 4.6/video 5 → end-start 4.6s；audio 5.4/video 5 → 5.0s */ });
test('long line splits into two entries proportional to chars', () { /* 48 字 → 2 entries，时长比 ≈ 字数比 */ });
test('render output has no BOM and LF endings', () { /* 首三字节非 EF BB BF；无 \r */ });
test('av mismatch beyond 0.2s fails compose', () async { /* fixture 构造 5s 视频 + 6s 音频 → throws av_mismatch（Review Focus #5） */ });
test('offline compose produces playable final.mp4 + srt', () async { /* 2 段 fixture 走全步骤 → ffprobe 断言时长与 srt 存在 */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/steps/compose.dart lib/pipeline/srt.dart test/pipeline/srt_test.dart test/pipeline/compose_test.dart
git commit -m "feat(compose): 拼接、SRT 生成与音画校验"
```

---

### Task 14: 编排器 + `generate_monthly_video` 工具

**Files:**
- Create: `lib/pipeline/orchestrator.dart`、`lib/pipeline/monthly_video_tool.dart`
- Test: `test/pipeline/orchestrator_test.dart`

**Interfaces:**
- Consumes: 全部 steps（Tasks 7–13）、`ContentState`（Task 3）、`resolveDialect`（Task 2）、`pickProvider`（Task 11）
- Produces:
  - `class PipelineInput { final List<String> photos; final String dialect; final int count; final String contentId; final bool dryRun; }`
  - `class PipelineResult { final String contentId; final String status; /* 'completed'|'dry_run'|'failed' */ final String? videoPath; final String? srtPath; final List<SegmentSummary> segments; final double estimatedYuan; final String? plan; }`
  - `class VivaPipeline { VivaPipeline({required PipelineConfig cfg, QwenClient? llm, TtsClient? tts, I2vClient? i2v, ImageUrlProvider? urls, http.Client? http}); Future<PipelineResult> run(PipelineInput input); }`
  - 执行顺序：load/初始化 state 并写 `meta.json`（params 快照）→ ingest → classify → select → script → tts → **dryRun 到此为止**（spec §4：跑到 04 后停；返回 plan：各段实测音频秒数换算的 i2v 段数、Ken Burns 段数、`i2vSeconds * 0.15` 元估算）→ render → compose；每步前后 `state.save()`；每步开始前按 Task 4 契约查工件 skip
  - `class GenerateMonthlyVideoTool extends Tool`（`package:conatus_foundation`）：`name = 'generate_monthly_video'`、`riskLevel = ToolRisk.high`、`params`：`photos`（array of string，required）、`dialect`（string，required）、`count`（integer，defaultValue 4）、`content_id`（string）、`dry_run`（boolean，defaultValue false）；`call()` 把参数组装成 `PipelineInput` 跑 `VivaPipeline`，返回 `ToolResult.success(jsonEncode(result))`；`PipelineError(fatal)` → `ToolResult.failure`

- [ ] **Step 1: 写失败测试**（全 fake：MockClient 按 URL 路由 LLM/TTS/i2v/upload，fixture 图片与 wav/视频字节）

```dart
test('full offline pipeline yields final.mp4 + srt with state completed', () async { /* 3 张图（1 张 has_person=true）→ status completed、segments 3、i2v 段 2、06_final.mp4 存在 */ });
test('rerun skips every step (zero http calls)', () async { /* 第二次 run → MockClient 计数 0，status completed（幂等契约） */ });
test('dry run stops after tts with cost plan', () async { /* 返回 plan 含 i2v 段数与 0.15*seconds 估算；tts 计数>0、i2v 计数 0 */ });
test('tool schema exposes spec params and high risk', () { /* toSchema()['parameters'] 含 photos/dialect/count/content_id/dry_run；riskLevel==high */ });
test('dialect unknown region still completes via mandarin', () { /* dialect='nowhere' → tts 请求 instruction 为普通话 */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**（skip 判定用 `stepDone`；`render`/`compose` 内部段级幂等由各自 state 保证，编排器只管步级）

- [ ] **Step 4: 跑测试确认通过** → PASS

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/orchestrator.dart lib/pipeline/monthly_video_tool.dart test/pipeline/orchestrator_test.dart
git commit -m "feat(pipeline): 编排器与 generate_monthly_video 工具"
```

---

### Task 15: 实验 host `bin/conatus_host.dart`

**Files:**
- Create: `bin/conatus_host.dart`
- Test: `test/pipeline/host_smoke_test.dart`（仅离线可验部分）

**Interfaces:**
- Consumes: `GenerateMonthlyVideoTool`（Task 14）、`PipelineConfig.load`（Task 1）、conatus：`Context`、`provideTools`、`provideLlm(OpenAiCompatibleProvider(...))`、`provideAgentLoop`、`AutoApproval`、`provideSystemPrompt`
- Produces:
  - CLI：`dart run bin/conatus_host.dart --photos <path[,path]|dir> --dialect <region> [--count 4] [--content-id X] [--dry-run] [--agent "自然语言任务"] [--prefer-provider dashscope|oss]`
  - 默认路径：组装 `ToolCall` 直接 `ctx.tools.call(...)`，stdout 打印 `PipelineResult` JSON；`--agent` 路径：把参数包成一句任务交 `AgentLoop.run`，会话日志开在 `pipeline_out/host-session/`
  - 启动时校验 `DASHSCOPE_API_KEY` 缺失 → 打印指引并退出码 2

- [ ] **Step 1: 写失败测试**

```dart
test('host registers tool with high risk and required params', () async { /* 抽出装配函数 createHost(config) → ctx.tools.describe() 含 generate_monthly_video */ });
test('missing api key exits with code 2 message', () { /* 纯函数 validateEnv(env) → 错误信息文案 */ });
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现**（装配逻辑抽成 `Future<Context> createHost(...)` 供测试；`main()` 只做参数解析 + 调用；`--agent` 的 LLM 用 conatus `OpenAiCompatibleProvider`，`model` 取配置）

- [ ] **Step 4: 跑测试确认通过 + analyze**

Run: `dart test test/pipeline/host_smoke_test.dart -r expanded && dart analyze lib bin test`
Expected: PASS，0 issues

- [ ] **Step 5: Commit**

```bash
git add bin/conatus_host.dart test/pipeline/host_smoke_test.dart
git commit -m "feat(host): conatus 实验宿主与 CLI"
```

---

### Task 16: M0 真钱冒烟（手动执行，≈2.25–3 元/次）

**Files:**
- Create: `docs/superpowers/plans/m0-smoke-report.md`（执行记录）

**Interfaces:**
- Consumes: 全部前置任务；需要真实 `DASHSCOPE_API_KEY`
- Produces: M0 出口记录（spec §7 清单逐项打勾）

- [ ] **Step 1: 单图 URL 冒烟（Review Focus #1，最先做，≈0.3–1.5 元）**

准备 1 张风景照，跑单照片全管线：`DashScopeUploadProvider.publish` 产出的 URL 交给万相，观察 render 步日志与 `state.json`——任务 SUCCEEDED 即证明「DashScope 上传 URL 可被万相拉取」。
Run: `DASHSCOPE_API_KEY=... dart run bin/conatus_host.dart --photos <1张风景照> --dialect 河南 --count 1 --content-id m0-url`
Expected: `pipeline_out/m0-url/06_final.mp4` 产出。**若 img_url 被拒** → 加 `--prefer-provider oss` 并配 OSS 凭证重跑，在报告记录切换原因；此开关不通则整条管线无法处理本地照片（M0 阻塞项）。

- [ ] **Step 2: 全程冒烟**

Run: `DASHSCOPE_API_KEY=... dart run bin/conatus_host.dart --photos <3-4张混合人物与风景> --dialect 河南 --content-id m0-1`
检查清单（逐项记录进报告）：
- `pipeline_out/m0-1/06_final.mp4` 可播，总长 15–20s，`|视频-音频| ≤ 0.2s`
- 人物段 Ken Burns、风景段 i2v（看 `05_clips/status.json` 的 route）
- 方言听感人工评审（记录结论与需调整项）
- `06_final.srt` 逐段与语音对齐（VLC 加载）
- `state.json` 的 `cost.estimatedYuan ≈ i2vSeconds * 0.15`

- [ ] **Step 3: 幂等与中断恢复验证**

- 立即重跑 Step 2 命令 → Expected: 各步全部 skip、stdout 零新 i2v 提交、耗时 <10s
- 清掉 `06_final.mp4` 之外的 `05_clips` 后产物、保留 state（模拟 render 中断）→ 重跑 → Expected: 已提交段按 `task_id` 恢复轮询，`state.json` 无新增 submit 记录

- [ ] **Step 4: `--agent` 模式验证**

Run: `DASHSCOPE_API_KEY=... dart run bin/conatus_host.dart --photos ... --dialect 四川 --agent "为这些照片生成本月相册视频"`
Expected: AgentLoop 自主调用 `generate_monthly_video` 产出同样的 `06_final.mp4`

- [ ] **Step 5: Commit 报告**

```bash
git add docs/superpowers/plans/m0-smoke-report.md
git commit -m "docs(m0): 真钱冒烟执行记录"
```
