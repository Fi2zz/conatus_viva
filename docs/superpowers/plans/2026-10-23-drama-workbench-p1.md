# 短剧工作台 P1（骨架 + 创作闭环）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把应用收敛为「短剧工作台」单一入口，落地多剧多集存储、故事→分镜→计划单的完整创作闭环，并把五个既有能力以可嵌入组件形式挂进对应工序。

**Architecture:** 新增 `lib/pipeline/drama/` 领域层（IDs、剧/集模型、状态、存储、状态推导、费用估算、LLM 草稿、HTTP controller），通过 `/api/drama/*` 暴露给前端。前端新增工作台壳与工序舞台，复用现有 `ImageStudio` / `VideoStudio` / `EditCostEstimator`，并把主讲人逻辑从 `App.tsx` 提取为 `SpeakerStudio`。相册六步管线不改。

**Tech Stack:** Dart 3.12（`package:test`、`package:crypto`）、React 19 + TypeScript + Vite 8 + vitest + oxlint。**不新增任何依赖。**

**Spec:** `docs/superpowers/specs/2026-10-23-drama-workbench-design.md`

## Global Constraints

- `lib/pipeline/**`、`lib/server/**` 禁止 `import 'package:flutter/...'`。
- 不新增 Dart / npm 依赖；路径拼接用 `dart:io` + 字符串，不引入 `package:path`。
- 价格只能来自 `generation_models.dart` 与 `pipeline_config.json` 的 `pricing.*`；不允许硬编码价格。
- 付费动作必须过费用闸门；P1 的 LLM 调用标「未估价」，前端必须勾选知悉。
- `state.json` 幂等与「产物存在即跳过」契约不可绕过；P1 不生成图片/视频/TTS 产物，只建立状态与 hash 基础。
- 密钥只走环境变量；禁止打印、记录、回显任何 key。
- server 只绑 `InternetAddress.loopbackIPv4`；不改成 `0.0.0.0`。
- 前端只经本地 `/api` 访问后端；不得使用 `window.confirm/alert`。
- `web_build/` 是入库产物：任何改到 UI 的 task 必须 `make web` 并提交生成物。
- 测试必须离线：LLM 用 fake，禁止真实网络；不提交 `pipeline_out/`、`.env`、密钥。
- 显式 `git add <文件列表>`，禁止 `git add -A` / `git add .`。
- Dart 输出用 `stdout.writeln` / `stderr.writeln`，不用 `print`。
- 错误统一走 `PipelineError` + `ErrorClass`；纯函数参数错误用 `ArgumentError`；不新造平行异常类。
- 所有新增 JSON 文件写入必须 tmp + rename 原子发布；中文注释。

## Review Focus

1. **ID / 路径逃逸**：`series_id`、`episode_id` 含 `/`、`..`、`.`、空串、超过 64 字符时，API 必须 400，且不能读写 `pipeline_out` 之外的任何文件。Task 2/4/7 各有测试。
2. **损坏或缺失的文件**：缺失 `series.json` / `episode.json` / `storyboard.json` 应 404 或返回 `null`，不能让整个列表或工作台崩溃。Task 4/7 覆盖。
3. **LLM 不可修复输出**：非法 JSON、缺 `shots`、类型错误必须重试一次后返回 422，且**不落盘**。Task 6/7 覆盖。
4. **预算与时长边界**：`total_budget_yuan` / `i2v_budget_yuan` 为 0、负数、NaN；分镜 `duration_s` 为 0、负数、非数字；必须 400 且不生成计划单。Task 2/5/7/8 覆盖。
5. **重复创建 / 并发写**：同一 `series_id`、`episode_id` 重复创建必须 409；不能出现半截 JSON。Task 4/7 覆盖。
6. **中文往返**：故事文本、台词、角色名、`voice_id` 经过 JSON 存取必须保持 UTF-8，不能乱码。Task 4/7 覆盖。
7. **空工作台**：没有剧、没有集、没有分镜时，前端必须走创建空态，不白屏、不伪造工序完成。Task 9/10 覆盖。
8. **未接入工序**：`run` 未接入工序必须 501；UI 显示「未接入」，不能显示假进度。Task 7/9/11 覆盖。

---

## File Structure

**Dart（新增）**

| 文件 | 职责 |
|---|---|
| `lib/pipeline/drama/ids.dart` | ID 校验 |
| `lib/pipeline/drama/json.dart` | JSON 类型读取助手 |
| `lib/pipeline/drama/series.dart` | 剧、角色、默认值、节拍模板 |
| `lib/pipeline/drama/episode.dart` | 集、源文本、故事、设置 |
| `lib/pipeline/drama/hash.dart` | canonical JSON + SHA-256 |
| `lib/pipeline/drama/state.dart` | 工序/镜头产物状态、成本 |
| `lib/pipeline/drama/steps.dart` | 8 工序推导、计划 hash |
| `lib/pipeline/drama/store.dart` | 原子读写、剧集目录、资源路径安全 |
| `lib/pipeline/drama/cost.dart` | 费用估算、计划单构建、i2v 单价 |
| `lib/pipeline/drama/llm.dart` | `DramaLlm`、拆片/分镜草稿、重试与校验 |
| `lib/pipeline/drama/controller.dart` | `/api/drama/*` 二级路由与处理 |

**Dart（修改）**

| 文件 | 改动 |
|---|---|
| `lib/pipeline/storyboard.dart` | `Shot.visual` 可选字段与 wire 序列化 |
| `lib/server/api_router.dart` | 增加 `ApiRoute.drama` |
| `lib/server/pipeline_server.dart` | 接线 controller、注入 seam |
| `Makefile` | 新 server 测试加入 `DART_TEST_CMD` |

**前端（新增）**

| 文件 | 职责 |
|---|---|
| `frontend/src/shortDrama/types.ts` | 后端 wire 类型 |
| `frontend/src/shortDrama/api.ts` | `/api/drama/*` 客户端 |
| `frontend/src/shortDrama/storyboard.ts` | 分镜草稿 ↔ wire、校验 |
| `frontend/src/shortDrama/view.ts` | 工序顺序/标签/预算/状态文案 |
| `frontend/src/shortDrama/WorkbenchShell.tsx` | 三栏壳体 |
| `frontend/src/shortDrama/WorkbenchHeader.tsx` | 顶栏 |
| `frontend/src/shortDrama/StepRail.tsx` | 左栏 8 工序 |
| `frontend/src/shortDrama/Inspector.tsx` | 右栏检视 |
| `frontend/src/shortDrama/FooterMeters.tsx` | 底栏 |
| `frontend/src/shortDrama/CanvasView.tsx` | 画布视图（真实 steps） |
| `frontend/src/shortDrama/EntryForms.tsx` | 新建剧/集空态 |
| `frontend/src/shortDrama/StoryboardTable.tsx` | 可编辑分镜表 |
| `frontend/src/shortDrama/PlanSummary.tsx` | 计划单/预算/告警 |
| `frontend/src/shortDrama/DramaCostGate.tsx` | 未估价可勾选的费用闸门 |
| `frontend/src/shortDrama/stages/SplitStage.tsx` | 拆片 |
| `frontend/src/shortDrama/stages/StoryStage.tsx` | 故事/节拍/角色 |
| `frontend/src/shortDrama/stages/BoardStage.tsx` | 分镜表 + 计划单 |
| `frontend/src/shortDrama/stages/CastStage.tsx` | 定妆 |
| `frontend/src/shortDrama/stages/FrameStage.tsx` | 画面 |
| `frontend/src/shortDrama/stages/VoiceStage.tsx` | 声音 |
| `frontend/src/shortDrama/stages/EditStage.tsx` | 剪辑成本 |
| `frontend/src/shortDrama/stages/PackStage.tsx` | 打包占位 |
| `frontend/src/SpeakerStudio.tsx` | 从 App 提取的主讲人工具 |
| `frontend/src/shortDrama/*.test.ts` | 纯函数测试 |

**前端（修改）**

| 文件 | 改动 |
|---|---|
| `frontend/src/ShortDrama.tsx` | 重写为工作台入口 |
| `frontend/src/App.tsx` | 删除五个 tab，只渲染工作台 |
| `frontend/src/ImageStudio.tsx` | 可选 `initialPrompt` / `contextLabel` |
| `frontend/src/VideoStudio.tsx` | 可选 `initialPrompt` / `contextLabel` |
| `frontend/src/shortDrama/pipelineDag.ts` | 画布节点读真实 steps |
| `frontend/src/shortDrama/ShortDrama.css` | 原型深色工作台样式 |
| `frontend/src/shortDrama/model.ts` | 增加 `budgetPercent` 等纯函数 |
| `web_build/**` | `make web` 生成并提交 |

---

### Task 1: 分镜表支持画面提示词

**Files:**
- Modify: `lib/pipeline/storyboard.dart`
- Test: `test/pipeline/storyboard_test.dart`

**Interfaces:**
- Produces: `Shot.visual`（`String?`）、`Shot.toJson()` 的 `'visual'` 键、解析时缺省 `null`。

- [ ] **Step 1: 写失败测试**

在 `test/pipeline/storyboard_test.dart` 的 full-input 与 roundtrip 组内加：

```dart
test('visual prompt parses, serializes and defaults to null', () {
  final withVisual = Storyboard.fromJson(<String, Object?>{
    'content_id': 'ep01',
    'shots': <Object?>[
      <String, Object?>{'id': 's01', 'kind': 'insert', 'visual': '堂屋逆光，借条特写'},
    ],
  });
  expect(withVisual.shots.single.visual, '堂屋逆光，借条特写');
  expect(
    (withVisual.toJson()['shots']! as List<Object?>).first,
    containsPair('visual', '堂屋逆光，借条特写'),
  );

  final withoutVisual = Storyboard.fromJson(minimalJson());
  expect(withoutVisual.shots.single.visual, isNull);
  expect(
    (withoutVisual.toJson()['shots']! as List<Object?>).first,
    containsPair('visual', null),
  );
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/storyboard_test.dart -n "visual prompt"`
Expected: FAIL，`Shot` 没有 `visual`。

- [ ] **Step 3: 实现字段**

`Shot` 增加 `final String? visual;`、构造函数可选参数、`toJson` 的 `'visual': visual`；`_parseShots` 用 `_optionalString(map['visual'], 'shots[$id].visual')` 填充。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/storyboard_test.dart`
Expected: PASS 全绿。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/storyboard.dart test/pipeline/storyboard_test.dart
git commit -m "feat(short-drama): 分镜表支持画面提示词"
```

---

### Task 2: 剧集领域模型与 JSON 校验

**Files:**
- Create: `lib/pipeline/drama/ids.dart`
- Create: `lib/pipeline/drama/json.dart`
- Create: `lib/pipeline/drama/series.dart`
- Create: `lib/pipeline/drama/episode.dart`
- Test: `test/pipeline/drama/ids_test.dart`
- Test: `test/pipeline/drama/series_test.dart`
- Test: `test/pipeline/drama/episode_test.dart`

**Interfaces:**
- Produces:
  - `bool isDramaId(String value)`；`void requireDramaId(String value, String field)`
  - `Map<String, Object?> asJsonMap(Object? raw, String field)`、`List<Object?> asJsonList(Object? raw, String field)`、`String requireJsonString(Object? raw, String field)`、`String? optionalJsonString(Object? raw, String field)`、`double? optionalJsonNumber(Object? raw, String field)`、`int? optionalJsonInt(Object? raw, String field)`、`bool optionalJsonBool(Object? raw, String field, {required bool fallback})`
  - `class DramaSeries`、`DramaDefaults`、`DramaCastMember`、`DramaCastAvatar`、`DramaBeat`
  - `class DramaEpisode`、`DramaSource`、`DramaStory`、`DramaSettings`
- 所有 `fromJson` 对结构错误抛 `PipelineError(ErrorClass.fatal, ...)`；ID 校验失败也抛 `PipelineError.fatal`。

- [ ] **Step 1: 写失败测试**

`series_test.dart` / `episode_test.dart` 顶部复用 `storyboard_test.dart` 的 `expectFatal` 助手。

`ids_test.dart`：

```dart
test('accepts 1..64 safe chars and rejects traversal', () {
  expect(isDramaId('ep07'), isTrue);
  expect(isDramaId('ep-07_A'), isTrue);
  expect(isDramaId(''), isFalse);
  expect(isDramaId('../ep07'), isFalse);
  expect(isDramaId('ep.07'), isFalse);
  expect(isDramaId('a' * 65), isFalse);
  expect(() => requireDramaId('bad/id', 'series_id'), throwsArgumentError);
});
```

`series_test.dart`：

```dart
test('parses defaults, cast and beat template', () {
  final series = DramaSeries.fromJson(<String, Object?>{
    'series_id': 'jietiao',
    'title': '借条',
    'dialect': 'henan',
    'frame': '1080x1920',
    'planned_episodes': 80,
    'defaults': <String, Object?>{
      'total_budget_yuan': 120,
      'i2v_budget_yuan': 20,
      'max_i2v_seconds': 0,
    },
    'beat_template': <Object?>[
      <String, Object?>{'id': 'hook', 'label': '钩子', 'summary': '借条拍桌', 'weight': 3},
    ],
    'cast': <String, Object?>{
      'erniu': <String, Object?>{
        'name': '二舅',
        'description': '五十岁，旧夹克',
        'voice_id': 'voice-1',
        'dialect': 'henan',
      },
    },
  });
  expect(series.seriesId, 'jietiao');
  expect(series.frame.label, '1080x1920');
  expect(series.defaults.totalBudgetYuan, 120);
  expect(series.defaults.clipVideoModel, 'wan2.6-i2v-flash');
  expect(series.beatTemplate.single.label, '钩子');
  expect(series.cast['erniu']!.voiceId, 'voice-1');
  expect(series.storyboardCast()['erniu']!.name, '二舅');
});

test('rejects invalid id, frame and non-positive budget', () {
  expectFatal(() => DramaSeries.fromJson({'series_id': '../x', 'title': 'x'}));
  expectFatal(() => DramaSeries.fromJson({'series_id': 'ok', 'title': 'x', 'frame': 'wide'}));
  expectFatal(() => DramaSeries.fromJson({
    'series_id': 'ok', 'title': 'x',
    'defaults': <String, Object?>{'total_budget_yuan': 0},
  }));
});
```

`episode_test.dart`：

```dart
test('create copies series defaults and beat template', () {
  final series = DramaSeries.fromJson(<String, Object?>{
    'series_id': 'jietiao', 'title': '借条', 'dialect': 'henan',
    'defaults': <String, Object?>{'total_budget_yuan': 88, 'i2v_budget_yuan': 18},
    'beat_template': <Object?>[
      <String, Object?>{'id': 'hook', 'label': '钩子', 'summary': '开场'},
    ],
  });
  final episode = DramaEpisode.create(
    series: series, episodeId: 'ep07', title: '堂屋对峙', number: 7,
  );
  expect(episode.settings.totalBudgetYuan, 88);
  expect(episode.settings.i2vBudgetYuan, 18);
  expect(episode.story.beats.single.id, 'hook');
  expect(episode.story.promptVersion, 1);
  expect(DramaEpisode.fromJson(episode.toJson()).toJson(), episode.toJson());
});

test('rejects non-positive settings', () {
  expectFatal(() => DramaEpisode.fromJson(<String, Object?>{
    'series_id': 'jietiao', 'episode_id': 'ep07', 'title': 'x',
    'settings': <String, Object?>{'total_budget_yuan': -1},
  }));
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/drama`
Expected: FAIL，文件/类不存在。

- [ ] **Step 3: 实现模型**

签名：

```dart
// ids.dart
bool isDramaId(String value);
void requireDramaId(String value, String field);

// series.dart
class DramaSeries {
  const DramaSeries({
    required this.seriesId, required this.title, required this.logline,
    required this.dialect, required this.frame, required this.contentType,
    required this.plannedEpisodes, required this.defaults,
    required this.beatTemplate, required this.cast,
  });
  final String seriesId, title, logline, dialect, contentType;
  final FrameSize frame;
  final int plannedEpisodes;
  final DramaDefaults defaults;
  final List<DramaBeat> beatTemplate;
  final Map<String, DramaCastMember> cast;
  factory DramaSeries.create({
    required String seriesId, required String title, String logline = '',
    String dialect = 'mandarin', FrameSize frame = FrameSize.vertical,
    String contentType = 'manju', int plannedEpisodes = 1,
    double totalBudgetYuan = 120, double i2vBudgetYuan = 20,
    int maxI2vSeconds = 0, List<DramaBeat> beatTemplate = const [],
    Map<String, DramaCastMember> cast = const {},
  });
  static DramaSeries fromJson(Map<String, Object?> json);
  Map<String, Object?> toJson();
  DramaSeries copyWith({
    String? title, String? logline, String? dialect, FrameSize? frame,
    String? contentType, int? plannedEpisodes, DramaDefaults? defaults,
    List<DramaBeat>? beatTemplate, Map<String, DramaCastMember>? cast,
  });
  Map<String, CastMember> storyboardCast();
}

class DramaDefaults {
  const DramaDefaults({
    this.totalBudgetYuan = 120, this.i2vBudgetYuan = 20,
    this.maxI2vSeconds = 0, this.castImageModel = 'wan2.7-image',
    this.frameImageModel = 'wan2.7-image',
    this.clipVideoModel = 'wan2.6-i2v-flash',
    this.t2vModel = 'wan3.0-video', this.resolution = '720P',
  });
  final double totalBudgetYuan, i2vBudgetYuan;
  final int maxI2vSeconds;
  final String castImageModel, frameImageModel, clipVideoModel, t2vModel, resolution;
  Map<String, Object?> toJson();
  static DramaDefaults fromJson(Map<String, Object?> json);
}

class DramaCastMember {
  const DramaCastMember({
    required this.castId, required this.name, this.description = '',
    this.voiceId, this.dialect, this.avatar,
  });
  final String castId, name, description;
  final String? voiceId, dialect;
  final DramaCastAvatar? avatar;
  Map<String, Object?> toJson();
  static DramaCastMember fromJson(String castId, Map<String, Object?> json);
  DramaCastMember copyWith({
    String? name, String? description, String? voiceId, String? dialect,
    DramaCastAvatar? avatar, bool clearAvatar = false,
  });
  CastMember toStoryboardCast();
}

class DramaCastAvatar {
  const DramaCastAvatar({
    required this.path, required this.sourceHash, required this.model,
    required this.costYuan, required this.approved,
  });
  final String path, sourceHash, model;
  final double costYuan;
  final bool approved;
  Map<String, Object?> toJson();
  static DramaCastAvatar fromJson(Map<String, Object?> json);
}

class DramaBeat {
  const DramaBeat({
    required this.id, required this.label, required this.summary,
    this.targetS, this.weight,
  });
  final String id, label, summary;
  final double? targetS;
  final int? weight;
  Map<String, Object?> toJson();
  static DramaBeat fromJson(Map<String, Object?> json);
}

// episode.dart
class DramaEpisode {
  const DramaEpisode({
    required this.seriesId, required this.episodeId, required this.number,
    required this.title, required this.source, required this.story,
    required this.settings,
  });
  final String seriesId, episodeId, title;
  final int number;
  final DramaSource source;
  final DramaStory story;
  final DramaSettings settings;
  factory DramaEpisode.create({
    required DramaSeries series, required String episodeId,
    required String title, int number = 1,
  });
  static DramaEpisode fromJson(Map<String, Object?> json);
  Map<String, Object?> toJson();
  DramaEpisode copyWith({
    String? title, int? number, DramaSource? source,
    DramaStory? story, DramaSettings? settings,
  });
}

class DramaSource {
  const DramaSource({required this.kind, required this.text});
  final String kind, text;
  Map<String, Object?> toJson();
}

class DramaStory {
  const DramaStory({
    this.logline = '', this.synopsis = '', this.beats = const [],
    this.sourceHash, this.promptVersion = 1, this.model,
  });
  final String logline, synopsis;
  final List<DramaBeat> beats;
  final String? sourceHash;
  final int promptVersion;
  final String? model;
  Map<String, Object?> toJson();
  static DramaStory fromJson(Map<String, Object?> json);
  DramaStory copyWith({
    String? logline, String? synopsis, List<DramaBeat>? beats,
    String? sourceHash, int? promptVersion, String? model,
    bool clearSourceHash = false, bool clearModel = false,
  });
}

class DramaSettings {
  const DramaSettings({
    required this.dialect, required this.frame,
    required this.totalBudgetYuan, required this.i2vBudgetYuan,
    this.maxI2vSeconds = 0, this.targetDurationS = 90,
  });
  final String dialect;
  final FrameSize frame;
  final double totalBudgetYuan, i2vBudgetYuan;
  final int maxI2vSeconds;
  final double targetDurationS;
  Map<String, Object?> toJson();
  static DramaSettings fromJson(Map<String, Object?> json, {
    required String fallbackDialect, required FrameSize fallbackFrame,
  });
  DramaSettings copyWith({
    String? dialect, FrameSize? frame, double? totalBudgetYuan,
    double? i2vBudgetYuan, int? maxI2vSeconds, double? targetDurationS,
  });
}
```

`DramaDefaults` 的模型默认值固定为 `wan2.7-image` / `wan2.7-image` / `wan2.6-i2v-flash` / `wan3.0-video` / `720P`；这些只是默认选择，实际调用仍走目录校验。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/drama`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/ids.dart lib/pipeline/drama/json.dart \
  lib/pipeline/drama/series.dart lib/pipeline/drama/episode.dart \
  test/pipeline/drama/ids_test.dart test/pipeline/drama/series_test.dart \
  test/pipeline/drama/episode_test.dart
git commit -m "feat(short-drama): 剧集领域模型与 JSON 校验"
```

---

### Task 3: 状态、hash 与工序推导

**Files:**
- Create: `lib/pipeline/drama/hash.dart`
- Create: `lib/pipeline/drama/state.dart`
- Create: `lib/pipeline/drama/steps.dart`
- Test: `test/pipeline/drama/hash_test.dart`
- Test: `test/pipeline/drama/steps_test.dart`

**Interfaces:**
- Produces:
  - `String canonicalJson(Object? value)`、`String dramaHash(Object? value)`
  - `enum DramaStatus { pending, running, succeeded, failed, stale, skipped, interrupted }`
  - `class DramaArtifact`、`DramaShotState`、`DramaStepRun`、`DramaEpisodeState`
  - `enum DramaStep { split, story, cast, board, frame, voice, edit, pack }`
  - `const List<DramaStep> kDramaStepOrder`
  - `const Set<DramaStep> kP1WiredSteps = {DramaStep.split, DramaStep.story, DramaStep.board}`
  - `String dramaStepKey(DramaStep step)`
  - `class DramaStepView { key, status, costYuan, summary, detail, wired; toJson() }`
  - `String dramaPlanHash({required Storyboard storyboard, required DramaEpisode episode})`
  - `List<DramaStepView> deriveDramaSteps({required DramaSeries series, required DramaEpisode episode, required Storyboard? storyboard, required Map<String, Object?>? planJson, required DramaEpisodeState state, required Set<DramaStep> wired})`

- [ ] **Step 1: 写失败测试**

`hash_test.dart`：

```dart
test('canonical json sorts keys recursively', () {
  expect(canonicalJson({'b': 1, 'a': {'d': 2, 'c': 3}}),
      '{"a":{"c":3,"d":2},"b":1}');
  expect(dramaHash({'a': 1, 'b': 2}), dramaHash({'b': 2, 'a': 1}));
  expect(dramaHash({'a': 1}), hasLength(64));
});
```

`steps_test.dart`：

```dart
test('empty episode: all steps pending, unwired show wired=false', () {
  final series = DramaSeries.create(seriesId: 'jietiao', title: '借条');
  final episode = DramaEpisode.create(
    series: series, episodeId: 'ep07', title: '堂屋对峙', number: 7,
  );
  final state = DramaEpisodeState.empty('jietiao', 'ep07');
  final steps = deriveDramaSteps(
    series: series, episode: episode, storyboard: null, planJson: null,
    state: state, wired: kP1WiredSteps,
  );
  expect(steps.map((s) => s.key), ['split', 'story', 'cast', 'board', 'frame', 'voice', 'edit', 'pack']);
  expect(steps.every((s) => s.status == DramaStatus.pending), isTrue);
  expect(steps.firstWhere((s) => s.key == 'cast').wired, isFalse);
});

test('split/story/board complete from source, story and plan hash', () {
  final series = DramaSeries.create(seriesId: 'jietiao', title: '借条');
  var episode = DramaEpisode.create(
    series: series, episodeId: 'ep07', title: '堂屋对峙', number: 7,
  ).copyWith(
    source: const DramaSource(kind: 'story', text: '二舅闯进堂屋'),
    story: DramaStory(
      logline: '二舅逼债',
      synopsis: '小满翻出第二张借条',
      beats: const [DramaBeat(id: 'hook', label: '钩子', summary: '拍桌')],
      sourceHash: dramaHash({'text': '二舅闯进堂屋'}),
    ),
  );
  final board = Storyboard.fromJson(<String, Object?>{
    'content_id': 'ep07',
    'shots': <Object?>[
      <String, Object?>{'id': 's01', 'kind': 'speak_off', 'line': '还钱。'},
    ],
  });
  var state = DramaEpisodeState.empty('jietiao', 'ep07');
  state = state.withPlanHash(dramaPlanHash(storyboard: board, episode: episode));
  final steps = deriveDramaSteps(
    series: series, episode: episode, storyboard: board,
    planJson: <String, Object?>{'shots': <Object?>[]},
    state: state, wired: kP1WiredSteps,
  );
  expect(steps.firstWhere((s) => s.key == 'split').status, DramaStatus.succeeded);
  expect(steps.firstWhere((s) => s.key == 'story').status, DramaStatus.succeeded);
  expect(steps.firstWhere((s) => s.key == 'board').status, DramaStatus.succeeded);
  expect(steps.firstWhere((s) => s.key == 'frame').status, DramaStatus.pending);
  expect(steps.firstWhere((s) => s.key == 'voice').status, DramaStatus.pending);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/drama/hash_test.dart test/pipeline/drama/steps_test.dart`
Expected: FAIL，类和函数不存在。

- [ ] **Step 3: 实现状态与推导**

`DramaEpisodeState` 至少包含：

```dart
enum DramaStatus { pending, running, succeeded, failed, stale, skipped, interrupted }

class DramaArtifact {
  const DramaArtifact({
    this.status = DramaStatus.pending, this.path, this.sourceHash,
    this.model, this.costYuan, this.durationS, this.error,
  });
  final DramaStatus status;
  final String? path, sourceHash, model, error;
  final double? costYuan, durationS;
  Map<String, Object?> toJson();
  static DramaArtifact fromJson(Map<String, Object?> json);
}

class DramaReview {
  const DramaReview({this.status = 'pending', this.note});
  final String status; // pending | approved | rejected
  final String? note;
  Map<String, Object?> toJson();
  static DramaReview fromJson(Map<String, Object?> json);
}

class DramaShotState {
  const DramaShotState({
    this.frame = const DramaArtifact(), this.clip = const DramaArtifact(),
    this.audio = const DramaArtifact(), this.review = const DramaReview(),
  });
  final DramaArtifact frame, clip, audio;
  final DramaReview review;
  Map<String, Object?> toJson();
  static DramaShotState fromJson(Map<String, Object?> json);
}

class DramaStepRun {
  const DramaStepRun({
    this.status = DramaStatus.pending, this.attempts = 0,
    this.error, this.logs = const [],
  });
  final DramaStatus status;
  final int attempts;
  final String? error;
  final List<String> logs; // 最多 200 行
  Map<String, Object?> toJson();
  static DramaStepRun fromJson(Map<String, Object?> json);
}

class DramaEpisodeState {
  const DramaEpisodeState({
    required this.seriesId, required this.episodeId,
    required this.storyboardHash, required this.planHash,
    required this.steps, required this.shots,
    required this.activeRunId, required this.actualYuan,
    required this.estimatedRemainingYuan, required this.warnings,
  });
  factory DramaEpisodeState.empty(String seriesId, String episodeId);
  final String seriesId, episodeId;
  final String? storyboardHash, planHash, activeRunId;
  final Map<String, DramaStepRun> steps; // key = “split”…”pack”
  final Map<String, DramaShotState> shots; // key = shot_id
  final double actualYuan, estimatedRemainingYuan;
  final List<String> warnings;
  static DramaEpisodeState fromJson(Map<String, Object?> json);
  Map<String, Object?> toJson();
  DramaEpisodeState withPlanHash(String? hash);
  DramaEpisodeState withStoryboardHash(String? hash);
}

class DramaStepView {
  const DramaStepView({
    required this.key, required this.status, required this.costYuan,
    required this.summary, required this.detail, required this.wired,
  });
  final DramaStep key;
  final DramaStatus status;
  final double costYuan;
  final String summary, detail;
  final bool wired;
  Map<String, Object?> toJson();
}
```

- `DramaEpisodeState.empty` 的 8 个工序默认 `pending`，`shots` 为空，`actualYuan = 0`。
- `DramaStepRun.logs` 上限 200。
- `canonicalJson` 递归排序 map key；list 保持顺序。
- `deriveDramaSteps` 按 spec §4.7 规则；`state.steps[key].status` 为 `running/failed/interrupted` 时覆盖。
- `dramaPlanHash` = `dramaHash({'storyboard': storyboard.toJson(), 'settings': episode.settings.toJson()})`。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/drama`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/hash.dart lib/pipeline/drama/state.dart \
  lib/pipeline/drama/steps.dart test/pipeline/drama/hash_test.dart \
  test/pipeline/drama/steps_test.dart
git commit -m "feat(short-drama): 剧集状态与工序推导"
```

---

### Task 4: 剧集文件存储

**Files:**
- Create: `lib/pipeline/drama/store.dart`
- Test: `test/pipeline/drama/store_test.dart`

**Interfaces:**
- Produces:

```dart
class DramaStore {
  DramaStore({required this.rootDir});
  final String rootDir; // 例如 .../pipeline_out/drama
  String seriesDir(String seriesId);
  String episodeDir(String seriesId, String episodeId);
  List<DramaSeries> listSeries();
  DramaSeries createSeries(DramaSeries series);
  DramaSeries readSeries(String seriesId);
  void writeSeries(DramaSeries series);
  void deleteSeries(String seriesId);
  List<DramaEpisode> listEpisodes(String seriesId);
  DramaEpisode createEpisode(DramaEpisode episode);
  DramaEpisode readEpisode(String seriesId, String episodeId);
  void writeEpisode(DramaEpisode episode);
  void deleteEpisode(String seriesId, String episodeId);
  Storyboard? readStoryboard(String seriesId, String episodeId);
  void writeStoryboard(String seriesId, String episodeId, Storyboard storyboard);
  Map<String, Object?>? readPlanJson(String seriesId, String episodeId);
  void writePlanJson(String seriesId, String episodeId, Map<String, Object?> plan);
  DramaEpisodeState readState(String seriesId, String episodeId);
  void writeState(String seriesId, String episodeId, DramaEpisodeState state);
  File assetFile(String seriesId, String episodeId, String relativePath);
}
```

- 重复创建抛 `StateError('series_exists')` / `StateError('episode_exists')`。
- 缺失文件抛 `FileSystemException`；`readState` 缺失返回 `empty`。
- 所有写入 tmp + rename，使用 2 空格 pretty JSON + `\n`。
- `assetFile` 拒绝空路径、`..`、绝对路径、解析后不在集目录内的路径（抛 `ArgumentError`）。

- [ ] **Step 1: 写失败测试**

```dart
late Directory tmp;
late DramaStore store;
setUp(() {
  tmp = Directory.systemTemp.createTempSync('drama_store');
  store = DramaStore(rootDir: '${tmp.path}/drama');
});
tearDown(() => tmp.deleteSync(recursive: true));

test('create/list/read/delete series and episodes', () {
  final series = DramaSeries.create(seriesId: 'jietiao', title: '借条');
  store.createSeries(series);
  expect(store.listSeries().single.title, '借条');
  final episode = DramaEpisode.create(series: series, episodeId: 'ep07', title: '堂屋对峙', number: 7);
  store.createEpisode(episode);
  expect(store.listEpisodes('jietiao').single.title, '堂屋对峙');
  store.deleteSeries('jietiao');
  expect(store.listSeries(), isEmpty);
});

test('duplicate create is a conflict, writes are atomic', () {
  final series = DramaSeries.create(seriesId: 'jietiao', title: '借条');
  store.createSeries(series);
  expect(() => store.createSeries(series), throwsStateError);
  expect(File('${store.seriesDir('jietiao')}/series.json.tmp').existsSync(), isFalse);
});

test('chinese text roundtrips and missing state is empty', () {
  final series = DramaSeries.create(seriesId: 'jietiao', title: '借条');
  store.createSeries(series);
  final episode = DramaEpisode.create(series: series, episodeId: 'ep07', title: '堂屋对峙')
      .copyWith(source: const DramaSource(kind: 'story', text: '二舅说：「还钱。」'));
  store.createEpisode(episode);
  expect(store.readEpisode('jietiao', 'ep07').source.text, '二舅说：「还钱。」');
  expect(store.readState('jietiao', 'ep07').episodeId, 'ep07');
});

test('asset path cannot escape the episode dir', () {
  expect(() => store.assetFile('jietiao', 'ep07', '../secret.png'), throwsArgumentError);
  expect(() => store.assetFile('jietiao', 'ep07', '/etc/passwd'), throwsArgumentError);
});

test('corrupt series is skipped by listSeries', () {
  Directory('${store.rootDir}/series/bad').createSync(recursive: true);
  File('${store.rootDir}/series/bad/series.json').writeAsStringSync('{');
  expect(store.listSeries(), isEmpty);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/drama/store_test.dart`
Expected: FAIL，`DramaStore` 不存在。

- [ ] **Step 3: 实现存储**

- `_writeJson(path, map)`：创建父目录、写 `path.tmp`、rename。
- `_readJson(path)`：缺失抛 `FileSystemException`；非法 JSON 抛 `PipelineError.fatal`。
- `listSeries` 排序 `seriesId`，单个坏文件跳过；`listEpisodes` 排序 `number` 再 `episodeId`。
- 删除只接受已校验 ID（`requireDramaId`）。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/drama`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/store.dart test/pipeline/drama/store_test.dart
git commit -m "feat(short-drama): 剧集文件存储"
```

---

### Task 5: 费用估算与计划单构建

**Files:**
- Create: `lib/pipeline/drama/cost.dart`
- Test: `test/pipeline/drama/cost_test.dart`

**Interfaces:**
- Produces:

```dart
double defaultDramaI2vPriceYuanPerSecond();
RenderPlan buildDramaPlan({
  required Storyboard storyboard,
  required DramaEpisode episode,
});

class DramaEstimateItem {
  const DramaEstimateItem({
    required this.kind, required this.id, required this.model,
    required this.quantity, required this.unit, required this.priceYuan,
    required this.subtotalYuan, required this.estimated,
  });
  final String kind, id, model, unit;
  final double quantity, priceYuan, subtotalYuan;
  final bool estimated;
  Map<String, Object?> toJson();
}

class DramaUnpricedItem {
  const DramaUnpricedItem({required this.kind, required this.id, required this.reason});
  final String kind, id, reason;
  Map<String, Object?> toJson();
}

class DramaBudgetSnapshot {
  const DramaBudgetSnapshot({
    required this.totalYuan, required this.actualYuan, required this.remainingYuan,
  });
  final double totalYuan, actualYuan, remainingYuan;
  Map<String, Object?> toJson();
}

class DramaEstimate {
  const DramaEstimate({
    required this.items, required this.totalEstimatedYuan,
    required this.unpriced, required this.budget,
  });
  final List<DramaEstimateItem> items;
  final double totalEstimatedYuan;
  final List<DramaUnpricedItem> unpriced;
  final DramaBudgetSnapshot budget;
  Map<String, Object?> toJson();
}

DramaEstimate estimateDrama({
  required DramaSeries series,
  required DramaEpisode episode,
  required DramaEpisodeState state,
  Storyboard? storyboard,
  Map<String, Object?>? planJson,
  required Set<String> targets, // P1: {'story'} / {'storyboard'}
  bool force = false,
});
```

- `defaultDramaI2vPriceYuanPerSecond()` 从 `findVideoModel(kPlanI2vModel)` 读 `defaultPrices[kPlanI2vResolution]`，缺失抛 `StateError`。
- `buildDramaPlan` 使用 `episode.settings.i2vBudgetYuan` 和 `maxI2vSeconds`。
- P1 的 `estimateDrama` 对每个 target 产出一个 `kind: 'llm'` 的 `unpriced` 项，`reason: 'llm_pricing_unavailable'`；`totalEstimatedYuan == 0`。
- `budget`：`total = episode.settings.totalBudgetYuan`、`actual = state.actualYuan`、`remaining = max(0, total - actual)`。

- [ ] **Step 1: 写失败测试**

```dart
test('i2v price comes from the catalog', () {
  expect(defaultDramaI2vPriceYuanPerSecond(), 0.15);
});

test('P1 estimate marks LLM unpriced and keeps budget snapshot', () {
  final series = DramaSeries.create(seriesId: 'jietiao', title: '借条');
  final episode = DramaEpisode.create(series: series, episodeId: 'ep07', title: 'x');
  final state = DramaEpisodeState.empty('jietiao', 'ep07');
  final estimate = estimateDrama(
    series: series, episode: episode, state: state, targets: {'story'},
  );
  expect(estimate.totalEstimatedYuan, 0);
  expect(estimate.unpriced.single.kind, 'llm');
  expect(estimate.budget.totalYuan, 120);
});

test('buildDramaPlan uses episode i2v budget', () {
  final series = DramaSeries.create(seriesId: 'jietiao', title: '借条');
  final episode = DramaEpisode.create(series: series, episodeId: 'ep07', title: 'x');
  final board = Storyboard.fromJson(<String, Object?>{
    'content_id': 'ep07',
    'budget_yuan': 20,
    'shots': <Object?>[
      <String, Object?>{'id': 's01', 'kind': 'action', 'duration_s': 3},
    ],
  });
  final plan = buildDramaPlan(storyboard: board, episode: episode);
  expect(plan.priceYuanPerSecond, 0.15);
  expect(plan.budgetYuan, 20);
  expect(plan.shots.single.route, ShotRoute.i2v);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/drama/cost_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现**

复用 `buildRenderPlan`；不新增价格常量。`estimateDrama` 只规划，不读网络。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/drama`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/cost.dart test/pipeline/drama/cost_test.dart
git commit -m "feat(short-drama): 费用估算与计划单构建"
```

---

### Task 6: 故事与分镜 LLM 草稿

**Files:**
- Create: `lib/pipeline/drama/llm.dart`
- Test: `test/pipeline/drama/llm_test.dart`

**Interfaces:**
- Produces:

```dart
abstract interface class DramaLlm {
  Future<Map<String, dynamic>> chatJson({
    required String system,
    required String user,
  });
}

class QwenDramaLlm implements DramaLlm {
  QwenDramaLlm({required PipelineConfig cfg});
}

class DramaExtractResult {
  final String logline, synopsis, sourceHash;
  final List<DramaBeat> beats;
  final Map<String, DramaCastMember> castNew;
  final Map<String, DramaCastMember> castUpdates;
  final List<String> warnings;
  Map<String, Object?> toJson();
}

class DramaStoryboardDraft {
  final Storyboard storyboard;
  final List<String> warnings;
  Map<String, Object?> toJson();
}

class DramaDraftService {
  DramaDraftService({required DramaLlm llm, int maxAttempts = 2});
  Future<DramaExtractResult> extract({
    required DramaSeries series,
    required DramaEpisode episode,
  });
  Future<DramaStoryboardDraft> draftStoryboard({
    required DramaSeries series,
    required DramaEpisode episode,
  });
}
```

- `sourceHash = dramaHash({'text': episode.source.text})`。
- 拆片 prompt 要求只输出：`{"logline":"","synopsis":"","beats":[{"id":"hook","label":"","summary":""}],"cast_new":{},"cast_updates":{}}`。
- 分镜 prompt 要求只输出：`{"title":"","shots":[{"id":"s01","kind":"speak_off","framing":"","speaker":"","line":"","duration_s":3.0,"priority":"hook","prop":null,"motion":null,"visual":""}]}`。
- `draftStoryboard` 由服务端注入 `content_id=episode.episodeId`、`dialect`、`frame`、`budget_yuan`、`cast`（来自 `series.storyboardCast()`），只吃 LLM 的 `title` 与 `shots`。
- 校验失败重试一次；第二次仍失败抛 `PipelineError(ErrorClass.fatal, 'draft_schema: <原因>')`，供 controller 映射 422。拆片与分镜都使用这个前缀。
- 缺 `id` 的镜头按顺序补 `s01...` 并写 warning。
- 拆片结果不自动覆盖已有 cast。

- [ ] **Step 1: 写失败测试**

```dart
class _FakeLlm implements DramaLlm {
  _FakeLlm(this.responses);
  final List<Map<String, dynamic> Function()> responses;
  int calls = 0;
  @override
  Future<Map<String, dynamic>> chatJson({required String system, required String user}) async {
    return responses[calls++]();
  }
}

test('extract parses beats, cast and source hash without writing', () async {
  final fake = _FakeLlm([
    () => {
      'logline': '二舅逼债',
      'synopsis': '小满翻出第二张借条',
      'beats': [{'id': 'hook', 'label': '钩子', 'summary': '借条拍桌'}],
      'cast_new': {'xiaoman': {'name': '小满'}},
      'cast_updates': {},
    },
  ]);
  final series = DramaSeries.create(seriesId: 'jietiao', title: '借条');
  var episode = DramaEpisode.create(series: series, episodeId: 'ep07', title: 'x');
  episode = episode.copyWith(source: const DramaSource(kind: 'story', text: '二舅闯进堂屋'));
  final result = await DramaDraftService(llm: fake).extract(series: series, episode: episode);
  expect(result.logline, '二舅逼债');
  expect(result.beats.single.label, '钩子');
  expect(result.castNew['xiaoman']!.name, '小满');
  expect(result.sourceHash, dramaHash({'text': '二舅闯进堂屋'}));
  expect(fake.calls, 1);
});

test('draft retries once and injects content_id/cast', () async {
  final fake = _FakeLlm([
    () => {'shots': 'not-a-list'},
    () => {
      'title': '堂屋对峙',
      'shots': [
        {'kind': 'action', 'visual': '借条特写', 'duration_s': 3.0},
      ],
    },
  ]);
  final series = DramaSeries.fromJson({
    'series_id': 'jietiao', 'title': '借条',
    'cast': {'erniu': {'name': '二舅'}},
  });
  final episode = DramaEpisode.create(series: series, episodeId: 'ep07', title: 'x');
  final draft = await DramaDraftService(llm: fake).draftStoryboard(series: series, episode: episode);
  expect(fake.calls, 2);
  expect(draft.storyboard.contentId, 'ep07');
  expect(draft.storyboard.cast['erniu']!.name, '二舅');
  expect(draft.storyboard.shots.single.id, 's01');
  expect(draft.storyboard.shots.single.visual, '借条特写');
});

test('unfixable draft is a fatal draft_schema error', () async {
  final fake = _FakeLlm([
    () => {'shots': 'bad'},
    () => {'shots': 'still-bad'},
  ]);
  final series = DramaSeries.create(seriesId: 'jietiao', title: '借条');
  final episode = DramaEpisode.create(series: series, episodeId: 'ep07', title: 'x');
  await expectLater(
    DramaDraftService(llm: fake).draftStoryboard(series: series, episode: episode),
    throwsA(isA<PipelineError>()
        .having((e) => e.cls, 'cls', ErrorClass.fatal)
        .having((e) => e.message, 'message', startsWith('draft_schema:'))),
  );
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/drama/llm_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现**

- `QwenDramaLlm` 每次调用构造 `QwenClient(apiKey: cfg.requireApiKey(), baseUrl: cfg.baseUrl, model: cfg.llmModel)`，调 `chatJson`。
- `DramaDraftService` 不写文件；只返回结果。
- prompt 里明确「不要 Markdown、只输出 JSON」；JSON schema 写在 system prompt。
- 解析 cast 用 `DramaCastMember.fromJson`，缺 `name` 抛错触发重试。
- `draftStoryboard` 捕获 `PipelineError` / `ArgumentError` / `TypeError`，重试时把错误文本拼进 user prompt。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/drama`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/llm.dart test/pipeline/drama/llm_test.dart
git commit -m "feat(short-drama): 故事与分镜 LLM 草稿"
```

---

### Task 7: 短剧工作台 API

**Files:**
- Create: `lib/pipeline/drama/controller.dart`
- Modify: `lib/server/api_router.dart`
- Modify: `lib/server/pipeline_server.dart`
- Modify: `test/server/api_router_test.dart`
- Modify: `Makefile`
- Test: `test/server/drama_api_test.dart`

**Interfaces:**
- Produces:
  - `enum ApiRoute ... drama`
  - `DramaRoute? parseDramaRoute(String method, List<String> segments)`
  - `enum DramaRoute { listSeries, createSeries, getSeries, updateSeries, deleteSeries, createEpisode, getEpisode, updateEpisode, deleteEpisode, saveStoryboard, replan, estimate, extractStory, draftStoryboard, runStep, runShot }`
  - `class DramaController { DramaController({required DramaStore store, required DramaDraftService drafts, required double priceYuanPerSecond, int maxBodyBytes = 2 * 1024 * 1024}); Future<void> handle(HttpRequest req); }`
  - `PipelineServer` 增加：`DramaController? dramaController`、`String? dramaRoot`、`DramaLlm? dramaLlm`。

- [ ] **Step 1: 写失败测试**

`api_router_test.dart` 加：

```dart
test('drama routes all methods go to the drama controller', () {
  expect(apiRouteFor('GET', '/api/drama/series'), ApiRoute.drama);
  expect(apiRouteFor('POST', '/api/drama/series'), ApiRoute.drama);
  expect(apiRouteFor('PUT', '/api/drama/series/jietiao'), ApiRoute.drama);
  expect(apiRouteFor('GET', '/api/drama'), ApiRoute.unknown);
  expect(apiRouteFor('GET', '/api/dramaX/series'), ApiRoute.unknown);
});
```

`test/server/drama_api_test.dart`（复制现有 `short_drama_api_test.dart` 的 `_get`，再补 `_post` / `_put`；用 temp store + fake LLM + `PipelineServer(dramaController: ...)`）。测试里定义一个 `_seed()` helper 建好 `jietiao` 与 `ep07`；除 create 测试外，其余测试在开头调用 `_seed()`）：

```dart
test('create series -> create episode -> bundle has 8 steps', () async {
  final created = await _post(port, '/api/drama/series', {
    'series_id': 'jietiao', 'title': '借条', 'dialect': 'henan',
    'planned_episodes': 80, 'total_budget_yuan': 120, 'i2v_budget_yuan': 20,
  });
  expect(created.status, 201);
  final episode = await _post(port, '/api/drama/series/jietiao/episodes', {
    'episode_id': 'ep07', 'title': '堂屋对峙', 'number': 7,
  });
  expect(episode.status, 201);
  final bundle = await _get(port, '/api/drama/series/jietiao/episodes/ep07');
  expect(bundle.status, 200);
  final decoded = jsonDecode(bundle.body) as Map<String, dynamic>;
  expect((decoded['steps'] as List), hasLength(8));
  expect((decoded['steps'] as List).first['key'], 'split');
  expect(decoded['plan'], isNull);
});

test('save storyboard returns a deterministic plan', () async {
  final res = await _put(port, '/api/drama/series/jietiao/episodes/ep07/storyboard', {
    'storyboard': {
      'content_id': 'ep07',
      'budget_yuan': 20,
      'shots': [
        {'id': 's01', 'kind': 'action', 'duration_s': 3},
        {'id': 's02', 'kind': 'speak_off', 'line': '还钱。', 'duration_s': 2},
      ],
    },
  });
  expect(res.status, 200);
  final decoded = jsonDecode(res.body) as Map<String, dynamic>;
  final plan = decoded['plan'] as Map<String, dynamic>;
  expect((plan['shots'] as List).first['route'], 'i2v');
  expect((plan['totals'] as Map)['i2v_seconds'], 3);
  expect(decoded['state']['plan_hash'], isNotNull);
});

test('invalid id/path is 400 and missing series is 404', () async {
  expect((await _get(port, '/api/drama/series/bad.id')).status, 400);
  expect((await _get(port, '/api/drama/series/nope')).status, 404);
});

test('duplicate create is 409', () async {
  final body = {
    'series_id': 'dup', 'title': '重复', 'dialect': 'henan',
    'planned_episodes': 1, 'total_budget_yuan': 10, 'i2v_budget_yuan': 5,
  };
  expect((await _post(port, '/api/drama/series', body)).status, 201);
  expect((await _post(port, '/api/drama/series', body)).status, 409);
});

test('extract returns a draft and estimate is unpriced', () async {
  final estimate = await _post(port, '/api/drama/series/jietiao/episodes/ep07/estimate', {
    'targets': ['story'],
  });
  expect(estimate.status, 200);
  expect(jsonDecode(estimate.body)['unpriced'], hasLength(1));

  final extract = await _post(port, '/api/drama/series/jietiao/episodes/ep07/story:extract', {});
  expect(extract.status, 200);
  expect(jsonDecode(extract.body)['logline'], '二舅逼债');
});

test('unwired step run is 501', () async {
  final res = await _post(port, '/api/drama/series/jietiao/episodes/ep07/steps/frame:run', {});
  expect(res.status, 501);
});

test('invalid storyboard duration is 400 and does not write a plan', () async {
  final res = await _put(port, '/api/drama/series/jietiao/episodes/ep07/storyboard', {
    'storyboard': {
      'content_id': 'ep07',
      'shots': [
        {'id': 's01', 'kind': 'action', 'duration_s': 0},
      ],
    },
  });
  expect(res.status, 400);
  final bundle = jsonDecode((await _get(port, '/api/drama/series/jietiao/episodes/ep07')).body);
  expect(bundle['plan'], isNull);
});

test('unfixable LLM draft is 422 and does not write', () async {
  // 让 fake LLM 连续两次返回 {'shots': 'bad'}
  final res = await _post(port, '/api/drama/series/jietiao/episodes/ep07/storyboard:draft', {});
  expect(res.status, 422);
  final bundle = jsonDecode((await _get(port, '/api/drama/series/jietiao/episodes/ep07')).body);
  expect(bundle['storyboard'], isNull);
});

test('chinese line survives save and read', () async {
  final res = await _put(port, '/api/drama/series/jietiao/episodes/ep07/storyboard', {
    'storyboard': {
      'content_id': 'ep07',
      'shots': [
        {'id': 's01', 'kind': 'speak_off', 'line': '你欠我的，今天该还了。', 'duration_s': 3},
      ],
    },
  });
  expect(res.status, 200);
  final bundle = jsonDecode(res.body) as Map<String, dynamic>;
  expect(bundle['storyboard']['shots'][0]['line'], '你欠我的，今天该还了。');
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/server/api_router_test.dart test/server/drama_api_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现 controller 与接线**

路由解析（`req.uri.pathSegments`，不含前导斜杠）：

```
['api','drama','series']                                  GET list / POST create
['api','drama','series',sid]                              GET / PUT / DELETE
['api','drama','series',sid,'episodes']                   POST
['api','drama','series',sid,'episodes',eid]               GET / PUT / DELETE
['api','drama','series',sid,'episodes',eid,'storyboard']  PUT
['api','drama','series',sid,'episodes',eid,'plan']        POST
['api','drama','series',sid,'episodes',eid,'estimate']    POST
['api','drama','series',sid,'episodes',eid,'story:extract'] POST
['api','drama','series',sid,'episodes',eid,'storyboard:draft'] POST
['api','drama','series',sid,'episodes',eid,'steps',<key>:run] POST → 501
['api','drama','series',sid,'episodes',eid,'shots',<shot>:run] POST → 501
```

请求/响应：

- `POST /series` body：`{series_id,title,dialect,planned_episodes,total_budget_yuan,i2v_budget_yuan}` → 201 `{series}`。
- `PUT /series/<sid>` body `{series: <Series JSON>}`；`series.series_id` 必须等于路径。
- `POST /series/<sid>/episodes` body `{episode_id?,title,number?}`；缺 id 时用 `ep{n}` 生成唯一 id。
- `PUT /series/<sid>/episodes/<eid>` body `{episode: <Episode JSON>}`；若已有 storyboard，则重算 plan 并写回。
- `PUT .../storyboard` body `{storyboard: <Storyboard JSON>}`；`content_id` 必须等于 `eid`。
- `POST .../plan` 免费重算。
- `POST .../estimate` body `{targets:[...],force?}`。
- `GET` 整包响应：`{series,episode,storyboard,plan,state,steps,capabilities}`；`plan` 缺失为 `null`；`state` 缺失用 `empty`。
- 错误：`ArgumentError`/模型解析 → 400 `invalid_body`；ID 非法 → 400 `invalid_id`；缺失 → 404；重复 → 409；LLM `draft_schema:` → 422；未接入 run → 501；请求体超限 → 413。
- 成功写 plan 后同步 `state.planHash = dramaPlanHash(storyboard: board, episode: episode)` 并写回 state；保存分镜时同时写 `state.storyboardHash = dramaHash(board.toJson())`。
- `_bundle` 中 `capabilities` = `{cast:false,frame:false,voice:false,edit:false,pack:false}`，`steps` 用 `kP1WiredSteps`。

`PipelineServer`：

- 增加构造参数 `this.dramaController, this.dramaRoot, this.dramaLlm`。
- 惰性 getter：`dramaController ?? DramaController(store: DramaStore(rootDir: dramaRoot ?? 'pipeline_out/drama'), drafts: DramaDraftService(llm: dramaLlm ?? QwenDramaLlm(cfg: cfg)), priceYuanPerSecond: defaultDramaI2vPriceYuanPerSecond())`。
- `_handleApi` 增加 `case ApiRoute.drama: await _drama.handle(req);`。
- `Makefile` 的 `DART_TEST_CMD` 加 `test/server/drama_api_test.dart`。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/server/drama_api_test.dart test/server/api_router_test.dart && make analyze`
Expected: PASS，analyze 零告警。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/controller.dart lib/server/api_router.dart \
  lib/server/pipeline_server.dart test/server/api_router_test.dart \
  test/server/drama_api_test.dart Makefile
git commit -m "feat(server): 短剧工作台 API"
```

---

### Task 8: 前端类型、API 与分镜校验

**Files:**
- Create: `frontend/src/shortDrama/types.ts`
- Create: `frontend/src/shortDrama/api.ts`
- Create: `frontend/src/shortDrama/storyboard.ts`
- Create: `frontend/src/shortDrama/view.ts`
- Test: `frontend/src/shortDrama/storyboard.test.ts`
- Test: `frontend/src/shortDrama/view.test.ts`
- Modify: `frontend/src/shortDrama/model.ts`
- Test: `frontend/src/shortDrama/model.test.ts`

**Interfaces:**
- `types.ts`：`StepKey`、`StepStatus`、`StepView`、`DramaSeries`、`DramaSeriesSummary`、`DramaEpisode`、`EpisodeSummary`、`Storyboard`、`StoryboardShot`、`EpisodeState`、`EpisodeBundle`、`DramaEstimate`、`StoryExtractResult`、`StoryboardDraftResult`。`Plan` 从 `./model` 导入复用。

```ts
export type StepKey = "split" | "story" | "cast" | "board" | "frame" | "voice" | "edit" | "pack";
export type StepStatus = "pending" | "running" | "succeeded" | "failed" | "stale" | "skipped" | "interrupted";
export interface StoryboardShot {
  id: string; kind: ShotKind; framing: string; speaker: string | null;
  line: string; duration_s: number | null; priority: ShotPriority;
  prop: string | null; motion: string | null; visual: string | null;
}
export interface Storyboard {
  content_id: string; title: string; dialect: string | null; frame: string;
  budget_yuan: number;
  cast: Record<string, { name: string; voice_id?: string | null; dialect?: string | null }>;
  shots: StoryboardShot[];
}
export interface StepView {
  key: StepKey; status: StepStatus; cost_yuan: number;
  summary: string; detail: string; wired: boolean;
}
export interface EpisodeBundle {
  series: DramaSeries; episode: DramaEpisode;
  storyboard: Storyboard | null; plan: Plan | null;
  state: EpisodeState; steps: StepView[];
  capabilities: Record<string, boolean>;
}

export interface DramaSeries {
  series_id: string; title: string; logline: string; dialect: string;
  frame: string; content_type: string; planned_episodes: number;
  defaults: {
    total_budget_yuan: number; i2v_budget_yuan: number; max_i2v_seconds: number;
    cast_image_model: string; frame_image_model: string;
    clip_video_model: string; t2v_model: string; resolution: string;
  };
  beat_template: DramaBeat[];
  cast: Record<string, DramaCastMember>;
}
export interface DramaCastMember {
  name: string; description: string;
  voice_id: string | null; dialect: string | null;
  avatar: { path: string; source_hash: string; model: string; cost_yuan: number; approved: boolean } | null;
}
export interface DramaBeat { id: string; label: string; summary: string; target_s?: number | null; weight?: number | null }
export interface DramaEpisode {
  series_id: string; episode_id: string; number: number; title: string;
  source: { kind: string; text: string };
  story: {
    logline: string; synopsis: string; beats: DramaBeat[];
    source_hash: string | null; prompt_version: number; model: string | null;
  };
  settings: {
    dialect: string; frame: string; total_budget_yuan: number;
    i2v_budget_yuan: number; max_i2v_seconds: number; target_duration_s: number;
  };
}
export interface EpisodeState {
  series_id: string; episode_id: string;
  storyboard_hash: string | null; plan_hash: string | null;
  steps: Record<string, { status: StepStatus; attempts: number; error: string | null }>;
  shots: Record<string, unknown>;
  active_run: string | null;
  cost: { actual_yuan: number; estimated_remaining_yuan: number };
  warnings: string[];
}
export interface DramaSeriesSummary extends DramaSeries { episode_count: number }
export interface EpisodeSummary { episode_id: string; number: number; title: string }
export interface DramaEstimate {
  items: Array<{
    kind: string; id: string; model: string; quantity: number;
    unit: string; price_yuan: number; subtotal_yuan: number; estimated: boolean;
  }>;
  total_estimated_yuan: number;
  unpriced: Array<{ kind: string; id: string; reason: string }>;
  budget: { total_yuan: number; actual_yuan: number; remaining_yuan: number };
}
export interface StoryExtractResult {
  logline: string; synopsis: string; source_hash: string;
  beats: DramaBeat[];
  cast_new: Record<string, DramaCastMember>;
  cast_updates: Record<string, DramaCastMember>;
  warnings: string[];
}
export interface StoryboardDraftResult { storyboard: Storyboard; warnings: string[] }
```
- `api.ts`：

```ts
export interface CreateSeriesInput {
  series_id: string; title: string; dialect: string;
  planned_episodes: number; total_budget_yuan: number; i2v_budget_yuan: number;
}
export interface CreateEpisodeInput { episode_id?: string; title: string; number?: number }

export class DramaApiError extends Error {
  readonly status: number
  readonly code?: string
  readonly details?: unknown
}

export const dramaApi: {
  listSeries(): Promise<{ series: DramaSeriesSummary[] }>
  createSeries(input: CreateSeriesInput): Promise<{ series: DramaSeries }>
  getSeries(id: string): Promise<{ series: DramaSeries; episodes: EpisodeSummary[] }>
  updateSeries(id: string, series: DramaSeries): Promise<{ series: DramaSeries; episodes: EpisodeSummary[] }>
  createEpisode(sid: string, input: CreateEpisodeInput): Promise<{ episode: DramaEpisode }>
  getEpisode(sid: string, eid: string): Promise<EpisodeBundle>
  updateEpisode(sid: string, eid: string, episode: DramaEpisode): Promise<EpisodeBundle>
  saveStoryboard(sid: string, eid: string, storyboard: Storyboard): Promise<EpisodeBundle>
  replan(sid: string, eid: string): Promise<EpisodeBundle>
  estimate(sid: string, eid: string, targets: string[], force?: boolean): Promise<DramaEstimate>
  extractStory(sid: string, eid: string, text?: string): Promise<StoryExtractResult>
  draftStoryboard(sid: string, eid: string): Promise<StoryboardDraftResult>
}
```

- `storyboard.ts`：

```ts
export interface ShotDraft {
  id: string; kind: ShotKind; framing: string; speaker: string;
  line: string; duration: string; priority: ShotPriority;
  prop: string; motion: string; visual: string;
}
export interface StoryboardDraft {
  content_id: string; title: string; dialect: string; frame: string;
  budget_yuan: number; cast: Storyboard["cast"]; shots: ShotDraft[];
}
export function storyboardToDraft(board: Storyboard): StoryboardDraft;
export function draftToStoryboard(draft: StoryboardDraft): Storyboard;
export function validateStoryboardDraft(draft: StoryboardDraft): string[];
export function emptyShotDraft(index: number): ShotDraft;
export function addShot(draft: StoryboardDraft): StoryboardDraft;
export function removeShot(draft: StoryboardDraft, id: string): StoryboardDraft;
export function moveShot(draft: StoryboardDraft, id: string, delta: -1 | 1): StoryboardDraft;
```

- `view.ts`：

```ts
export const STEP_ORDER: StepKey[];
export const STEP_LABELS: Record<StepKey, string>;
export const STEP_TO_DAG: Record<StepKey, "rip" | "story" | "cast" | "board" | "frame" | "voice" | "edit" | "pack">;
export function budgetPercent(actual: number, total: number): number;
export function stepStatusLabel(step: StepView): string; // 未接入 / 待处理 / 运行中 / 完成 / 失败 / 已过期 / 已跳过 / 已中断
export function findStep(steps: StepView[], key: StepKey): StepView | undefined;
```

- `model.ts` 增加：

```ts
export function budgetPercent(actual: number, total: number): number;
```

- [ ] **Step 1: 写失败测试**

`storyboard.test.ts`（在文件顶部定义 `minimalBoard()`：`content_id:'ep07'`、一个 `speak_off` 镜头、空 cast）：

```ts
it('maps wire storyboard to editable draft and back', () => {
  const board: Storyboard = {
    content_id: 'ep07', title: '堂屋对峙', dialect: 'henan', frame: '1080x1920', budget_yuan: 20,
    cast: { erniu: { name: '二舅' } },
    shots: [{ id: 's01', kind: 'action', framing: '中景', speaker: 'erniu', line: '',
      duration_s: 3, priority: 'hook', prop: null, motion: null, visual: '借条特写' }],
  }
  const draft = storyboardToDraft(board)
  expect(draft.shots[0].duration).toBe('3.0')
  expect(draftToStoryboard(draft)).toEqual(board)
})

it('rejects empty/duplicate ids and bad durations', () => {
  const draft = storyboardToDraft(minimalBoard())
  draft.shots[0].id = ''
  expect(validateStoryboardDraft(draft)).toContain('镜号不能为空')
  draft.shots[0].id = 's01'
  draft.shots.push({ ...draft.shots[0] })
  expect(validateStoryboardDraft(draft)).toContain('镜号重复：s01')
  draft.shots[1].id = 's02'
  draft.shots[0].duration = '0'
  expect(validateStoryboardDraft(draft)).toContain('第 1 镜时长必须是有限正数')
})

it('adds/moves shots with unique ids', () => {
  const draft = addShot(storyboardToDraft(minimalBoard()))
  expect(draft.shots).toHaveLength(2)
  expect(new Set(draft.shots.map((s) => s.id)).size).toBe(2)
  expect(moveShot(draft, draft.shots[1].id, -1).shots[0].id).toBe(draft.shots[1].id)
})
```

`view.test.ts`（顶部定义 `step()` 返回一个 `wired: true, status: "pending"` 的 `StepView`）：

```ts
it('budget percent clamps and handles zero total', () => {
  expect(budgetPercent(50, 100)).toBe(50)
  expect(budgetPercent(150, 100)).toBe(100)
  expect(budgetPercent(1, 0)).toBe(0)
})
it('status label prioritizes unwired', () => {
  expect(stepStatusLabel({ ...step(), wired: false })).toBe('未接入')
  expect(stepStatusLabel({ ...step(), status: 'failed' })).toBe('失败')
})
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd frontend && npm test -- storyboard view`
Expected: FAIL。

- [ ] **Step 3: 实现**

- `api.ts` 用 `fetch`；非 2xx 解析 `{error,code,details}` 抛 `DramaApiError`；网络错误抛 `DramaApiError(0, 'network')`。
- `storyboardToDraft`：`duration_s == null ? '' : duration_s.toFixed(1)`；null 字符串字段转 `''`。
- `draftToStoryboard`：`duration.trim() === '' ? null : Number(duration)`；null 字符串转 `null`。
- 校验规则：至少 1 镜、id 非空唯一、duration 为空或有限正数、kind/priority 枚举合法。
- `budgetPercent` 在 `model.ts` 与 `view.ts` 二选一实现，另一个 re-export，避免两套算法；计划选择 `model.ts` 实现，`view.ts` re-export。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd frontend && npm test && npm run lint && npm run build`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add frontend/src/shortDrama/types.ts frontend/src/shortDrama/api.ts \
  frontend/src/shortDrama/storyboard.ts frontend/src/shortDrama/view.ts \
  frontend/src/shortDrama/storyboard.test.ts frontend/src/shortDrama/view.test.ts \
  frontend/src/shortDrama/model.ts frontend/src/shortDrama/model.test.ts
git commit -m "feat(web): 工作台前端类型与分镜校验"
```

---

### Task 9: 工作台骨架与入口

**Files:**
- Modify: `frontend/src/ShortDrama.tsx`（整文件替换）
- Create: `frontend/src/shortDrama/WorkbenchShell.tsx`
- Create: `frontend/src/shortDrama/WorkbenchHeader.tsx`
- Create: `frontend/src/shortDrama/StepRail.tsx`
- Create: `frontend/src/shortDrama/Inspector.tsx`
- Create: `frontend/src/shortDrama/FooterMeters.tsx`
- Create: `frontend/src/shortDrama/CanvasView.tsx`
- Create: `frontend/src/shortDrama/EntryForms.tsx`
- Create: `frontend/src/shortDrama/StageRouter.tsx`
- Create: `frontend/src/shortDrama/stages/*.tsx`（8 个占位/只读舞台）
- Modify: `frontend/src/shortDrama/pipelineDag.ts`
- Modify: `frontend/src/shortDrama/ShortDrama.css`（整文件替换）
- Test: 手工 + build

**Interfaces:**
- `ShortDrama()`：拉取 series 列表；无剧渲染 `<EntryForms mode="series" />`；有剧无集渲染 `<EntryForms mode="episode" />`；否则渲染 `<WorkbenchShell bundle={bundle} onBundle={...} onReload={...} />`。
- `WorkbenchShell` props：

```ts
interface Props {
  bundle: EpisodeBundle
  onBundle: (bundle: EpisodeBundle) => void
  onReload: () => void
}
```

- `StageRouter` props：

```ts
interface Props {
  step: StepKey
  bundle: EpisodeBundle
  selectedShotId: string | null
  onBundle: (bundle: EpisodeBundle) => void
  onReload: () => void
  onSelectShot: (id: string | null) => void
}
```

- `WorkbenchHeader` props：`{ series: DramaSeries; episodes: EpisodeSummary[]; episodeId: string; view: "prod" | "canvas"; onEpisodeChange: (id: string) => void; onViewChange: (view: "prod" | "canvas") => void }`。
- `StepRail` props：`{ steps: StepView[]; selected: StepKey; onSelect: (key: StepKey) => void }`。
- `Inspector` props：`{ step: StepView; shot: StoryboardShot | null; planShot: PlanShot | null }`。
- `FooterMeters` props：`{ actualYuan: number; totalYuan: number; shotCount: number; hookCount: number }`。
- `CanvasView` props：`{ steps: StepView[]; selected: StepKey; onSelect: (key: StepKey) => void }`；复用 `DAG_NODES` / `DAG_EDGES` 画 SVG 连线，节点 meta 用 `dagNodeMetaFromStep`，点击节点切回对应工序。
- `EntryForms` props：`{ mode: "series"; onCreated: (series: DramaSeries) => void } | { mode: "episode"; seriesId: string; onCreated: (episode: DramaEpisode) => void }`。表单自己拉 `/api/dialects`，失败时退化为纯文本输入，不阻塞创建。
- `pipelineDag.ts` 增加 `dagNodeMetaFromStep(key: DagNodeKey, steps: StepView[]): string`；`DAG_BANNER` 改为 `"工序状态来自本地 state · 未接入项不显示进度"`。

- [ ] **Step 1: 写只读占位舞台并接线**

- `SplitStage`：显示源文本 `textarea`（只读）+ `story.beats` 列表。
- `StoryStage`：显示 logline/synopsis/beats/cast（只读）。
- `BoardStage`：显示分镜数量、总时长、plan totals/warnings（只读）。
- `CastStage` / `FrameStage` / `VoiceStage` / `EditStage` / `PackStage`：显示「未接入（P2/P3）」+ 当前数据摘要。
- `Inspector`：选中镜头显示 `shot_id/kind/framing/speaker/line/duration/priority`；选中工序显示 `status/summary/cost`。
- `FooterMeters`：成本 = `state.cost.actual_yuan` / `episode.settings.total_budget_yuan`；其他无真实数据指标显示 `—`。
- `WorkbenchHeader`：剧名、`竖屏 · 方言 · 类型 · N 集`、集选择器、视图切换、预算条、缓存 `—`。
- `StepRail`：8 工序，状态点 class `st-{status}`，未接入显示 `未接入`。
- `ShortDrama.css`：按原型写深色三栏；左栏 232px，右栏 300px，<940px 隐藏右栏，<760px 左栏横排。
- `ShortDrama.tsx` 不再 import `pipelineDag` 之外的旧产线组件；保留 `view` 状态。`view === "canvas"` 时渲染 `CanvasView`，点击节点把 `selectedStep` 切到对应工序并回到产线视图。

- [ ] **Step 2: 跑前端检查**

Run: `cd frontend && npm run lint && npm run build`
Expected: PASS。若 TypeScript 报未使用变量，删除而非 `any`。

- [ ] **Step 3: 重建 web_build**

Run: `make web`
Expected: `web_build/` 更新。

- [ ] **Step 4: 手工检查**

Run: `make run`（有 GUI 时）
Expected: 打开「短剧工作台」tab → 无剧时显示新建剧表单；建剧后显示新建集；建集后三栏出现 8 工序，未接入工序显示「未接入」。

- [ ] **Step 5: 提交**

```bash
git add frontend/src/ShortDrama.tsx frontend/src/shortDrama/WorkbenchShell.tsx \
  frontend/src/shortDrama/WorkbenchHeader.tsx frontend/src/shortDrama/StepRail.tsx \
  frontend/src/shortDrama/Inspector.tsx frontend/src/shortDrama/FooterMeters.tsx \
  frontend/src/shortDrama/CanvasView.tsx frontend/src/shortDrama/EntryForms.tsx \
  frontend/src/shortDrama/StageRouter.tsx \
  frontend/src/shortDrama/stages frontend/src/shortDrama/pipelineDag.ts \
  frontend/src/shortDrama/ShortDrama.css web_build
git commit -m "feat(web): 短剧工作台骨架"
```

---

### Task 10: 故事 → 分镜创作闭环

**Files:**
- Modify: `frontend/src/shortDrama/stages/SplitStage.tsx`
- Modify: `frontend/src/shortDrama/stages/StoryStage.tsx`
- Modify: `frontend/src/shortDrama/stages/BoardStage.tsx`
- Create: `frontend/src/shortDrama/StoryboardTable.tsx`
- Create: `frontend/src/shortDrama/PlanSummary.tsx`
- Create: `frontend/src/shortDrama/DramaCostGate.tsx`
- Test: `frontend/src/shortDrama/storyboard.test.ts`（补保存前校验用例）

**Interfaces:**
- `DramaCostGate` props：

```ts
interface Props {
  estimate: DramaEstimate
  busy: boolean
  onCancel: () => void
  onConfirm: () => void
}
```

- `StoryboardTable` props：

```ts
interface Props {
  draft: StoryboardDraft
  onChange: (draft: StoryboardDraft) => void
  disabled?: boolean
  onSelectShot?: (id: string) => void
}
```

- `PlanSummary` props：`{ plan: Plan | null; i2vBudgetYuan: number; totalBudgetYuan: number; actualYuan: number }`。

- [ ] **Step 1: 实现拆片/故事/分镜流程**

- 拆片：`textarea` 可编辑 → 「保存文本」调 `dramaApi.updateEpisode`（构造 `episode` 副本，只改 `source.text`）；「拆片」先 `estimate(['story'])` → `DramaCostGate` → `extractStory`；结果面板展示 logline/synopsis/beats/cast diff；「应用」同时 `updateSeries` 与 `updateEpisode`。合并规则：`cast_new` 中不存在的 cast id 直接新增；`cast_updates` 只填充现有角色中为空的 `description/voiceId/dialect`，已有非空值一律不覆盖；`name` 只在为空时填。应用时把 `extract.sourceHash` 写入 `episode.story.sourceHash`，然后 `onReload()`。
- 故事：编辑 logline/synopsis/beats（增删改排序）与角色（可增删；name/description/voice_id/dialect）；「保存」先 `updateSeries`，再 `updateEpisode`；成功后 `onReload`。所有必填为空时禁用保存并显示错误。同一表单允许改本集设置：方言、总预算、i2v 预算、目标时长；保存设置时若已有分镜，服务端会自动重算计划单，前端提示「计划单已更新」。
- 分镜：`StoryboardTable` 编辑；「生成草稿」先 `estimate(['storyboard'])` → gate → `draftStoryboard` → 替换 draft；「保存并重算」先 `validateStoryboardDraft`，无错误后 `saveStoryboard` → `onBundle`。
- `StoryboardTable` 列：镜号、类型（select）、景别、角色（select cast + 空）、台词、时长、优先级（select）、成本（只读，来自 plan 匹配 shot_id，缺省 `—`）；行操作上移/下移/删除；底部「＋ 添加镜头」。
- `PlanSummary` 显示：镜头数、总时长、i2v 秒数、预估成本、剩余预算、warnings。
- `DramaCostGate`：`total_estimated_yuan` 与 `unpriced` 同时展示；有 unpriced 时必须勾选 checkbox 才能确认；超预算时确认禁用；不使用原生对话框。

- [ ] **Step 2: 补测试**

`storyboard.test.ts` 增加：

```ts
it('save validation rejects zero/NaN/negative durations', () => {
  for (const value of ['0', '-1', 'abc', 'NaN', 'Infinity']) {
    const draft = storyboardToDraft(minimalBoard())
    draft.shots[0].duration = value
    expect(validateStoryboardDraft(draft)).toContain('第 1 镜时长必须是有限正数')
  }
})
```

- [ ] **Step 3: 跑前端检查**

Run: `cd frontend && npm test && npm run lint && npm run build`
Expected: PASS。

- [ ] **Step 4: 重建 web_build**

Run: `make web`

- [ ] **Step 5: 手工检查**

Run: `make run` → 新建剧/集 → 粘故事 → 保存 → 拆片（勾选未估价）→ 应用 → 生成分镜 → 编辑台词/时长 → 保存并重算 → 计划单数字变化。

- [ ] **Step 6: 提交**

```bash
git add frontend/src/shortDrama/stages/SplitStage.tsx \
  frontend/src/shortDrama/stages/StoryStage.tsx \
  frontend/src/shortDrama/stages/BoardStage.tsx \
  frontend/src/shortDrama/StoryboardTable.tsx frontend/src/shortDrama/PlanSummary.tsx \
  frontend/src/shortDrama/DramaCostGate.tsx \
  frontend/src/shortDrama/storyboard.test.ts web_build
git commit -m "feat(web): 故事到分镜创作闭环"
```

---

### Task 11: 五能力进驻与单一入口收口

**Files:**
- Create: `frontend/src/SpeakerStudio.tsx`
- Modify: `frontend/src/App.tsx`
- Modify: `frontend/src/ImageStudio.tsx`
- Modify: `frontend/src/VideoStudio.tsx`
- Modify: `frontend/src/shortDrama/stages/CastStage.tsx`
- Modify: `frontend/src/shortDrama/stages/FrameStage.tsx`
- Modify: `frontend/src/shortDrama/stages/VoiceStage.tsx`
- Modify: `frontend/src/shortDrama/stages/EditStage.tsx`
- Modify: `frontend/src/shortDrama/stages/PackStage.tsx`
- Modify: `frontend/src/shortDrama/pipelineDag.ts`
- Test: 手工 + build

**Interfaces:**
- `SpeakerStudio({ initialTheme = '', contextLabel }: { initialTheme?: string; contextLabel?: string })`
- `ImageStudio({ initialPrompt = '', contextLabel }: { initialPrompt?: string; contextLabel?: string })`
- `VideoStudio({ mode, initialPrompt = '', contextLabel }: { mode: VideoMode; initialPrompt?: string; contextLabel?: string })`

- [ ] **Step 1: 提取 SpeakerStudio**

把 `App.tsx` 里主讲人的 state（dialects、t2v、duration、dialect、theme、run、polling、confirming、formError、pollRef）、effect、`pollRun`、`handleSubmit`、`confirmAndGenerate`、预览/下载 UI 原样搬进 `SpeakerStudio.tsx`；props 只用于初始主题与上下文提示。行为保持不变。

- [ ] **Step 2: 给 Image/Video 加可选上下文**

- `ImageStudio`：`useState(initialPrompt)`；在表单顶部显示 `contextLabel`（有值时）。
- `VideoStudio`：`useState(initialPrompt)`；在表单顶部显示 `contextLabel`；`mode` 行为不变。
- 不改变任何请求 body、计费或校验。

- [ ] **Step 3: 工序嵌入**

- 定妆：角色卡（series.cast）+ `<ImageStudio initialPrompt={角色描述 + 风格} contextLabel="定妆 · 全季复用" />`；页面注明 P1 结果不自动回填。
- 画面：镜头下拉/列表 + `<ImageStudio key={'img-'+shot.id} initialPrompt={shot.visual ?? shot.line} contextLabel={shot.id} />` + `<VideoStudio key={'vid-'+shot.id} mode="i2v" initialPrompt={shot.motion ?? ''} contextLabel={shot.id} />`；注明首帧需手动选择。
- 声音：台词列表 + `<SpeakerStudio initialTheme={selected?.line ?? ''} contextLabel="主讲人导读 · 非逐句配音" />`；注明逐句配音 P3。
- 剪辑：`<EditCostEstimator />` + 说明「成本对比只读，合成 P3」。
- 打包：未接入占位，列出未来产物。
- `pipelineDag.ts`：节点 meta 用 `dagNodeMetaFromStep`；横幅改为真实 state 文案。

- [ ] **Step 4: App 只留工作台**

`App.tsx` 改为：

```tsx
import ShortDrama from "./ShortDrama";
import "./App.css";

export default function App() {
  return <ShortDrama />;
}
```

删除所有旧 tab、旧 speaker state、未使用 import。保留 `App.css`（内嵌工具仍依赖其中的 `.form/.field/.layout` 等样式）。

- [ ] **Step 5: 跑全量检查**

Run:

```bash
cd frontend && npm test && npm run lint && npm run check:dialogs && npm run build && cd ..
make analyze
make test-dart
```

Expected: 全绿，analyze 零告警。

- [ ] **Step 6: 重建 web_build**

Run: `make web`
Expected: `web_build/` 更新。

- [ ] **Step 7: 手工检查**

Run: `make run`
Expected:

- 顶部不再有五个 tab，只显示工作台。
- 定妆/画面/声音/剪辑四个工序能打开原工具，且表单有当前镜头/角色提示。
- 未接入的打包工序显示「未接入」。
- 画布视图节点状态来自 steps，不显示假进度。

- [ ] **Step 8: 提交**

```bash
git add frontend/src/SpeakerStudio.tsx frontend/src/App.tsx \
  frontend/src/ImageStudio.tsx frontend/src/VideoStudio.tsx \
  frontend/src/shortDrama/stages/CastStage.tsx \
  frontend/src/shortDrama/stages/FrameStage.tsx \
  frontend/src/shortDrama/stages/VoiceStage.tsx \
  frontend/src/shortDrama/stages/EditStage.tsx \
  frontend/src/shortDrama/stages/PackStage.tsx \
  frontend/src/shortDrama/pipelineDag.ts web_build
git commit -m "feat(web): 五能力进驻短剧工作台"
```

---

## 验收清单

- [ ] `make analyze` 零告警。
- [ ] `make test-dart` 全绿（含 `test/pipeline/drama/**`、`test/server/drama_api_test.dart`）。
- [ ] `cd frontend && npm test && npm run lint && npm run check:dialogs && npm run build` 全绿。
- [ ] `make web` 后 `web_build/` 已更新并提交。
- [ ] 新建剧/集、保存故事、拆片、生成分镜、编辑、保存、计划单重算全部可用。
- [ ] 未接入工序显示「未接入」，`run` 返回 501。
- [ ] 无剧/无集/无分镜空态不白屏。
- [ ] `git status` 不含 `pipeline_out/`、`.env`、密钥、无关 WIP。
- [ ] 提交信息符合 Conventional Commits + 中文描述 + scope。
