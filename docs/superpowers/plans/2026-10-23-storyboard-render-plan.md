# 短剧垂直切片：分镜表 → 渲染计划单 + 工作台 UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: 用 `superpowers:subagent-driven-development`（推荐）或
> `superpowers:executing-plans` 逐 Task 执行。步骤用 checkbox（`- [ ]`）跟踪。
> **本计划已按 `2026-10-23-storyboard-render-plan-audit.md` 的两轮审计修订**（第一轮 P0/P1/P2 + 第二轮 R2-*）。
>
> **本期范围变更（产品方确认）**：把 `prototype/short-drama-console.html` 的工作台 UI 纳入本期（Task 5–6）。
> 因此第一轮审计锁定的「纯 Dart、只新增文件」边界不再适用；本版明确列出允许修改的既有文件与
> `web_build/` 构建产物。落地前按本版重新过一轮审计。

**Goal:** 一集短剧从分镜表走到「可看的工作台」：纯 Dart 计划单（路由 / i2v 秒数 / 成本 / 降级）+
一个本地 HTTP 端点 + 一个对齐原型的 React 页面。全程不发真实生成请求。

**Architecture:** 后端四个新模块（`frame` / `storyboard` / `render_plan` / `planner_cli`）+ 一个只读端点
（`GET /api/short-drama/plans/<id>`）；前端新增「短剧工作台」tab，读计划单渲染产线视图，并用静态 DAG
数据渲染画布预览。计划单也是后续 conatus workflow、批量队列与真实渲染 PR 的共同数据源。

**Tech Stack:** Dart 3.12（`package:args ^2.6.0`、`package:test`）、React 19 + TypeScript + Vite 8 + vitest + oxlint。
**不新增任何依赖**（Dart 与 npm 都不加）。

**Spec:** 本文档自身；审计意见见 `docs/superpowers/plans/2026-10-23-storyboard-render-plan-audit.md`；
交互基准见 `prototype/short-drama-console.html`（设计参考，不参与构建，不要修改）。

---

> **执行前请先读**：`Global Constraints`、`Decisions`、`Review Focus`、§1、§2，再按 Task 1→7 开始。
> 当前工作区没有源码 WIP，但有若干无关 untracked（`.vscode/`、`AGENTS.md`、`docs/upstream/`、
> `prototype/`、计划/审计文档）——保持原样，不要提交。`test/fixtures/ep07.storyboard.json` 已预置，
> 不要重写。遇到文档未定的选择先停下来问，不要自行扩大范围。

## Global Constraints

- `lib/pipeline/**`、`lib/server/**` 禁止 `import 'package:flutter/...'`（纯 Dart，可 CLI 跑）。
- **不新增依赖**：Dart 不加包，前端不加 npm 包；路径拼接用 `dart:io` + 字符串，**不得 import `package:path`**。
- **价格只能来自目录**：`wan2.6-i2v-flash` / 720P / 0.15 元/秒；本 PR 不提供价格覆盖，也不读
  `pipeline_config.json` 的 `pricing.*`。纯函数 `buildRenderPlan` 只接收价格参数，内部不做 IO。
- **不改变既有语义**：不碰 `state.json`、不碰 `ffmpeg`、不接百炼、不接 conatus、不发真实网络请求。
- **改动范围**（除此之外不改任何既有文件）：
  - 新增：`lib/pipeline/frame.dart`、`storyboard.dart`、`render_plan.dart`、`planner_cli.dart`、`bin/short_drama.dart`；
    `test/pipeline/{storyboard,render_plan,planner_cli}_test.dart`、`test/server/short_drama_api_test.dart`、
    `test/fixtures/README.md`；`frontend/src/shortDrama/{model.ts,model.test.ts,pipelineDag.ts,ShortDrama.css}`、
    `frontend/src/ShortDrama.tsx`。
  - 修改：`lib/pipeline/generation_models.dart`、`test/pipeline/generation_models_test.dart`、
    `test/server/video_api_test.dart`（Task 1）；`lib/server/api_router.dart`、`lib/server/pipeline_server.dart`、
    `test/server/api_router_test.dart`、`Makefile`（Task 5）；`frontend/src/App.tsx`（Task 6）。
  - 生成物：`web_build/**`（Task 6 必须 `make web` 后提交，AGENTS 要求）。
  - 预置：`test/fixtures/ep07.storyboard.json`（已存在，勿改写）。
- **`prototype/` 是设计基准**：可以照着做，不要改它，也不要把它的静态数据当成运行时真值。
- 提交时显式 `git add <文件列表>`，**禁止 `git add -A` / `git add .`**；无关 untracked 保持原样。
- 输出用 `stdout.writeln` / `stderr.writeln`，**不用 `print`**（`flutter_lints` 的 `avoid_print` 会报）。
- 错误分类：Storyboard 解析 / 文件 IO 输入错误 → `PipelineError(ErrorClass.fatal, ...)`；
  `buildRenderPlan` 参数错误 → `ArgumentError`；**不新造平行异常类**；CLI 分别映射 65 / 64。
- 前端：只经本地 `/api` 访问后端；**不得使用 `window.confirm/alert`**（`npm run check:dialogs` 会拦）；
  新增 tab 不得改变既有四个模式的行为。
- 确定性：计划单输出不得含时间戳、随机数、绝对路径；同一输入两次执行逐字节一致。
- 每个 Task 走 TDD：先写失败测试 → 跑失败 → 实现 → 跑通过 → `make analyze` / `npm run lint` 零告警 → 提交。
- 收尾基线：`make analyze` 零告警、`make test-dart` 全绿（v2 后 pipeline 250 例，含新增端点测试）、`npm test` / `npm run lint` / `npm run build` 通过。

## Decisions（已定，不留 TBD）

| ID | 决策 | 取值 |
|---|---|---|
| D-01 | i2v 模型与分辨率 | **`wan2.6-i2v-flash`，720P 生成（720×1280）**；`frame: 1080x1920` 只是输出画布，渲染阶段放大。目录价 720P = **0.15 元/秒**（1080P = 0.25，不用） |
| D-02 | `duration_s` 边界 | `<=0` / 非有限值 → 输入错误；`0<d<0.8` → 夹到 0.8 并记 `duration_raised:<id>`；`d>30` → 夹到 30 并记 `duration_clamped:<id>` |
| D-03 | i2v 单镜上限 | `i2v_seconds = clamp(ceil(duration), 2, 10)`；**只在真的分配到 i2v 时**，`ceil<2` 记 `i2v_min_duration_raised:<id>`、`>10` 记 `i2v_capped:<id>`；渲染阶段负责把 10 秒扩展到镜头时长 |
| D-04 | 错误类型 | 解析/IO → `PipelineError.fatal`（CLI 65）；纯函数参数 → `ArgumentError`（CLI 64） |
| D-05 | Task 边界 | 目录补全、计划/预算、CLI、端点、UI、收尾各自独立成 Task、一笔提交 |
| D-06 | 价格口径 | 默认 = 目录价（`wan2.6-i2v-flash` 720P = **0.15**）；本 PR **不提供价格覆盖**；画质档（wan3.0-video 0.42）等后续 PR 做「模型切换 + 目录价」 |
| D-07 | UI 数据源 | UI 只读 `07_plan.json`（新增展示字段 `framing/speaker/line/priority`）；不读 storyboard、不读 state |
| D-08 | 画布视图的诚实边界 | 画布节点来自 `frontend/src/shortDrama/pipelineDag.ts` 静态设计数据；只有「分镜 / 画面」两个节点可从 plan 派生数字，其余显示「未接入」+ 顶部横幅「设计预览 · 工序状态未接入 conatus」。**禁止编造运行时状态** |

## Review Focus（最可能出错的输入，每项都有对应测试）

1. **价格来自目录**：Task 1 必须先补 `wan2.6-i2v-flash`；`defaultI2vPriceYuanPerSecond() == 0.15`，目录缺失直接 `throw StateError`，不静默回退。
2. **`duration_s` 为 0 / 负数 / NaN / Infinity**：解析阶段抛错，不能进入 `clamp` / `floor`。
3. **`priorityRank` 不依赖枚举声明顺序**：声明序是 `hook,turn,payoff,normal`，rank 是 `hook=0,payoff=1,turn=2,normal=3`；用 `.index` 会让 **1 元预算**先给 `s04`（turn）而不是 `s08`（payoff）。
4. **wire name 是 snake_case**：`speakOff` ↔ `speak_off`，`listenFace` ↔ `listen_face`；直接 `.name` 会让 roundtrip 失败。
5. **浮点求和**：12 个时长直接相加 = `30.199999999999996`；`totals` 必须 `_round1`；`remaining = max(0, round2(...))`。
6. **预算不足**：整镜降级，不给部分预算；1.5 元是「刚好花完」的边界（cap=10 秒）。
7. **warning 语义**：`i2v_min_duration_raised` / `i2v_capped` 只在分配成功时产生；解析期 warning 必须并入 plan 且顺序稳定去重。
8. **CLI 子命令**：`buildPlannerParser()` 必须 `addCommand('plan')`；`--storyboard` 非 mandatory。
9. **既有测试联动**：Task 1 必须删 `generation_models_test.dart` 里的 `isNull` 断言；`video_api_test.dart` 的「双模式」断言要改成分别断言（prime 仍双模式）。
10. **端点安全**：`content_id` 必须匹配 `^[A-Za-z0-9_-]+$`；非法 400、文件不存在 404；只读 `pipeline_out`，不接受任意路径。
11. **`web_build` 必须重建**：改前端后不 `make web` 并提交产物，桌面 app 里看到的还是旧 UI（这是入库产物，AGENTS §3）。
12. **画布不得造假**：除「分镜 / 画面」外不显示编造的运行状态；必须有「设计预览」横幅（D-08）。

---

## 1. 数据契约

### 1.1 输入：`storyboard.json`（fixture 已预置，12 镜）

内容见 `test/fixtures/ep07.storyboard.json`，与审计版 §1.1 一致（12 镜、总时长 30.2 秒）。字段规则：

| 字段 | 必需 | 规则 |
|---|---|---|
| `content_id` | ✅ | 非空，仅 `[A-Za-z0-9_-]`；否则 `PipelineError.fatal` |
| `title` | ❌ | 缺省 = `content_id` |
| `shots` | ✅ | 非空数组；`shots[].id` 非空且唯一 |
| `shots[].kind` | ✅ | `speak_off` / `insert` / `listen_face` / `action` / `establishing`；未知值降级为 `speak_off` + warning |
| `shots[].line` | ❌ | 缺省 `""`；`avatar` 判断用 `line.trim().isNotEmpty` |
| `shots[].duration_s` | ❌ | 缺省按台词估算；`<=0` / 非有限 → 抛错；`0<d<0.8` → 0.8 + `duration_raised`；`d>30` → 30 + `duration_clamped` |
| `shots[].speaker` | ❌ | 不在 `cast` → warning，不抛错 |
| `shots[].priority` | ❌ | 缺省 `normal`；未知值 → `normal` + warning |
| `shots[].framing` | ❌ | 缺省 `"unknown"`，透传 |
| `frame` | ❌ | `宽x高`；缺省 `1080x1920`；非法抛错；非竖屏 → `frame_not_vertical` |
| `budget_yuan` | ❌ | 缺省 `120`；必须有限且 >0；CLI `--budget` 优先 |
| `cast` | ❌ | 缺省空表 |

### 1.2 输出：`07_plan.json`

> 节选 3 镜；实际输出全部镜头、按输入顺序。新增的展示字段（`framing/speaker/line/priority`）
> 是给 UI 用的，不参与计算。

```json
{
  "content_id": "ep07",
  "title": "堂屋对峙",
  "frame": { "width": 1080, "height": 1920 },
  "i2v_generation": {
    "model": "wan2.6-i2v-flash", "resolution": "720P",
    "width": 720, "height": 1280
  },
  "budget_yuan": 20.0,
  "price_yuan_per_second": 0.15,
  "max_i2v_seconds": 0,
  "shots": [
    { "shot_id": "s01", "kind": "speak_off", "route": "kenburns", "avatar": true,
      "duration_s": 3.0, "i2v_seconds": 0, "cost_yuan": 0.0, "downgrade_reason": null,
      "framing": "over_shoulder", "speaker": "erniu",
      "line": "你欠我的，今天该还了。", "priority": "hook" },
    { "shot_id": "s04", "kind": "action", "route": "i2v", "avatar": false,
      "duration_s": 3.0, "i2v_seconds": 3, "cost_yuan": 0.45, "downgrade_reason": null,
      "framing": "medium", "speaker": "erniu", "line": "", "priority": "turn" },
    { "shot_id": "s12", "kind": "listen_face", "route": "i2v", "avatar": false,
      "duration_s": 1.8, "i2v_seconds": 2, "cost_yuan": 0.3, "downgrade_reason": null,
      "framing": "close", "speaker": "xiaoman", "line": "", "priority": "payoff" }
  ],
  "totals": {
    "duration_s": 30.2, "i2v_seconds": 13,
    "estimated_yuan": 1.95, "remaining_yuan": 18.05
  },
  "counts": { "kenburns": 6, "micro": 1, "i2v": 5 },
  "warnings": []
}
```

### 1.3 序列化规则

- `ShotKind` / `ShotPriority` 的 JSON wire name 一律 snake_case；提供显式映射函数，不用 `.name`。
- `Storyboard.toJson`：`frame` 输出 `"1080x1920"`；不输出 `warnings`；canonical roundtrip =
  `fromJson(toJson(x)).toJson() == toJson(x)`。
- `RenderPlan.toJson`：`frame` 输出对象；`i2v_generation` 固定从
  `kPlanI2vModel / kPlanI2vResolution / kPlanI2vWidth / kPlanI2vHeight` 生成（不额外存字段）；
  `counts` 固定三键（零值也输出）；`downgrade_reason` 始终存在。
- 数值：`duration_s` 用 `_round1`；金额/预算/单价用 `_round2`；`_round1/_round2` 返回 `double`。
- stdout 与文件内容统一为 **pretty JSON（2 空格）+ 一个 `\n`**。

---

## 2. 算法（纯函数、确定性）

### 2.1 wire 映射与排序

```dart
String shotKindToWire(ShotKind kind);
ShotKind? shotKindFromWire(String raw);
String shotPriorityToWire(ShotPriority p);
ShotPriority? shotPriorityFromWire(String raw);
int priorityRank(ShotPriority p);   // switch: hook=0,payoff=1,turn=2,normal=3
```

### 2.2 时长

```dart
double resolveDuration(Shot shot, List<String> warnings);   // 公开，供测试
```

```
显式 duration_s（解析阶段已保证有限且 >0）:
    d = shot.durationS!
    if d < 0.8: warnings += duration_raised:<id>; d = 0.8
    if d > 30 : warnings += duration_clamped:<id>; d = 30
    return round1(d)
缺省:
    chars = shot.line.trim().runes.length
    if chars == 0: return 2.0
    return ceil1(clamp(chars / 4.5, 1.2, 30.0))
```

### 2.3 默认路由

| kind | 默认 route | avatar | 说明 |
|---|---|---|---|
| `speak_off` | `kenburns` | `line.trim().isNotEmpty` | 画外音；头像卡渲染阶段叠加 |
| `insert` | `kenburns` | false | 道具/特写 |
| `establishing` | `kenburns` | false | 空镜 |
| `listen_face` | `micro` | false | 听者反应；可被预算升级为 `i2v` |
| `action` | 候选 `i2v` | false | 预算不足降级为 `micro` |

### 2.4 预算分配

```
预算 = 参数 budgetYuan ?? storyboard.budgetYuan
capSeconds = floor(预算 / 单价)
if maxI2vSeconds > 0: capSeconds = min(capSeconds, maxI2vSeconds)

候选 = 所有 action ∪ (listen_face 且 priority != normal)
排序 = priorityRank 升序，其次原始下标升序
remaining = capSeconds

for shot in 排序后候选:
    need = clamp(ceil(shot.durationS), 2, 10)
    if need <= remaining:
        if ceil(shot.durationS) < 2: warnings += i2v_min_duration_raised:<id>
        if ceil(shot.durationS) > 10: warnings += i2v_capped:<id>
        route = i2v; i2v_seconds = need; remaining -= need
    else:
        route = micro; i2v_seconds = 0; downgrade_reason = "budget_insufficient"

if 候选非空 && 没有任何 i2v: warnings += no_i2v_budget
```

- 不部分分配；`cost = round2(i2v_seconds * 单价)`；`estimated = round2(Σcost)`；
  `remaining = max(0, round2(预算 - estimated))`。

### 2.5 warnings

`unknown_kind:<id>:<raw>`、`unknown_priority:<id>:<raw>`、`speaker_not_in_cast:<id>:<speaker>`、
`duration_raised:<id>`、`duration_clamped:<id>`、`i2v_min_duration_raised:<id>`、
`i2v_capped:<id>`、`frame_not_vertical`、`no_i2v_budget`。

`i2v_min_duration_raised` / `i2v_capped` 只在真的分配到 i2v 时产生；`plan.warnings =
去重([...storyboard.warnings, ...planWarnings])`，保留首次出现顺序（`LinkedHashSet`）。

### 2.6 数值安全

所有进入计算的数必须 `isFinite`：价格 >0、预算 >0、`maxI2vSeconds >= 0`、时长 >0。
纯函数参数错误抛 `ArgumentError`；CLI 参数错误 64、输入错误 65。

---

## 3. 任务

### Task 1: 视频目录补 `wan2.6-i2v-flash`

**Files**
- Modify: `lib/pipeline/generation_models.dart`
- Modify: `test/pipeline/generation_models_test.dart`
- Modify: `test/server/video_api_test.dart`

**新增目录项（追加到 `kVideoModels` 末尾）**

```dart
VideoModel(
  id: 'wan2.6-i2v-flash',
  label: '万相 2.6 图生视频 Flash',
  modes: <VideoMode>{VideoMode.i2v},
  resolutions: <String>['720P', '1080P'],
  durationMin: 2,
  durationMax: 15,
  supportsAudio: false,
  defaultPrices: <String, double>{'720P': 0.15, '1080P': 0.25},
  // 本目录项仅登记无声档；有声档（720P 0.3 / 1080P 0.5）暂不收录。
),
```

**TDD 步骤**
- [ ] 改 `generation_models_test.dart`：删除 `expect(findVideoModel('wan2.6-i2v-flash'), isNull);`；
      测试名改为覆盖 wan3.0 + wan2.6；期望 id 列表加 `'wan2.6-i2v-flash'`；
      新增断言：`modes == {VideoMode.i2v}`、`defaultPrices == {'720P':0.15,'1080P':0.25}`、
      `durationMax == 15`、`supportsAudio == false`；先跑红。
- [ ] 改 `video_api_test.dart`：「每个模型至少一个模式；`wan3.0-video` 与 `wan3.0-video-prime`
      都含 `t2v`+`i2v`；`wan2.6-i2v-flash` 只有 `i2v`」；先跑红。
- [ ] 加目录项；文件头注释改为「视频生成模型目录（t2v / i2v）」。
- [ ] 两个测试转绿；`make analyze` 零告警。
- [ ] 提交：`feat(generation): 视频目录补 wan2.6-i2v-flash（720P 0.15）`

### Task 2: 画幅 + 分镜表

**Files**
- Create: `lib/pipeline/frame.dart`
- Create: `lib/pipeline/storyboard.dart`
- Create: `test/pipeline/storyboard_test.dart`
- Provided（已预置，勿改写）: `test/fixtures/ep07.storyboard.json`

**Interfaces**

```dart
class FrameSize {
  const FrameSize(this.width, this.height);
  static const FrameSize vertical = FrameSize(1080, 1920);
  static FrameSize? tryParse(String raw);   // "1080x1920" / "1080*1920"
  final int width; final int height;
  bool get isVertical;
  String get label;
  Map<String, Object?> toJson();
}

enum ShotKind { speakOff, insert, listenFace, action, establishing }
enum ShotPriority { hook, turn, payoff, normal }

class CastMember { /* id,name,voiceId,dialect + toJson */ }
class Shot { /* id,kind,framing,speaker,line,durationS,priority,prop,motion + toJson */ }

class Storyboard {
  final String contentId, title; final String? dialect;
  final FrameSize frame; final double budgetYuan;
  final Map<String, CastMember> cast; final List<Shot> shots;
  final List<String> warnings;
  static Storyboard fromJsonString(String source);  // 失败抛 PipelineError.fatal
  static Storyboard fromJson(Map<String, Object?> json);
  Map<String, Object?> toJson();                    // 不含 warnings
}
```

**TDD 步骤**
- [ ] 写失败测试：frame 解析（`x`/`*`/非法）；最小输入；全字段输入；canonical roundtrip；
      未知 kind / priority 降级 + warning；speaker 不在 cast 只 warning；
      重复 id / 空 shots / 非法 content_id / `budget_yuan<=0`/NaN /
      `duration_s` 为 `0`、`-1`、`NaN`、`Infinity` → `PipelineError.fatal`；非竖屏 → warning。
- [ ] 跑红；实现 `frame.dart` / `storyboard.dart`（类型错误显式 `is` 判断，不让 `TypeError` 漏出）。
- [ ] 跑绿；`make analyze` 零告警。
- [ ] 提交：`feat(short-drama): 分镜表模型与解析`

### Task 3: 渲染计划与预算分配

**Files**
- Create: `lib/pipeline/render_plan.dart`
- Create: `test/pipeline/render_plan_test.dart`

**Interfaces**

```dart
enum ShotRoute { kenburns, micro, i2v }

const String kPlanI2vModel = 'wan2.6-i2v-flash';
const String kPlanI2vResolution = '720P';
const int kPlanI2vWidth = 720;
const int kPlanI2vHeight = 1280;

class PlannedShot { /* shotId,kind,route,avatar,durationS,i2vSeconds,costYuan,downgradeReason,
                       framing,speaker,line,priority + toJson */ }
class PlanTotals { final double durationS, estimatedYuan, remainingYuan; final int i2vSeconds; Map<String,Object?> toJson(); }
class RenderPlan { /* contentId,title,frame,budgetYuan,priceYuanPerSecond,maxI2vSeconds,shots,totals,counts,warnings + toJson */ }
// toJson 固定从四个常量生成 i2v_generation；展示字段从 Shot 透传。

double resolveDuration(Shot shot, List<String> warnings);
RenderPlan buildRenderPlan({
  required Storyboard storyboard,
  required double priceYuanPerSecond,   // 必传，无默认值
  double? budgetYuan,
  int maxI2vSeconds = 0,
});
```

**TDD 步骤**
- [ ] 写失败测试（价格 0.15）：
  - 时长：显式、台词估算（11 runes→2.5）、空台词→2.0、`0.5`→0.8+raised、`30.1`→30+clamped；
  - 路由：五种 kind 默认 route/avatar（空白台词 `speak_off` avatar=false）；
  - i2v 上限（预算充足）：`ceil=1` 的 action → 2 秒 + raised；15 秒 action → 10 秒 + capped；
  - i2v 上限（预算不足）：15 秒 action 被降级 → **不得出现** capped；0.8 秒 action 被降级 → 不得出现 raised；
  - 排序：`priorityRank(payoff) < priorityRank(turn)`；**1 元预算**（cap=6）只给 `s07,s08`；
  - 预算：20 元 → 13 秒 / ¥1.95 / 余 ¥18.05 / counts `6/1/5`；1.5 元（cap=10）→
    `s07,s08,s12,s10`、¥1.50、余 0.00、counts `6/2/4`；0.2 元 → 0 个 i2v + `no_i2v_budget`、
    counts `6/6/0`；`maxI2vSeconds=4` → 只有 s07=3 秒、¥0.45、counts `6/5/1`；
    0.1 元 → 0 个 i2v、`remaining_yuan == 0.1`；
  - 输出：12 镜按 `s01..s12`；counts 三键零值也输出；`i2v_generation` 字段正确；
    展示字段（framing/speaker/line/priority）与 storyboard 一致；
  - 价格比例：0.15→0.30，cost/estimated 翻倍；
  - 精度：`totals.duration_s == 30.2`；`jsonEncode` 不含长浮点串；
  - warning 合并顺序稳定；参数校验（price/budget/max）→ `ArgumentError`；确定性两次编码相等。
- [ ] 跑红；实现；跑绿；`make analyze` 零告警。
- [ ] 提交：`feat(short-drama): 渲染计划与预算分配`

### Task 4: 计划单 CLI

**Files**
- Create: `lib/pipeline/planner_cli.dart`
- Create: `bin/short_drama.dart`（只保留 `main`）
- Create: `test/pipeline/planner_cli_test.dart`

**Interfaces**

```dart
ArgParser buildPlannerParser();          // 顶层 -h/--help；addCommand('plan')
class PlannerArgs {
  final String storyboardPath;
  final double? budgetYuan;              // null → storyboard.budget_yuan
  final int maxI2vSeconds;               // 0 = 不限
  final String? outPath;                 // null → pipeline_out/<id>/07_plan.json
}
PlannerArgs? parsePlannerArgs(ArgResults results, ArgParser parser);

double defaultI2vPriceYuanPerSecond();   // 目录价 → 0.15；目录缺失 throw StateError
String plannerUsage(ArgParser parser);   // 顶层 usage + plan 子命令与选项
String encodePlanJson(RenderPlan plan);  // pretty 2 空格 + '\n'
Future<int> runPlan(PlannerArgs args, {String? outDir, StringSink? warningSink}); // 返回退出码
Future<int> runCli(List<String> argv);   // main 只 exit(await runCli(argv))
```

**契约**
- `buildPlannerParser()` 必须 `addCommand('plan')`；`plan` 下注册 `storyboard`、`budget`、
  `max-i2v-seconds`、`out`（**不提供 price 覆盖**）；`plan` 子命令也支持 `-h/--help`。
- `--storyboard` 不设 `mandatory`；缺失/空串 → stderr usage + null；无子命令同。
- 数值 `double.tryParse` / `int.tryParse` + `isFinite` + 范围校验；不合法 null。
- 单价固定 `defaultI2vPriceYuanPerSecond()`。
- 输出路径：`args.outPath` 优先；否则 `${outDir ?? 'pipeline_out'}/${contentId}/07_plan.json`；递归建目录。
- 退出码：成功 0；参数/用法 64（含直接构造的非法 `PlannerArgs`）；读/解析失败 65；写盘失败 74。
- 成功时先写文件，再 `stdout.write(encodePlanJson(plan))`；warnings 逐条写 `warningSink ?? stderr`（`warn: …`）。
- `runCli`：`FormatException` → usage + 64；`--help` / `plan --help` → 0；其余 `runPlan`。`bin/short_drama.dart` 只 `exit(await runCli(argv))`。

**TDD 步骤**
- [ ] 写失败测试：无子命令 / 缺 storyboard / 空串 / `--budget 0`/NaN/Infinity /
      `--max-i2v-seconds -1` → null；合法参数；`--help`→0、未知子命令→64；
      `defaultI2vPriceYuanPerSecond()==0.15`；
      `runPlan`：fixture → 0、文件在 `temp/ep07/07_plan.json`、内容等于 `encodePlanJson(plan)`；
      `--out` 优先；文件不存在/JSON 语法错误/非法 schema → 65；输出路径是目录 → 74；
      低预算时 `warningSink` 含 `warn: no_i2v_budget`；`plannerUsage` 含 `plan` 与四个选项；
      `encodePlanJson` 以 `\n` 结尾且可 `jsonDecode` 还原。
- [ ] 跑红；实现；跑绿；`make analyze` 零告警。
- [ ] 提交：`feat(short-drama): 计划单 CLI`

### Task 5: 计划单读取端点

**Files**
- Modify: `lib/server/api_router.dart`
- Modify: `lib/server/pipeline_server.dart`
- Modify: `test/server/api_router_test.dart`
- Modify: `Makefile`（把新端点测试加入 `DART_TEST_CMD`，避免孤儿测试）
- Create: `test/server/short_drama_api_test.dart`

**接口与路由**

```
GET /api/short-drama/plans/<content_id>
```

- `ApiRoute` 增加 `getShortDramaPlan`；`apiRouteFor`：
  `method == 'GET' && path.startsWith('/api/short-drama/plans/')` → 该路由。
- `PipelineServer` 构造参数增加 `this.plansDir`（`final String? plansDir;`，测试 seam）；
  默认 `'pipeline_out'`（相对 CWD；桌面 app 打包态需传绝对路径，见 §6）。
- 处理函数 `_getShortDramaPlan(HttpRequest req)`：
  - 取 `req.uri.pathSegments.last`（路径形如 `['api','short-drama','plans','<id>']`，段数必须为 4）；
  - `content_id` 不匹配 `^[A-Za-z0-9_-]+$` → 400 `{'error':'invalid content id'}`；
  - 读 `${plansDir ?? 'pipeline_out'}/<id>/07_plan.json`；不存在 → 404 `{'error':'plan not found'}`；
  - 成功 → 200，原样返回该 JSON（`_sendJson`，Map 形式）。
  - `/api/short-drama/plans`（无尾斜杠）→ unknown；`/api/short-drama/plans/`（尾斜杠、空 id）→ 400。
  - 计划文件非法 JSON / 非对象 → 500 `{'error':'invalid plan file'}`；缺文件 → 404。
- `_handleApi` 增加 dispatch case。
- 把 `test/server/short_drama_api_test.dart` 加入 `Makefile` 的 `DART_TEST_CMD`。

**TDD 步骤**
- [ ] 写失败测试（`api_router_test`）：GET 合法路径 → `getShortDramaPlan`；POST 同路径 → unknown；
      `/api/short-drama/plans`（缺 id）→ unknown；`/api/short-drama/other` → unknown。
- [ ] 写失败测试（`short_drama_api_test`，临时目录作 `plansDir`）：写入计划文件 → GET 200 且
      字段正确；不存在 → 404；`bad.id` → 400；确保响应 content-type 为 JSON。
- [ ] 跑红；实现 router + server；跑绿；`make analyze` 零告警。
- [ ] 提交：`feat(server): 计划单读取端点`

### Task 6: 前端「短剧工作台」

**Files**
- Create: `frontend/src/shortDrama/model.ts`
- Create: `frontend/src/shortDrama/model.test.ts`
- Create: `frontend/src/shortDrama/pipelineDag.ts`
- Create: `frontend/src/shortDrama/ShortDrama.css`
- Create: `frontend/src/ShortDrama.tsx`
- Modify: `frontend/src/App.tsx`（mode union + tab + 渲染）
- Generated: `web_build/**`（`make web` 后提交）

**Types 与纯函数（`model.ts`）**

```ts
export type ShotRoute = "kenburns" | "micro" | "i2v";
export type ShotKind = "speak_off" | "insert" | "listen_face" | "action" | "establishing";
export type ShotPriority = "hook" | "turn" | "payoff" | "normal";

export interface PlanShot {
  shot_id: string; kind: ShotKind; route: ShotRoute; avatar: boolean;
  duration_s: number; i2v_seconds: number; cost_yuan: number;
  downgrade_reason: string | null;
  framing: string; speaker: string | null; line: string; priority: ShotPriority;
}
export interface Plan { /* content_id,title,frame,i2v_generation,budget_yuan,
  price_yuan_per_second,max_i2v_seconds,shots,totals,counts,warnings */ }

export function hookShots(shots: PlanShot[], seconds = 3): PlanShot[]; // 累计到 >= seconds（含跨越镜）
export function timelineBlocks(shots: PlanShot[]): { shot: PlanShot; start: number; width: number }[];
export function costByRoute(shots: PlanShot[]): Record<ShotRoute, number>;
export function routeLabel(route: ShotRoute): string;   // 静帧推拉 / 局部微动 / 图生视频
export function formatYuan(v: number): string;
export function formatSeconds(v: number): string;
```

**页面（`ShortDrama.tsx`）**
- 顶部：`content_id` 输入框（默认 `ep07`）+ 加载按钮/自动加载、标题、预算条（`estimated_yuan` /
  `budget_yuan`）、视图切换「产线视图 / 画布视图」。
- 数据：`fetch('/api/short-drama/plans/' + encodeURIComponent(id))`；处理 loading / 404 / 其他错误，
  错误文案中文且不崩溃；空态提示先跑 CLI。
- **产线视图（真实数据）**：前 3 秒 hook 条（`hookShots`）；时间轴按 `duration_s` 等比例铺镜，
  每块显示镜头号、route、`i2v_seconds`、`cost_yuan`；下方台词行（`line` 非空时）；
  点击选镜 → 右侧检视（kind/framing/speaker/line/route/duration/i2v/cost/downgrade_reason/avatar）；
  成本构成（按 route）；warnings 列表（无则显示「无」）。
- **画布视图（设计预览）**：`pipelineDag.ts` 的 8 个工序节点（拆片/故事/定妆/分镜/画面/声音/剪辑/打包）静态布局 + 连线；仅「分镜」节点显示
  `${shots.length} 镜`、「画面」节点显示 `${counts.i2v} 镜 i2v · ¥cost`，其余显示「未接入」；
  顶部横幅「设计预览 · 工序状态未接入 conatus」；**不得编造状态/成本**。
- 样式自包含于 `ShortDrama.css`；不引入新依赖；不使用 `window.confirm/alert`。
- `App.tsx`：mode union 加 `"short-drama"`、tab 文案「短剧工作台」、渲染 `<ShortDrama />`；默认 mode 不变。

**TDD 步骤**
- [ ] 写失败测试 `model.test.ts`：hook 边界（含 0.5s 跨越镜）、timeline 起始/宽度、
      costByRoute 求和、routeLabel、format 函数。
- [ ] 跑红（`cd frontend && npm test`）；实现 `model.ts`；跑绿。
- [ ] 实现 `pipelineDag.ts`、`ShortDrama.tsx`、`ShortDrama.css`、`App.tsx` 接线。
- [ ] `cd frontend && npm test && npm run lint && npm run build` 全通过。
- [ ] 回仓库根 `make web`，确认 `web_build/` 更新；提交时包含产物。
- [ ] 人工检查（有 GUI 时）：先生成 `pipeline_out/ep07/07_plan.json`，再 `make run`，
      打开「短剧工作台」→ 产线视图与检视/成本/告警正常，切画布视图见横幅与 8 节点。
- [ ] 提交：`feat(web): 短剧工作台（产线视图 + 画布设计预览）`

### Task 7: 收尾验收

**Files**
- Update: `test/fixtures/README.md`（已存在；补充只读说明与单行验收命令）

**步骤**
- [ ] 更新 `test/fixtures/README.md`。
- [ ] 跑 §4 全部命令，贴输出。
- [ ] `git status --short` 只含预期路径；无关 untracked 保持原样；`web_build/` 变更已包含。
- [ ] 提交：`docs(short-drama): 计划单夹具说明与验收记录`

---

## 4. 验收

```bash
cd /Users/fitz/REPO/conatus_viva

make analyze
dart test test/pipeline/generation_models_test.dart
dart test test/pipeline/storyboard_test.dart test/pipeline/render_plan_test.dart test/pipeline/planner_cli_test.dart
dart test test/server/api_router_test.dart test/server/short_drama_api_test.dart test/server/video_api_test.dart
dart test test/pipeline

# 生成计划单（默认写到 pipeline_out/ep07/07_plan.json）
dart run bin/short_drama.dart plan --storyboard test/fixtures/ep07.storyboard.json --budget 20

# 前端
cd frontend && npm test && npm run lint && npm run build && cd ..
make web          # 产出 web_build/，确认已更新

# 人工（有 GUI 时）
make run          # 从仓库根启动 app；切到「短剧工作台」
```

期望计划单关键字段：

```json
{
  "content_id": "ep07",
  "frame": { "width": 1080, "height": 1920 },
  "i2v_generation": { "model": "wan2.6-i2v-flash", "resolution": "720P", "width": 720, "height": 1280 },
  "budget_yuan": 20.0,
  "price_yuan_per_second": 0.15,
  "totals": { "duration_s": 30.2, "i2v_seconds": 13, "estimated_yuan": 1.95, "remaining_yuan": 18.05 },
  "counts": { "kenburns": 6, "micro": 1, "i2v": 5 },
  "warnings": []
}
```

端点：

```bash
curl -s http://localhost:18080/api/short-drama/plans/ep07 | head -c 200   # app 运行中
```

提交时显式列文件（**禁止 `git add -A`**）：

```bash
git add lib/pipeline/generation_models.dart \
  test/pipeline/generation_models_test.dart test/server/video_api_test.dart \
  lib/pipeline/frame.dart lib/pipeline/storyboard.dart \
  lib/pipeline/render_plan.dart lib/pipeline/planner_cli.dart \
  bin/short_drama.dart \
  test/pipeline/storyboard_test.dart test/pipeline/render_plan_test.dart \
  test/pipeline/planner_cli_test.dart \
  lib/server/api_router.dart lib/server/pipeline_server.dart \
  test/server/api_router_test.dart test/server/short_drama_api_test.dart \
  frontend/src/shortDrama/model.ts frontend/src/shortDrama/model.test.ts \
  frontend/src/shortDrama/pipelineDag.ts frontend/src/shortDrama/ShortDrama.css \
  frontend/src/ShortDrama.tsx frontend/src/App.tsx \
  web_build test/fixtures/README.md
```

## 5. Definition of Done

- [ ] `make analyze` 零告警；`dart test test/pipeline` 全绿；server 三个测试文件全绿
- [ ] `npm test` / `npm run lint` / `npm run build` 全绿；`web_build/` 已重建并提交
- [ ] 同输入重复执行，stdout 与 `07_plan.json` 逐字节一致
- [ ] 端点：合法 id 200、非法 id 400、缺文件 404；只读 `pipeline_out`
- [ ] 画布视图有「设计预览」横幅，除「分镜/画面」外不显示编造状态（D-08）
- [ ] 不新增依赖；不用 `print`；不用原生对话框；不新造异常类
- [ ] 只修改 Global Constraints 列出的既有文件；无关 untracked 原样保留
- [ ] 提交数与基线一致：v2 已合并 6 笔；本增量分支为 Task 3b/5/6/7 共 4 笔。若从零实现则 Task 1–7 共 7 笔。
- [ ] PR 描述包含：§4 实际输出、`wan2.6-i2v-flash 720P / 0.15 / frame 1080x1920` 口径说明、
      UI 截图（有 GUI 时）、一句话「本 PR 不发真实生成请求，不碰 ffmpeg/conatus」

## 6. 后续 PR（本 PR 不做）

1. 接 `pipeline_config.json` 的 `pricing.video` / `t2v.yuan_per_second` 覆盖；加「模型切换 +
   价格覆盖」并输出 `price_source` / `price_model`。
2. `lib/pipeline/ffmpeg.dart` 画幅参数化（720×1280 生成、1080×1920 输出）。
3. 按 plan 的 route 派发真实生成（i2v / 静帧 / 音频 / 合成），接百炼。
4. 注册 conatus 工具 `plan_episode`、写 `workflows/drama_episode.json`；画布视图改为读真实
   WorkflowRun 状态，去掉「设计预览」横幅。
5. 素材库（定妆/场景/首帧按 `shot_id` 检索、缓存命中回填 UI）与试投素材矩阵。
6. 桌面 app 打包态：为 `plansDir` 传绝对路径（参照 `outputDir` / `$HOME/conatus_viva/...` 惯例）。
