# 「分镜表 → 渲染计划单」计划审计意见

**审计对象**：`docs/superpowers/plans/2026-10-23-storyboard-render-plan.md`  
**审计日期**：2026-10-23  
**审计基线**：`AGENTS.md`、当前 `master`、`lib/pipeline/generation_models.dart`、`lib/pipeline/config.dart`  
**执行范围**：只修订上述计划文档，不要开始实现，不要改源码、不要发网络请求、不要改 `AGENTS.md`。  
若任务方要求直接实现，先按本意见修订计划并回报，等确认后再开工。

**审计结论（第一轮，历史记录）**：计划主体可执行，预算算例全部正确；但存在 1 个违反仓库硬约束的计价问题、1 个分辨率/单价口径冲突，以及若干会导致测试跑不通或实现结果与文档不一致的缺口。先修 P0，再修 P1，最后补 P2。**当前修订版的结论见文末「第二轮复审」。**

> **给执行 agent 的开工指令**：只修改
> `docs/superpowers/plans/2026-10-23-storyboard-render-plan.md`。
> 先读本审计 §0 的 5 个决策，回复你准备采用的值（无异议就用推荐值），再按
> P0 → P1 → P2 修订；不要实现代码，不要改源码/测试/fixture。改完按 §5 自检并回报。
>
> **状态**：第一轮审计条目保留为历史记录，未逐条删改；当前修订版的结论看文末
> 「第二轮复审（计划修订后）」。第二轮只保留仍未解决的问题，并撤回一条已确认不成立的
> “设计文档限制 CLI”判断。

**已核实的基线**

- Dart `3.12.2`；包名 `flutter_wanxiang`；`args ^2.6.0` 已在 `pubspec.yaml`。
- `dart analyze lib bin test` → `No issues found!`
- `dart test test/pipeline` → 162 个用例全绿。
- `pipeline_out/` 已在 `.gitignore`。
- §0 所说“当前工作区有未提交 WIP”已过时：当前只有 `.vscode/`、`AGENTS.md`、`docs/upstream/`、`prototype/`、计划文档等 untracked 项，`README.md` 是干净的。

---

## 0. 先定 5 个决策（无异议按推荐值写进计划）

| ID | 决策 | 推荐值 | 影响 |
|---|---|---|---|
| D-01 | i2v 生成分辨率与计价档 | i2v 固定按 **720P（720×1280）** 生成，`frame: 1080x1920` 只作为输出画布/放大目标；单价取 `generation_models.dart` 中 `wan3.0-video` 的 `720P` 档 | 保持 0.42 元/秒和现有全部算例；若改为真正的 1080P 生成，单价 0.84，所有金额/预算用例要重算 |
| D-02 | `duration_s` 边界 | `<= 0` 或非有限值 → 抛输入错误；`0 < d < 0.8` → 夹到 0.8 并记 `duration_raised:<id>`；`d > 30` → 夹到 30 并记 `duration_clamped:<id>` | 消除“必须 >0”与 `clamp(0.8, 30)` 的矛盾 |
| D-03 | i2v 单镜上限 10 秒 | `i2v_seconds = clamp(ceil(duration), 2, 10)`；`ceil(duration) < 2` 记 `i2v_min_duration_raised:<id>`；`ceil(duration) > 10` 记 `i2v_capped:<id>`，由渲染阶段负责补齐/循环到镜头时长 | 让两个“死 warning”有明确触发条件，并说清 30 秒 action 只买 10 秒 i2v 的语义 |
| D-04 | 错误类型 | 用 `PipelineError(ErrorClass.fatal, ...)`，CLI 将 fatal 输入错误映射为 65；不新造平行异常体系 | 对齐 `AGENTS.md` §5“错误统一走 `PipelineError` + `ErrorClass`” |
| D-05 | Task 2 / Task 3 边界 | 合并为一个 Task「渲染计划与预算分配」，或明确 Task 2 只测非 action 路由、action 的 i2v/降级只在 Task 3 测 | 避免 Task 2 先写“action 永远 i2v”、Task 3 再改行为的返工和提交数矛盾 |

> D-01 如果产品方要求真正的 1080P 生成，先停下确认，不要自行改算例。对应数字见 §1 P0-02。

---

## 1. P0：必须修，否则会算错或跑不通

### P0-01 价格来源违反 `AGENTS.md` 硬约束

**位置**：计划 L292、L341、L421、L348  
**问题**：

- `buildRenderPlan` 默认 `priceYuanPerSecond = 0.42`，CLI 默认 `null → 0.42`，§6 #4 又把 0.42 写成“默认价格”。
- 计划明确写“不读 `pipeline_config.json`”，等于把价格硬编码在计划模块里。
- `AGENTS.md` §3 第 2/3 条要求：单价/计费口径只能来自 `pipeline_config.json` 与 `lib/pipeline/generation_models.dart`；新代码不得硬编码价格。`generation_models.dart` 已经有 `wan3.0-video` 的 `480P=0.21 / 720P=0.42 / 1080P=0.84`。

**要求**：

1. `buildRenderPlan` 的 `priceYuanPerSecond` 改为**必传参数**，不要给 `0.42` 默认值。
2. CLI 解析价格的优先级写成：`--price-per-second` > `generation_models.dart` 目录价（`findVideoModel('wan3.0-video')` + `unitPrice(..., '720P')`）。本 PR 不接 `pipeline_config.json` 的 `pricing.video` 覆盖可以接受，但要在计划里写明“这是本 PR 边界，下一 PR 接”，不能写成“价格默认写死”。如果顺手能读 config 的 `pricing.video` / `t2v.yuan_per_second` 作为覆盖更好；纯函数只接收 price，不在纯函数里做 IO。
3. 明确 i2v 使用哪个模型：计划按 `wan3.0-video` 720P 计价；如果沿用现有 `i2v.model = wan2.6-i2v-flash`，`generation_models.dart` 没有该模型价格，必须先补目录或从 config 取，不能继续假设 0.42。
4. 计划中的 0.42 只作为**算例期望值**出现，不作为代码默认值来源。
5. 增加一个测试：同一 storyboard 传入不同 price，`cost_yuan` / `estimated_yuan` 按比例变化。

**验收**：计划里不再出现“代码默认 0.42”的表述；`generation_models.dart` 被明确列为唯一默认价来源。

### P0-02 1080×1920 与 720P 单价对不上

**位置**：L47、L95、L107、L421  
**问题**：fixture 和默认 `frame` 是 `1080x1920`（1080P），但单价按 720P 的 0.42。`AGENTS.md` §9 明确提醒“默认 1080P 会抬价，i2v/t2v 要显式传 720P 才走低价档”。计划没有说明 i2v 的实际生成分辨率。

**要求**（按 D-01 推荐值）：

- 在 §1.2 / §6 #4 明确写：i2v 生成分辨率固定 720P（720×1280），`frame: 1080x1920` 是输出画布，渲染阶段负责放大。
- 这样 §4 的期望值 `13 秒 / 5.46 元 / 剩 14.54 / counts 6-1-5` 全部保持不变。
- 如果改选真正的 1080P 生成，必须同步改成：

| 场景 | 720P 生成（推荐） | 1080P 生成（若选） |
|---|---|---|
| 20 元 | cap 47，13 秒，5.46 元，剩 14.54 | cap 23，13 秒，10.92 元，剩 9.08 |
| 3 元 | cap 7，s07+s08=6 秒，2.52 元 | cap 3，仅 s07=3 秒，2.52 元 |
| 0.5 元 | cap 1，0 个 i2v | cap 0，0 个 i2v |
| max=4 | s07=3 秒，其余降级 | s07=3 秒，其余降级 |

**验收**：计划里能一眼看出“0.42 对应哪个分辨率”，并且算例与所选口径一致。

### P0-03 fixture 创建顺序反了

**位置**：L315、L357 vs L363  
**问题**：Task 3 的预算用例和 Task 4 的 CLI 用例都引用 `test/fixtures/ep07.storyboard.json`，但该文件在 Task 5 才创建。

**要求**：把 fixture 创建提前到 Task 1（数据契约任务），或把 Task 5 整体前移；Task 5 只保留 `test/fixtures/README.md` 和最终验收。确保任何引用 fixture 的测试执行时文件已存在。本轮只改计划里的 Task 顺序，不要实际创建 fixture。

**验收**：按 Task 顺序执行时，Task 1 结束后 `test/fixtures/ep07.storyboard.json` 已存在。

### P0-04 CLI 契约没定死

**位置**：L334–L346  
**问题**：

- 文中说“必须导出以下三个符号”，实际列了 4 个：`buildPlannerParser`、`PlannerArgs`、`parsePlannerArgs`、`runPlan`。
- 没有说明 `buildPlannerParser()` 是否使用 `addCommand('plan', ...)`。如果不加子命令，`parser.parse(['plan', ...])` 会报 unexpected argument，Task 4 的所有测试都跑不起来。
- 没有说明 `--storyboard` 是否 `mandatory`。如果设成 mandatory，缺参时 `parser.parse` 先抛 `FormatException`，`parsePlannerArgs` 返回 null 的测试写法不成立。
- 没有说明 `parsePlannerArgs` 从哪里取子命令（应为 `results.command`）、缺子命令时谁打印 usage。

**要求**：在 Interfaces 里补全并固定以下行为：

```dart
ArgParser buildPlannerParser();   // 顶层 -h/--help；addCommand('plan', ...)
PlannerArgs? parsePlannerArgs(ArgResults results, ArgParser parser);
Future<int> runPlan(PlannerArgs args, {String? outDir});
```

- `buildPlannerParser()` 必须 `addCommand('plan')`；`plan` 命令下注册 `storyboard`、`budget`、`price-per-second`、`max-i2v-seconds`、`out`。
- `--storyboard` **不要**设 `mandatory: true`，由 `parsePlannerArgs` 手动校验；缺失/空串时打印 usage 并返回 null。
- `parsePlannerArgs` 取 `results.command`；`command == null` 时打印 usage 并返回 null。
- 数值解析用 `double.tryParse` / `int.tryParse`，再做 `isFinite` 和范围校验；不合法返回 null。
- `main` 捕获 `FormatException`，未知子命令/无子命令 → usage + 64；`--help` → 0。

**验收**：Task 4 的“缺 `--storyboard` 返回 null”“`--budget 0` 返回 null”“`--price-per-second 0` 返回 null”三个测试都能按现有写法通过。

### P0-05 Task 4 断言类型错了

**位置**：L357  
**问题**：`buildRenderPlan(...).toJson()` 是 `Map<String, Object?>`，不能直接和文件字符串比较。

**要求**：改为比较编码后的字符串：

```dart
final expected = const JsonEncoder.withIndent('  ').convert(plan.toJson());
expect(file.readAsStringSync(), '$expected\n'); // 或明确文件不带结尾换行
```

同时明确 stdout 与文件内容是否都带结尾换行；建议统一为“pretty JSON + 一个结尾 `\n`”。

**验收**：测试断言的是字符串，而不是 `Map`。

### P0-06 `outDir` / `--out` 优先级没定

**位置**：L346、L350  
**问题**：`runPlan(args, {String? outDir})` 里的 `outDir` 是替换 `pipeline_out` 的基目录，还是最终目录？`--out` 和 `outDir` 谁优先？测试用临时目录，必须能确定文件落在哪里。

**要求**：明确写成：

- `args.outPath != null` → 原样使用 `args.outPath`（相对路径相对 CWD）。
- 否则 `base = outDir ?? 'pipeline_out'`，输出 `base/<content_id>/07_plan.json`。
- 自动递归创建父目录；创建或写盘失败 → 74。
- `outDir` 只影响默认路径，不覆盖显式 `--out`。

**验收**：新增一个测试：传 `outDir=temp`，断言文件在 `temp/<content_id>/07_plan.json`；传 `--out` 时断言在指定路径。

### P0-07 `resolveDuration` 没给签名/可见性

**位置**：L298  
**问题**：Task 2 要单测 `resolveDuration`，但 Interfaces 里没有它。如果实现成私有函数，测试无法调用。

**要求**：在 Interfaces 中明确：

```dart
double resolveDuration(Shot shot, List<String> warnings);
```

或者明确“只通过 `buildRenderPlan` 测，不直接测 `resolveDuration`”。二选一，不要留给执行者猜。

**验收**：Task 2 的测试代码能直接 import 并调用，或明确改为通过 `buildRenderPlan` 断言。

### P0-08 `git status` 验收条件与现状冲突

**位置**：L401  
**问题**：当前仓库已有 `.vscode/`、`AGENTS.md`、`docs/upstream/`、`prototype/`、计划文档等 untracked 项，`git status --short` 不可能“只出现新增文件”。执行者若照做会误以为有异常，甚至用 `git add -A` 把这些无关文件带进提交。

**要求**：

- 验收改为“只检查本次新增/修改的文件”，不要求全仓 `git status` 干净。
- 提交时显式列出文件，例如：

```bash
git add lib/pipeline/frame.dart lib/pipeline/storyboard.dart \
  lib/pipeline/render_plan.dart bin/short_drama.dart \
  test/pipeline/storyboard_test.dart test/pipeline/render_plan_test.dart \
  test/pipeline/planner_cli_test.dart test/fixtures/ep07.storyboard.json \
  test/fixtures/README.md
```

- **禁止** `git add -A` / `git add .`。
- `pipeline_out/` 已在 `.gitignore`，不会出现在 `git status`，删掉验收里的“若未被忽略”括号。

**验收**：`git status --short` 中本次提交只包含上述路径；无关 untracked 项保持原样。

---

## 2. P1：会写出与文档不一致的结果

### P1-01 `avoid_print` 与 `package:path`

**位置**：L349、L350、L410  
**问题**：

- `analysis_options.yaml` 启用了 `flutter_lints`，其中包含 `avoid_print`。CLI 若用 `print`，`dart analyze` 会报 info，DoD“零告警”不成立。
- `package:path` 不在 `pubspec.yaml`，§0 又要求不新增依赖；直接 import 会触发 `depend_on_referenced_packages` 或违反依赖约束。

**要求**：

- 用 `stdout.writeln` / `stderr.writeln`，照 `bin/conatus_host.dart` 的写法。
- 路径拼接只用 `dart:io` + 字符串（如 `'$base/${plan.contentId}/07_plan.json'`），不要引入 `package:path`。
- 验证命令改用仓库标准 `make analyze`，或保持 `dart analyze lib bin test` 但确认零 issue。

### P1-02 `duration_s` 0/负数/非有限值行为矛盾

**位置**：L90 vs L135–L142  
**问题**：表里写“必须 >0”，算法又把 `<0.8` 夹到 0.8；0、负数、NaN 到底抛错还是夹没有定义。

**要求**（按 D-02）：

- 解析阶段：`<= 0`、非有限值 → 输入错误（`PipelineError(ErrorClass.fatal, ...)` 或计划统一的异常）。
- 解析阶段允许 `0 < d < 0.8`，`resolveDuration` 夹到 0.8，并记 `duration_raised:<id>`。
- `d > 30` → 夹到 30，记 `duration_clamped:<id>`。
- 补测试：`0`、`-1`、`0.5`、`30.1`、`NaN`。

### P1-03 两个 warning 是死规格

**位置**：L188  
**问题**：`i2v_min_duration_raised:<id>` 和 `frame_not_vertical` 列在警告表里，但 §2.1/§2.4 没有任何地方产生它们。

**要求**（按 D-03）：

- `ceil(duration) < 2` → `i2v_min_duration_raised:<id>`。
- `ceil(duration) > 10` → `i2v_capped:<id>`。
- `!frame.isVertical` → `frame_not_vertical`。
- 补测试：0.8 秒的 action、15 秒的 action、1920×1080 的 frame。
- 如果决定不实现某个 warning，就把它从 §2.5 删除，不要留死规格。

### P1-04 Storyboard warnings 没并入 plan warnings

**位置**：L240、L285、L349  
**问题**：`Storyboard` 和 `RenderPlan` 各有一个 `warnings`，但没有规则说明 `buildRenderPlan` 是否复制解析期 warning。如果不复制，CLI 打印的 `plan.warnings` 会丢掉 `unknown_kind`、`speaker_not_in_cast` 等。

**要求**：

- 明确 `plan.warnings = dedupe([...storyboard.warnings, ...planWarnings])`，保持首次出现顺序。
- 用 `LinkedHashSet` 或等价结构去重。
- 补测试：一个未知 `kind` + 低预算的 storyboard，最终 `warnings` 同时包含 `unknown_kind` 和 `no_i2v_budget`，且顺序稳定。

### P1-05 Enum 序列化与优先级排序有坑

**位置**：L205–L206、L161  
**问题**：

- `ShotKind.speakOff.name` 是 `speakOff`，但 JSON 契约要 `speak_off`；`listenFace` 同理。直接用 `.name` 会让 `Storyboard.toJson` 的 roundtrip 失败。
- `ShotPriority` 的声明顺序是 `hook, turn, payoff, normal`，但 rank 是 `hook=0, payoff=1, turn=2, normal=3`。如果实现者用 `.index`，3 元预算会先给 `s04(turn)` 而不是 `s08(payoff)`。

**要求**：

- 增加显式 wire 映射：

```dart
String shotKindToWire(ShotKind kind);
ShotKind? shotKindFromWire(String raw);
int priorityRank(ShotPriority priority);
```

- `priorityRank` 用 switch，不要用 `.index`。
- 补测试：`priorityRank(payoff) < priorityRank(turn)`；3 元预算只给 `s07`、`s08`。
- `Storyboard.toJson` / `RenderPlan.toJson` 的 `kind` 必须是 `speak_off` 等 snake_case。

### P1-06 输出镜头集合/顺序/counts 键没定

**位置**：L109–L118  
**问题**：§1.2 示例只列了 3 个镜头，没有说明是节选；实现者可能只输出候选镜头。`counts` 也没有说零值是否保留。

**要求**：

- 写明“示例仅节选，实际按输入顺序输出全部镜头”。
- 补测试：`plan.shots.length == 12`，`shot_id` 顺序为 `s01..s12`。
- `counts` 固定三键 `kenburns`、`micro`、`i2v`，零值也输出；例如 0.5 元用例应为 `{kenburns:6, micro:6, i2v:0}`。

### P1-07 `toJson` 接口不完整

**位置**：L218–L241、L275–L287  
**问题**：

- `Storyboard.toJson` 需要 `Shot.toJson` 和 `CastMember.toJson`，但 Interfaces 只列了 `Storyboard.toJson`。
- `PlanTotals` 没有 `toJson`。
- `Storyboard.toJson` 的 `frame` 应该输出输入契约的字符串 `"1080x1920"`（roundtrip 需要），而 `RenderPlan.toJson` 输出 `{width, height}`；计划没有区分。

**要求**：

- 补 `Shot.toJson()`、`CastMember.toJson()`、`PlanTotals.toJson()`。
- 明确 `Storyboard.toJson` 的 `frame` 用 `FrameSize.label` 字符串，`RenderPlan.toJson` 的 `frame` 用对象。
- 明确 `Storyboard.toJson` 不输出 `warnings`（解析诊断不属于数据模型），或明确输出并说明 roundtrip 规则。
- 补 roundtrip 测试：`Storyboard.fromJsonString(input).toJson()` 与 `jsonDecode(input)` 深比较相等。

### P1-08 总时长求和会出 30.199999999999996

**位置**：L117、L300  
**问题**：逐镜 `ceil1` 都正确，但 12 个 double 相加是 `30.199999999999996`（已实测）。只对单镜做 `ceil1` 不够。

**要求**：

- 定义 `_round1` / `_round2` 返回 `double`，实现为 `(x * 10^n).round() / 10^n`，不要返回 `toStringAsFixed` 字符串。
- `totals.duration_s = _round1(sum(shot.durationS))`。
- 金额建议在构造时就 round：`PlannedShot.costYuan = _round2(i2vSeconds * price)`；`estimatedYuan = _round2(sum(costYuan))`；`remainingYuan = _round2(budget - estimatedYuan)`。
- 明确 `budget_yuan` / `price_yuan_per_second` 输出也做 `_round2`。
- 补测试：`totals.duration_s == 30.2`，且 `jsonEncode` 不出现长浮点串。

### P1-09 avatar 与 duration 的 trim 不一致

**位置**：L124 vs L140  
**问题**：avatar 用 `line.isNotEmpty`，duration 用 `line.trim().runes.length`；`"   "` 会得到 `avatar=true` 但时长 2.0。

**要求**：统一为 `line.trim().isNotEmpty`。

### P1-10 i2v 上限 10 秒 vs 镜头 30 秒语义没定

**位置**：L171、L420  
**问题**：30 秒的 action 只买 10 秒 i2v，剩下 20 秒怎么覆盖没有说明。

**要求**（按 D-03）：

- 明确 `i2v_seconds = clamp(ceil(duration), 2, 10)`。
- `ceil(duration) > 10` 记 `i2v_capped:<id>`，并写明“渲染阶段负责把 10 秒 i2v 扩展到镜头时长（循环/变速/补帧）”。
- 补测试：15 秒 action 的 `i2v_seconds == 10` 且 warning 存在。

### P1-11 NaN / Infinity / 负数 max 没校验

**位置**：L96、L253、L302  
**问题**：`double.tryParse('NaN')` 返回 NaN，`NaN <= 0` 是 false，会绕过校验；后续 `floor(NaN)` 直接抛 `UnsupportedError`。`maxI2vSeconds < 0` 会被 `if (maxI2vSeconds > 0)` 当成“不限”。

**要求**：

- 所有价格/预算/时长数值校验加 `isFinite`。
- `maxI2vSeconds` 要求 `>= 0`；负数在 CLI 返回 64。
- 补测试：`--budget NaN`、`--budget Infinity`、`--price-per-second NaN`、`--max-i2v-seconds -1` 均返回 64。

### P1-12 错误分类没跟仓库约定

**位置**：Task 1 的 `StoryboardException`  
**问题**：`AGENTS.md` §5 要求错误统一走 `PipelineError` + `ErrorClass`；计划新造了平行异常。

**要求**（按 D-04）：

- 用 `PipelineError(ErrorClass.fatal, '...')` 表示输入错误，CLI 映射为 65。
- `Storyboard.fromJsonString` 捕获 `FormatException` / 类型错误并包装，不能把 `TypeError` 直接漏给 CLI。
- `runPlan` 区分读失败（65）和写失败（74），用两个独立 try 块。
- 补测试：文件不存在 65、JSON 语法错误 65、非法 storyboard 65、输出路径是目录 74。

### P1-13 Task 2 / Task 3 边界不清

**位置**：L297–L319  
**问题**：Task 2 要求“五种 kind 各一镜，断言 route/avatar”，但 `action` 的最终 route 取决于 Task 3 的预算分配；Task 2 若先实现“action 永远 i2v”，Task 3 又要改行为。DoD 又写“每个 Task 一笔”，但只列了 4 笔提交。

**要求**（按 D-05）：

- 方案 A（推荐）：合并 Task 2 和 Task 3 为「渲染计划与预算分配」，一笔提交，测试覆盖默认路由 + 预算 + 降级。
- 方案 B：保留两个 Task，但 Task 2 只测 `speak_off` / `insert` / `establishing` / `listen_face(normal)` 的 route 和全部 avatar；`action` 的 i2v/降级只在 Task 3 测。
- 同步修正 §5 DoD 的提交拆分，确保 Task 数与提交数一致。

---

## 3. P2：文档与流程修正

- **P2-01**：L90 “见 §3.1” 改为 “见 §2.1”；§3.1 实际是 Task 1，不是时长算法。
- **P2-02**：删除或改写 L26、L33 的 WIP 描述；当前仓库没有未提交的源码 WIP，README 也是干净的。
- **P2-03**：L411 的提交拆分与 Task 数对齐；若按 D-05 合并 Task 2/3，则保留 4 笔；若保留 5 个 Task，就写 5 笔。
- **P2-04**：补 `writing-plans` 要求的 header：`REQUIRED SUB-SKILL`、`Spec`、`Global Constraints`、`Review Focus`；每个 Task 改成“写失败测试 → 跑失败 → 实现 → 跑通过 → 提交”的逐步格式，不要只给 bullet 清单。
- **P2-05**：L19 “先读 §0 与 §6” 改为 “先读 §0、§1、§2、§6”；否则执行者可能漏掉核心路由/预算算法。
- **P2-06**：L334 “三个符号” 改为“四个符号”，并给 `PlannerArgs` 的字段表。
- **P2-07**：L318 “截到 4 秒” 改为“上限 4 秒，实际 s07 用 3 秒，s08 因剩余 1 秒降级”。
- **P2-08**：Task 1 的 `storyboard_exception.dart` “或并入 storyboard.dart，二选一” 直接定一个；建议按 D-04 改用 `PipelineError`，不再新增异常文件。
- **P2-09**：Task 5 要求“把输出贴进 PR 描述”，但全文没有 PR 创建步骤；补 `gh pr create`（或明确由人工创建 PR，Task 5 只产出可直接粘贴的文本）。
- **P2-10**：`AGENTS.md` 说 `bin/` 是薄入口、逻辑放 `lib/pipeline/`；计划把 `PlannerArgs` / `parsePlannerArgs` / `runPlan` 都放在 `bin/short_drama.dart`。有 `bin/conatus_host.dart` 先例，但建议至少把纯计划逻辑留在 `lib/pipeline/`，`bin` 只保留 `main`、文件读写和打印。

---

## 4. 建议的修订顺序

1. 先落 D-01～D-05 到计划正文（特别是 §1.2、§2、§6）。
2. 修 P0-01～P0-08（价格、分辨率、fixture、CLI、断言、outDir、resolveDuration、git）。
3. 修 P1-01～P1-13（依赖/校验/warning/enum/输出/rounding/错误类型/任务边界）。
4. 补 P2 文档结构。
5. 按 §5 自检，回报“改了哪些行、哪些决策按推荐值、哪些仍需产品确认”。

---

## 5. 执行者自检清单

- [ ] 计划里不再把 `0.42` 写成代码默认值；默认价来源明确指向 `generation_models.dart`。
- [ ] 明确 i2v 生成分辨率，以及它与 `frame`/单价档的关系；算例与口径一致。
- [ ] `test/fixtures/ep07.storyboard.json` 在 Task 1 结束前已存在。
- [ ] `buildPlannerParser` / `parsePlannerArgs` / `runPlan` 的签名、子命令、null 行为、usage、退出码全部写死。
- [ ] Task 4 的文件断言比较的是 pretty JSON 字符串，不是 `Map`。
- [ ] `outDir` 与 `--out` 的优先级、默认路径、建目录行为明确。
- [ ] `resolveDuration` 的可见性与签名明确。
- [ ] 提交步骤只 `git add` 本次文件，禁止 `git add -A`；`pipeline_out/` 不提交。
- [ ] CLI 用 `stdout.writeln` / `stderr.writeln`，不用 `print`；不引入 `package:path`。
- [ ] `duration_s` 的 0/负数/NaN/<0.8/>30 行为全部有定义和测试。
- [ ] `i2v_min_duration_raised`、`i2v_capped`、`frame_not_vertical` 都有触发规则和测试，或已从 warning 表删除。
- [ ] `Storyboard.warnings` 已按稳定顺序并入 `RenderPlan.warnings`。
- [ ] `ShotKind` 的 JSON wire name 是 snake_case；`priorityRank` 不用 `.index`。
- [ ] 输出包含全部镜头且按输入顺序；`counts` 固定三键。
- [ ] `Shot.toJson`、`CastMember.toJson`、`PlanTotals.toJson` 已补；`Storyboard` 与 `RenderPlan` 的 `frame` 序列化形式已区分。
- [ ] `totals.duration_s` 加了 `_round1`，不会出现 `30.199999999999996`。
- [ ] `avatar` 使用 `line.trim().isNotEmpty`。
- [ ] 10 秒 i2v 上限与 30 秒镜头的补齐策略已写清。
- [ ] `NaN` / `Infinity` / 负数 max 有校验和 64 测试。
- [ ] 错误类型符合 `PipelineError` + `ErrorClass`，CLI 读写错误分别映射 65/74。
- [ ] Task 2/3 边界与 DoD 提交数一致。
- [ ] `writing-plans` 的 header / Global Constraints / Review Focus / TDD 步骤已补。
- [ ] 所有跨节引用（§2.1、§3.1 等）已核对。

---

## 6. 禁止事项

- 不要在本轮修改任何源码、测试或 fixture；本轮只改计划文档。
- 不要新增第三方依赖；不要引入 `package:path`。
- 不要为了让算例通过而改期望值；先定 D-01 的口径，再决定数字。
- 不要把“TBD / 二选一 / 自行决定”留在计划里；每一项都要给出唯一做法。
- 不要提交 `.vscode/`、`AGENTS.md`、`docs/upstream/`、`prototype/`、`pipeline_out/` 或其他无关 untracked 文件。
- 不要发真实网络请求，不要接百炼/conatus，不要跑 ffmpeg。

---

# 第二轮复审（计划修订后）

**复审对象**：`docs/superpowers/plans/2026-10-23-storyboard-render-plan.md`（2026-10-23 10:55 修订版）  
**复审日期**：2026-10-23  
**执行范围**：仍然只修订计划文档；`test/fixtures/ep07.storyboard.json` 已预置，不要改写；不要开始实现源码。

**复审结论**：第一轮的 P0/P1 大部分已落实，计划已接近可执行。当前只剩 **1 个会让 Task 1 直接变红的点**，以及 **3 个实现语义缺口**；P2 可以顺手处理。

## 已复核通过

- `test/fixtures/ep07.storyboard.json` 已存在，内容与 §1.1 一致。
- `Global Constraints` 的“9 个新增文件 + 1 个预置 fixture + 3 个修改文件”计数正确；`§4` 的 `git add` 列表覆盖这 13 个路径。
- 价格口径有据：`docs/万相视频生成与编辑成本核算_v1.0.md:49-50` 确认 `wan2.6-i2v-flash` 无声档 720P=0.15、1080P=0.25；`2–15` 秒与计划一致。
- 0.15 元/秒口径下的算例全部正确：
  - 20 元 → cap 133，13 秒，¥1.95，余 ¥18.05，counts `6/1/5`；
  - 1.5 元 → cap 10，`s07,s08,s12,s10`，¥1.50，余 ¥0.00，counts `6/2/4`；
  - 1 元 → cap 6，只给 `s07,s08`；
  - 0.2 元 → cap 1，0 个 i2v，counts `6/6/0`；
  - `maxI2vSeconds=4` → `s07` 3 秒，¥0.45，counts `6/5/1`。
  - `1.5 / 0.15 == 10.0` 是精确的，1.5 元边界用例稳定。
- 第一轮聊天里提出的“把 `wan2.6-i2v-flash` 加进 `kVideoModels` 与设计文档冲突”**撤回**。  
  `docs/superpowers/specs/2026-10-22-image-and-video-generation-split-design.md:62` 的“仅 CLI/管线”是对当时使用现状的描述，不是限制；后面的“通用文生视频页只暴露 wan3.0…”只说明它不属于 t2v 页。  
  因此：作为 i2v-only 模型加入 `kVideoModels`、同步修改 `video_api_test.dart` 的“双模式”断言，是允许的。设计文档可以顺手同步，但不是阻塞项。

## R2-P0：会让 Task 1 直接变红

### R2-P0-01 `generation_models_test.dart` 的 `isNull` 必须删除/改写

**位置**：`test/pipeline/generation_models_test.dart:33`；计划 Task 1 L290–L292。  
**问题**：当前测试仍有：

```dart
expect(findVideoModel('wan2.6-i2v-flash'), isNull);
```

计划的 Task 1 只写了“`kVideoModels` 期望 id 列表加上 `wan2.6-i2v-flash`、新增断言”，没有写删除这行。只要模型加进 `kVideoModels`，这个断言必然失败，Task 1 不可能转绿。

**要求**：在 Task 1 的 TDD 步骤里补一句明确指令：

- 删除 `expect(findVideoModel('wan2.6-i2v-flash'), isNull);`；
- 把测试名从 `video catalog exposes t2v and i2v for the wan3.0 family` 改成覆盖 wan3.0 + wan2.6 的名字；
- 新增 `findVideoModel('wan2.6-i2v-flash')!.modes == {VideoMode.i2v}` 等断言。

**验收**：`dart test test/pipeline/generation_models_test.dart` 在加入目录项后全绿；测试文件中不再有该 `isNull` 断言。

## R2-P1：实现语义缺口

### R2-P1-01 `i2v_generation` 没进 `RenderPlan` 接口和测试

**位置**：计划 §1.3 L142–L145 有输出字段；Task 3 的 `RenderPlan` 接口 L367 没有。  
**问题**：输出契约写了 `i2v_generation: {model, resolution, width, height}`，但 `RenderPlan` 的字段列表没有它，Task 3 的测试也没有断言它。实现者可能只把它写进 `toJson`，也可能完全漏掉。

**要求**：二选一写死：

- `RenderPlan` 增加 `i2vGeneration` 字段；或
- 明确 `RenderPlan.toJson` 固定从 `kPlanI2vModel / kPlanI2vResolution / kPlanI2vWidth / kPlanI2vHeight` 生成 `i2v_generation`。

**验收**：Task 3 增加测试，断言输出含 `model=wan2.6-i2v-flash`、`resolution=720P`、`width=720`、`height=1280`。

### R2-P1-02 `i2v_capped` / `i2v_min_duration_raised` 在预算判断之前发出

**位置**：计划 §2.4 L232–L238。  
**问题**：两条 warning 在 `if need <= remaining` 之前发出。一个 15 秒 action 如果因预算不足被降级成 `micro`，仍会带 `i2v_capped`；一个 0.8 秒 action 被降级，仍会带 `i2v_min_duration_raised`。warning 名是 i2v，实际 0 秒 i2v，下游会误读。

**要求**：二选一：

- 把两条 warning 移进 `if need <= remaining` 的 i2v 分支；或
- 改名成 `i2v_would_cap` / `i2v_would_raise`，并明确“即使降级也提示计划意图”。

**验收**：补一个“15 秒 action + 低预算”的用例，断言降级为 micro 时不会出现误导性的 `i2v_capped`（或按新语义断言）；预算充足时仍出现该 warning。

### R2-P1-03 `--price-per-second 0.42` 与 `i2v_generation.model = wan2.6` 不一致

**位置**：计划 D-06 L54。  
**问题**：允许用 `--price-per-second 0.42` 模拟 `wan3.0-video` 画质档，但输出仍写 `i2v_generation.model = wan2.6-i2v-flash`、`price_yuan_per_second = 0.42`。下游会以为 wan2.6 单价是 0.42。

**要求**：三选一：

- 禁止跨模型覆盖：`--price` 只允许覆盖同模型价格，并在计划里加 `price_override` warning；
- 输出增加 `price_source` / `price_model`，说明 0.42 是估算覆盖、不是 wan2.6 目录价；
- 本 PR 不提供 `--price` 覆盖，等渲染 PR 接模型切换。

**验收**：Task 4 增加一个 `--price-per-second 0.42` 用例，断言输出能区分“估算价格来源”和 `i2v_generation.model`，不会让读者误以为 wan2.6 目录价是 0.42。

## R2-P2：建议顺手处理

1. **`supportsAudio: false` 的语义**（计划 L284）。`docs/万相视频生成与编辑成本核算_v1.0.md:49-50` 同时有无声 0.15/0.25 和有声 0.3/0.5 两档。当前目录项只登记无声档；建议在 Task 1 注释里写明“本目录项仅无声档”，避免 UI/API 误以为模型完全没有有声能力。
2. **`remaining_yuan` 的负值保护**（计划 §2.4 L244）。现在只写了“不得为负”，算法只做 `round2`；建议 `remaining = max(0, round2(...))` 或加断言，并补一个极端价格/预算用例。
3. **`defaultI2vPriceYuanPerSecond()` 目录缺失时的行为**（计划 Review Focus L58、Task 4 L424/L449）。建议明确 `findVideoModel('wan2.6-i2v-flash') ?? (throw StateError('catalog missing ...'))`，不要静默回退；测试同时断言目录项存在。
4. **`video_api_test.dart` 保留 `wan3.0-video-prime` 的双模式覆盖**（计划 L294）。改成“每个模型至少一个模式 + 分别断言”时，别只断言 `wan3.0-video` 和 `wan2.6`，prime 也应保留 `t2v+i2v`。
5. **`Global Constraints` 的错误类型表述**（计划 L40 vs L260）。L40 说“输入错误统一抛 `PipelineError`”，L260 说纯函数参数错误抛 `ArgumentError`。建议改成：Storyboard 解析/IO 输入错误 → `PipelineError.fatal`；`buildRenderPlan` 参数错误 → `ArgumentError`；CLI 分别映射 65/64。
6. **设计文档可选同步**（`2026-10-22-image-and-video-generation-split-design.md:62`）。不是限制，也不阻塞；如果顺手改，可写成“既有 CLI/管线，本期起计划单/图生视频页复用”。若改，`Global Constraints` 的“修改 3 个既有文件”要变成 4 个。
7. **CLI 边角测试可选补**：`--help` → 0、未知子命令 → 64、warnings 确实写 stderr、默认 `outDir` 路径。不是阻塞项。

## 第二轮修订顺序

1. 先改 R2-P0-01（否则 Task 1 直接红）。
2. 再改 R2-P1-01～R2-P1-03（输出契约、warning 顺序、价格覆盖语义）。
3. 顺手处理 R2-P2-01～R2-P2-05。
4. 设计文档同步（R2-P2-06）可选；若做，更新文件计数。
5. 跑一遍 §4 的全部命令，确认 Task 1 的 `generation_models_test.dart` 与 `video_api_test.dart` 都能转绿。

## 第二轮验收命令

```bash
make analyze
dart test test/pipeline/generation_models_test.dart
dart test test/server/video_api_test.dart
dart test test/pipeline/storyboard_test.dart test/pipeline/render_plan_test.dart test/pipeline/planner_cli_test.dart
dart test test/pipeline
```

期望：全部通过；`generation_models_test.dart` 不再有 `findVideoModel('wan2.6-i2v-flash'), isNull`；`dart run bin/short_drama.dart plan ... --budget 20` 仍输出 `13 秒 / ¥1.95 / 余 ¥18.05 / counts 6-1-5`。
