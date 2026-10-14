# 视频编辑成本预估器 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 app 顶部新增「视频编辑成本」模式，横向对比三个编辑模型的预估费用与计费口径（纯计算，不调百炼、不碰 mp4）。

**Architecture:** 编辑模型目录（价格/限制/计费模式/输出规则）以纯 Dart 常量集中在 `lib/pipeline/edit_models.dart`，经只读 `GET /api/edit-models` 下发；前端拉一次后用纯函数 `editCost.ts` 计算 `计费秒数 × 单价` 并渲染对比表。

**Tech Stack:** Dart 3.12（纯 Dart：`lib/pipeline/**`、`lib/server/**`）、`package:test`、React 19 + TypeScript + Vite 8、Vitest（前端纯函数单测）、oxlint。

**Spec:** `docs/superpowers/specs/2026-10-14-video-edit-cost-estimator-design.md`

## Global Constraints

- `lib/pipeline/**`、`lib/server/**` 禁止 `import 'package:flutter/...'`（纯 Dart，可整体搬后端）。
- 单价/限制/计费模式必须与 spec §3 表、`docs/万相视频生成与编辑成本核算_v1.0.md` 逐字一致：wan2.7-videoedit 720P 0.6 / 1080P 1.0（输入+输出，输入 2–10s，输出=输入，免费 50s）；happyhorse-1.0-video-edit 720P 0.9 / 1080P 1.6（输入+输出，输入 3–60s，输出 min(输入,15)，免费 10s）；wanx2.1-vace-plus 720P 0.70（**仅输出**，输入 0–5s，输出固定 5，免费 50s）。
- 前端只经 HTTP 与 server 交互；单价/限制不得硬编码在前端（来自 `/api/edit-models`）。
- 计费公式只实现一次（前端 `editCost.ts`），Dart 侧不重复实现。
- 前端类型用字符串联合（`erasableSyntaxOnly` 禁止 enum）；type-only import 用 `import type`（`verbatimModuleSyntax`）。
- 不改动现有「方言配音主讲人」模式的任何行为。
- 收尾基线：`dart analyze lib bin test` 零告警、`flutter test` 全绿、`cd frontend && npm run lint && npm run test && npm run build`。

## Review Focus

spec 未明说、但最可能伤到用户的输入/条件（每行在所属任务里配了验证）：

1. **素材时长落在模型区间端点**（如 wan2.7 的 2s / 10s）——应判**可用**（区间含端点）。（Task 3 `isApplicable`）
2. **时长超模型上限**（如 wan2.7 11s）——该模型必须**不可用**，不能仍显示一个看似正常的费用。（Task 3 `estimateCost` 返回 undefined；Task 4 标灰）
3. **VACE 没有 1080P 档**——切到 1080P 时它必须显示「不支持」，不能显示 0 或 NaN。（Task 3 `resolutionPrice` undefined；Task 4 文案）
4. **happyhorse 超 15s 截断**——计费秒数按**截断后**的输出算，不能按输入算输出。（Task 3 `outputSeconds`/`billedSeconds`）
5. **`/api/edit-models` 拉取失败**——页面显示中文错误且不崩溃，主讲人模式不受影响。（Task 4；组件层，无前端 DOM 测试环境，靠 build + 手动验证）

---

### Task 1: 编辑模型目录（纯 Dart）

**Files:**
- Create: `lib/pipeline/edit_models.dart`
- Test: `test/pipeline/edit_models_test.dart`

**Interfaces:**
- Produces（`package:flutter_wanxiang/pipeline/edit_models.dart`）：
  - `enum EditBilling { inputOutput, outputOnly }`
  - `enum EditOutputMode { sameAsInput, fixed, min }`
  - `class EditResolution { const EditResolution({required String label, required double yuanPerSecond}); final String label; final double yuanPerSecond; Map<String, Object?> toJson(); }`
  - `class EditModel { const EditModel({required String id, required String name, required EditBilling billing, required int inputMinS, required int inputMaxS, required EditOutputMode outputMode, int? outputValue, required List<EditResolution> resolutions, required int freeQuotaS, required String note}); ... Map<String, Object?> toJson(); }`
  - `const List<EditModel> kEditModels`
  - `toJson()` 线格式：`{id, name, billing: 'input_output'|'output', input_min_s, input_max_s, output: {mode: 'same_as_input'|'fixed'|'min', value?}, resolutions: [{label, yuan_per_second}], free_quota_s, note}`

- [ ] **Step 1: 写失败测试** `test/pipeline/edit_models_test.dart`

```dart
import 'package:flutter_wanxiang/pipeline/edit_models.dart';
import 'package:test/test.dart';

void main() {
  test('catalog lists the three edit models with spec prices', () {
    expect(kEditModels.map((m) => m.id).toList(), [
      'wan2.7-videoedit',
      'happyhorse-1.0-video-edit',
      'wanx2.1-vace-plus',
    ]);

    final wan = kEditModels[0];
    expect(wan.billing, EditBilling.inputOutput);
    expect([wan.inputMinS, wan.inputMaxS], [2, 10]);
    expect(wan.outputMode, EditOutputMode.sameAsInput);
    expect(wan.freeQuotaS, 50);
    expect(wan.resolutions.map((r) => r.yuanPerSecond).toList(), [0.6, 1.0]);

    final hh = kEditModels[1];
    expect(hh.billing, EditBilling.inputOutput);
    expect([hh.inputMinS, hh.inputMaxS], [3, 60]);
    expect(hh.outputMode, EditOutputMode.min);
    expect(hh.outputValue, 15);
    expect(hh.resolutions.map((r) => r.yuanPerSecond).toList(), [0.9, 1.6]);

    final vace = kEditModels[2];
    expect(vace.billing, EditBilling.outputOnly);
    expect([vace.inputMinS, vace.inputMaxS], [0, 5]);
    expect(vace.outputMode, EditOutputMode.fixed);
    expect(vace.outputValue, 5);
    expect(vace.resolutions.map((r) => r.label).toList(), ['720P']);
    expect(vace.resolutions.single.yuanPerSecond, 0.70);
  });

  test('toJson emits the wire shape the frontend reads', () {
    final wan = kEditModels[0].toJson();
    expect(wan['billing'], 'input_output');
    expect(wan['input_min_s'], 2);
    expect((wan['output'] as Map)['mode'], 'same_as_input');
    expect((wan['output'] as Map).containsKey('value'), isFalse);
    expect((wan['resolutions'] as List).first,
        {'label': '720P', 'yuan_per_second': 0.6});

    expect(kEditModels[2].toJson()['billing'], 'output');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/pipeline/edit_models_test.dart`
Expected: FAIL —— `edit_models.dart` 不存在 / `kEditModels` 未定义。

- [ ] **Step 3: 实现 `lib/pipeline/edit_models.dart`**

按上列 Interfaces 定义枚举、`EditResolution`、`EditModel`（含 `toJson()`），并写 `const kEditModels` 三条，数值严格取 Global Constraints。`toJson()` 的 `output` 仅在 `outputValue != null` 时写入 `value`。`billing` 序列化为 `'input_output'` / `'output'`。

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/pipeline/edit_models_test.dart`
Expected: PASS（2 tests）。

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/edit_models.dart test/pipeline/edit_models_test.dart
git commit -m "feat(video-edit): add edit-model price catalog (pure Dart)"
```

---

### Task 2: `GET /api/edit-models` 路由与处理器

**Files:**
- Modify: `lib/server/api_router.dart`
- Modify: `lib/server/pipeline_server.dart:162-177`（`_handleApi` switch）
- Test: `test/server/api_router_test.dart`、`test/server/pipeline_server_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `kEditModels` 及 `EditModel.toJson()`。
- Produces: `ApiRoute.getEditModels`；`GET /api/edit-models` → `200 {"edit_models": [<EditModel.toJson()>, ...]}`。

- [ ] **Step 1: 写失败测试**（追加到 `test/server/api_router_test.dart` 的第一个 test 内）

```dart
      expect(apiRouteFor('GET', '/api/edit-models'), ApiRoute.getEditModels);
```
（追加到第二个 test 内）
```dart
      expect(apiRouteFor('POST', '/api/edit-models'), ApiRoute.unknown);
```

- [ ] **Step 2: 跑测试确认失败**

Run: `flutter test test/server/api_router_test.dart`
Expected: FAIL —— `ApiRoute.getEditModels` 未定义。

- [ ] **Step 3: 实现路由**

在 `api_router.dart` 的 `enum ApiRoute` 增 `getEditModels,`；在 `apiRouteFor` 顶部（`/api/dialects` 分支旁）加：
```dart
  if (path == '/api/edit-models' && method == 'GET') {
    return ApiRoute.getEditModels;
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `flutter test test/server/api_router_test.dart`
Expected: PASS。

- [ ] **Step 5: 写失败测试**（追加到 `test/server/pipeline_server_test.dart`）

```dart
  test('edit-models payload lists the three edit models', () async {
    final res = await _get(server.boundPort!, '/api/edit-models');
    expect(res.status, 200);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final models = (data['edit_models'] as List).cast<Map<String, dynamic>>();
    expect(models.map((m) => m['id']).toList(), [
      'wan2.7-videoedit',
      'happyhorse-1.0-video-edit',
      'wanx2.1-vace-plus',
    ]);
    expect(models[0]['billing'], 'input_output');
  });
```

- [ ] **Step 6: 跑测试确认失败**

Run: `flutter test test/server/pipeline_server_test.dart`
Expected: FAIL —— `/api/edit-models` 返回 404（路由已加、处理器未加）。

- [ ] **Step 7: 实现处理器**

在 `pipeline_server.dart` 的 `_handleApi` switch 增 `case ApiRoute.getEditModels: await _getEditModels(req);`；导入 `package:flutter_wanxiang/pipeline/edit_models.dart`；新增：
```dart
  Future<void> _getEditModels(HttpRequest req) async {
    _sendJson(req, HttpStatus.ok, <String, dynamic>{
      'edit_models': [for (final m in kEditModels) m.toJson()],
    });
  }
```

- [ ] **Step 8: 跑测试确认通过**

Run: `flutter test test/server/api_router_test.dart test/server/pipeline_server_test.dart`
Expected: PASS。

- [ ] **Step 9: Commit**

```bash
git add lib/server/api_router.dart lib/server/pipeline_server.dart test/server/api_router_test.dart test/server/pipeline_server_test.dart
git commit -m "feat(video-edit): serve /api/edit-models catalog"
```

---

### Task 3: 前端纯函数 `editCost.ts` + Vitest 装置

**Files:**
- Create: `frontend/src/editCost.ts`
- Test: `frontend/src/editCost.test.ts`
- Modify: `frontend/package.json`（加 devDependency `vitest` 与 `"test": "vitest run"`）

**Interfaces:**
- Produces（`frontend/src/editCost.ts`，全部 named export）：
  - `type EditBilling = 'input_output' | 'output'`；`type EditOutputMode = 'same_as_input' | 'fixed' | 'min'`
  - `interface EditResolution { label: string; yuan_per_second: number }`
  - `interface EditOutput { mode: EditOutputMode; value?: number }`
  - `interface EditModel { id: string; name: string; billing: EditBilling; input_min_s: number; input_max_s: number; output: EditOutput; resolutions: EditResolution[]; free_quota_s: number; note: string }`
  - `outputSeconds(m: EditModel, inputS: number): number`
  - `billedSeconds(m: EditModel, inputS: number): number`
  - `isApplicable(m: EditModel, inputS: number): boolean`（区间**含端点**）
  - `resolutionPrice(m: EditModel, label: string): number | undefined`
  - `estimateCost(m: EditModel, inputS: number, label: string): number | undefined`（不可用或无该分辨率 → `undefined`）

- [ ] **Step 1: 装 Vitest 并加脚本**

Run: `cd frontend && npm i -D vitest`
然后手工在 `package.json` 的 `scripts` 加 `"test": "vitest run"`。（若 `npm i` 报 Vite 8 peer 冲突，安装与 Vite 8 兼容的 vitest 版本，如 `vitest@^4`。）

- [ ] **Step 2: 写失败测试** `frontend/src/editCost.test.ts`

```ts
import { describe, expect, it } from 'vitest'
import {
  billedSeconds,
  estimateCost,
  isApplicable,
  outputSeconds,
  resolutionPrice,
  type EditModel,
} from './editCost'

const wan: EditModel = {
  id: 'wan2.7-videoedit', name: '万相2.7-视频编辑', billing: 'input_output',
  input_min_s: 2, input_max_s: 10, output: { mode: 'same_as_input' },
  resolutions: [{ label: '720P', yuan_per_second: 0.6 }, { label: '1080P', yuan_per_second: 1.0 }],
  free_quota_s: 50, note: '',
}
const hh: EditModel = {
  id: 'happyhorse-1.0-video-edit', name: 'HappyHorse', billing: 'input_output',
  input_min_s: 3, input_max_s: 60, output: { mode: 'min', value: 15 },
  resolutions: [{ label: '720P', yuan_per_second: 0.9 }, { label: '1080P', yuan_per_second: 1.6 }],
  free_quota_s: 10, note: '',
}
const vace: EditModel = {
  id: 'wanx2.1-vace-plus', name: 'VACE', billing: 'output',
  input_min_s: 0, input_max_s: 5, output: { mode: 'fixed', value: 5 },
  resolutions: [{ label: '720P', yuan_per_second: 0.7 }],
  free_quota_s: 50, note: '',
}

describe('outputSeconds', () => {
  it('same_as_input mirrors the input', () => expect(outputSeconds(wan, 8)).toBe(8))
  it('min caps at the value', () => expect(outputSeconds(hh, 60)).toBe(15))
  it('min keeps small inputs', () => expect(outputSeconds(hh, 3)).toBe(3))
  it('fixed ignores the input', () => expect(outputSeconds(vace, 4)).toBe(5))
})

describe('billedSeconds', () => {
  it('input+output doubles', () => expect(billedSeconds(wan, 5)).toBe(10))
  it('output-only ignores input', () => expect(billedSeconds(vace, 4)).toBe(5))
  it('happyhorse truncates output before adding', () => expect(billedSeconds(hh, 60)).toBe(75))
})

describe('isApplicable is inclusive', () => {
  it('wan at min/max', () => {
    expect(isApplicable(wan, 2)).toBe(true)
    expect(isApplicable(wan, 10)).toBe(true)
    expect(isApplicable(wan, 1)).toBe(false)
    expect(isApplicable(wan, 11)).toBe(false)
  })
  it('vace at 0 and 5', () => {
    expect(isApplicable(vace, 0)).toBe(true)
    expect(isApplicable(vace, 5)).toBe(true)
    expect(isApplicable(vace, 6)).toBe(false)
  })
})

describe('resolutionPrice', () => {
  it('reads by label', () => expect(resolutionPrice(wan, '1080P')).toBe(1.0))
  it('vace has no 1080P', () => expect(resolutionPrice(vace, '1080P')).toBeUndefined())
})

describe('estimateCost', () => {
  it('wan 5s @720P', () => expect(estimateCost(wan, 5, '720P')).toBeCloseTo(6.0))
  it('vace 4s @720P (output only)', () => expect(estimateCost(vace, 4, '720P')).toBeCloseTo(3.5))
  it('out-of-range duration → undefined', () =>
    expect(estimateCost(wan, 11, '720P')).toBeUndefined())
  it('missing resolution → undefined', () =>
    expect(estimateCost(vace, 4, '1080P')).toBeUndefined())
})
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd frontend && npm run test`
Expected: FAIL —— 找不到 `./editCost`。

- [ ] **Step 4: 实现 `frontend/src/editCost.ts`**

按 Interfaces 定义类型与函数。`estimateCost` = 先 `isApplicable`（否则 undefined），再 `resolutionPrice`（否则 undefined），返回 `billedSeconds(m, inputS) * price`。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd frontend && npm run test`
Expected: PASS（全部用例）。

- [ ] **Step 6: Commit**

```bash
git add frontend/package.json frontend/package-lock.json frontend/src/editCost.ts frontend/src/editCost.test.ts
git commit -m "feat(video-edit): pure cost function + vitest tests"
```

---

### Task 4: 模式切换 + `EditCostEstimator` UI + 重建 web_build

**Files:**
- Create: `frontend/src/EditCostEstimator.tsx`
- Modify: `frontend/src/App.tsx`、`frontend/src/App.css`
- Modify: `README.md`（成本预估节加一句索引）
- Rebuild: `web_build/`

**Interfaces:**
- Consumes: Task 3 的 `estimateCost` / `isApplicable` / `resolutionPrice` / `billedSeconds` 与 `type EditModel`；Task 2 的 `GET /api/edit-models`。

- [ ] **Step 1: 实现 `EditCostEstimator.tsx`**

组件签名 `export default function EditCostEstimator()`。状态：`models: EditModel[] | null`、`error: string`、`inputS = 5`、`resolution: '720P' | '1080P' = '720P'`。`useEffect` 拉一次 `/api/edit-models` → `setModels(d.edit_models)`；失败 `setError('加载编辑模型定价失败，请重试')` 并渲染错误 + 「重试」按钮（重新 fetch），不影响其它模式。

控件：素材时长 `range`（min 1 / max 60 / step 1）、分辨率 `select`（720P / 1080P）。

对比表（`models.map`，每模型一行）：列 = 模型名 / 计费口径（`billing === 'output' ? '仅输出' : '输入+输出'`）/ 计费秒数（`billedSeconds(m, inputS)`）/ 预估费用 / 免费额度。
- `!isApplicable(m, inputS)` → 整行加 `unavailable` 类，费用列显示「该模型输入需 {input_min_s}–{input_max_s}s」。
- `resolutionPrice(m, resolution) === undefined` → 费用列显示「不支持」。
- 否则费用 = `estimateCost(m, inputS, resolution)`，渲染 `¥{cost.toFixed(2)}`。

底部注：「以实际账单为准。单价与计费口径见 docs/万相视频生成与编辑成本核算_v1.0.md」。

- [ ] **Step 2: 接入 `App.tsx`**

加 `const [mode, setMode] = useState<'speaker' | 'edit-cost'>('speaker')`；在 `<header>` 之后渲染两个 tab 按钮（「方言配音主讲人」/「视频编辑成本」）；用 `mode === 'speaker' ? (现有内容) : <EditCostEstimator />` 切换。现有 form/result/preview 结构与逻辑**不动**。

- [ ] **Step 3: 加样式到 `App.css`**

`.mode-tabs` / `.mode-tabs .tab` / `.tab.active`，以及对比表 `.edit-table`（含 `th/td`、`.unavailable` 灰化）。复用现有色板（`#0071e3` 主色、`#6e6e73` 次要文字）。

- [ ] **Step 4: README 索引**

在 README「成本预估」节末尾加一句：`> 页面顶部「视频编辑成本」模式可横向对比三个编辑模型的预估费用。`（保持该节既有风格）。

- [ ] **Step 5: Lint + 测试 + 构建（重建 web_build）**

Run: `cd frontend && npm run lint && npm run test && npm run build`
Expected: oxlint 无错误；vitest 全绿；`tsc -b && vite build` 成功、产物写入 `../web_build/`（`web_build/index.html` 与 `assets/index-*.js`、`assets/index-*.css` 更新）。

- [ ] **Step 6: 手动验证（Review Focus 第 5 条）**

`/api/*` 由 Dart server 提供（`npm run dev` 的 Vite 不带代理），所以用构建产物验证：先跑完 Step 5 的 `npm run build`，再启动 app（`flutter run -d macos`）或由内嵌 server 托管 `web_build/` 打开。在「视频编辑成本」模式：拖到 2s/10s 看 wan2.7 仍可用；拖到 11s 看它标灰；切 1080P 看 VACE 显示「不支持」；把服务停掉看错误提示与「重试」。确认主讲人模式不受影响。

- [ ] **Step 7: 全量基线**

Run: `dart analyze lib bin test && flutter test`
Expected: 零告警、全绿。

- [ ] **Step 8: Commit**

```bash
git add frontend/src/EditCostEstimator.tsx frontend/src/App.tsx frontend/src/App.css web_build README.md
git commit -m "feat(video-edit): cost estimator mode in the web UI"
```
