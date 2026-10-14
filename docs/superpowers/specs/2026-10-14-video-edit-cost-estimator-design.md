# 视频编辑成本预估器（前端模式）设计文档

> 状态：待评审 · 日期：2026-10-14
> 前置：`docs/万相视频生成与编辑成本核算_v1.0.md`（单价与计费口径）
> 关联：`docs/视频局部修改可行性方案_v1.0.md`（编辑模型选型）
> 范围：**只做成本预估**，不调用百炼、不碰 mp4；真实编辑链（上传→提交→下载）后置。

## 1. 背景与目标

现有 app（`lib/main.dart` + `lib/server/` + `frontend/`）只有「方言配音主讲人」一个模式，其费用预估由 `t2v.yuan_per_second` 驱动。可行性方案已确认「视频局部修改」会用到多个编辑模型，且它们的计费口径**不一致**：

- `wan2.7-videoedit` / `happyhorse-1.0-video-edit`：**输入 + 输出都计费**（≈2× 素材时长）。
- `wanx2.1-vace-plus`：**仅输出计费**，且输入 ≤5s、输出固定 5s、仅 720P。

目标：在 app 顶部加「视频编辑成本」模式，输入素材时长 + 分辨率，**横向对比三个编辑模型**的预估费用与计费口径，帮助选型。

**本期做**：三模型成本对比预估器（纯展示/计算）。
**本期不做**：上传 mp4、调用编辑接口、轮询、预览下载、mask 画板、换人。

## 2. 总体结构

沿用现有壳与分层：`lib/main.dart`（Flutter 壳）→ 本地 `lib/server/` Dart server → WebView 载 React。

```
React「视频编辑成本」模式 ──GET /api/edit-models──▶ Dart server
   素材时长滑杆 + 分辨率              返回：模型目录（价格/限制/计费模式/输出规则）
        │
        └─ 前端通用解释器：按规则算 计费秒数 × 单价 ──▶ 对比表（本地即时，无网络往返）
```

### 分层与边界
- `lib/pipeline/edit_models.dart` 纯 Dart（不 import flutter），可整体搬后端：**只持有并暴露目录数据**。
- `lib/server/**` 纯 Dart，新增一条只读路由。
- `frontend/**` 只经 HTTP 与 server 交互。
- **计费公式不在 Dart 侧实现**：目录已把「计费模式 + 输出规则」数据化，前端用一段**通用解释器**（非按模型分支）计算，避免逻辑双写。Dart 侧只测目录数据的正确性。

## 3. 计费模型数据（华北2 北京，元/秒）

| 模型 ID | 计费模式 | 输入时长 | 输出规则 | 720P | 1080P | 免费额度 |
|---|---|---|---|---|---|---|
| `wan2.7-videoedit` | `input_output` | 2–10s | `same_as_input` | 0.6 | 1.0 | 50s |
| `happyhorse-1.0-video-edit` | `input_output` | 3–60s | `min`（上限 15） | 0.9 | 1.6 | 10s |
| `wanx2.1-vace-plus` | `output` | ≤5s | `fixed`（5） | 0.70 | —（无） | 50s |

> `wanx2.1-vace-plus` 即可行性方案里的 `wan2.1-vace-plus`（官方 model id 带 `x`）。

## 4. Server API（`lib/server/`）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/edit-models` | 返回编辑模型目录（下方结构）；只读，无副作用 |

```jsonc
{
  "edit_models": [
    {
      "id": "wan2.7-videoedit",
      "name": "万相2.7-视频编辑",
      "billing": "input_output",              // "input_output" | "output"
      "input_min_s": 2,
      "input_max_s": 10,
      "output": { "mode": "same_as_input" },  // {"mode":"same_as_input"} | {"mode":"fixed","value":5} | {"mode":"min","value":15}
      "resolutions": [
        { "label": "720P", "yuan_per_second": 0.6 },
        { "label": "1080P", "yuan_per_second": 1.0 }
      ],
      "free_quota_s": 50,
      "note": "指令编辑 + 视频迁移；输入和输出都计费"
    }
    // happyhorse-1.0-video-edit、wanx2.1-vace-plus 同构
  ]
}
```

- 路由：`ApiRoute` 增 `getEditModels`；`apiRouteFor('GET', '/api/edit-models')` 返回之（`api_router.dart`）。
- `PipelineServer` 增 `_getEditModels` 处理器，序列化 `lib/pipeline/edit_models.dart` 的目录常量。
- 目录为静态常量，无需配置注入。

## 5. 前端 UI（`frontend/src/`）

- `App.tsx` 顶部加**模式切换**：「方言配音主讲人」/「视频编辑成本」（`useState<'speaker' | 'edit-cost'>`）。两模式各自渲染；主讲人模式现有逻辑不动。
- 新增组件 `frontend/src/EditCostEstimator.tsx`：
  - 拉一次 `GET /api/edit-models`（`useEffect`）；失败显示错误、可重试。
  - 控件：**素材时长滑杆**（1–60s，默认 5）、**分辨率选择**（720P/1080P）。
  - 计算（通用解释器）：
    - `outputSeconds = rule(input)`：`same_as_input → input`；`fixed → value`；`min → min(input, value)`。
    - `billedSeconds = billing === 'output' ? outputSeconds : input + outputSeconds`。
    - `cost = billedSeconds × 该模型该分辨率的单价`。
  - 渲染对比表：每个模型一行，列 = 模型名 / 计费口径 / 计费秒数 / 720P 费用 / 1080P 费用 / 免费额度。
  - **适用性**：素材时长超出 `[input_min_s, input_max_s]` → 该行标灰并提示不可用；无对应分辨率 → 显示「—」。
  - 口径说明：区分「输入+输出双计」与「仅输出」；底部注明「以实际账单为准」。
- 样式：复用现有 `.form/.field/.value` 等类，必要处加少量 `.mode-tabs` / 表格样式到 `App.css`。

## 6. 计费函数 / 规则

- 规则全部数据化在目录里（`billing` + `output.mode`），前端解释器不按模型名分支。
- 与评分文档口径一致：`计费时长 = 输入 + 输出`（双计）或 `= 输出`（仅输出）；失败不计费、免费额度仅北京。

## 7. 错误与边界

- `/api/edit-models` 拉取失败 → 组件显示中文错误 + 重试按钮，不影响主讲人模式。
- 素材时长超模型上限：标灰 + 文案（如「该模型输入需 2–10s」）。
- `wanx2.1-vace-plus` 无 1080P 档：1080P 列显示「—」。

## 8. 测试

- Dart：
  - `test/pipeline/edit_models_test.dart`：目录条目齐全、价格与 `docs/万相视频生成与编辑成本核算_v1.0.md` 一致、计费模式/输出规则/时长上下限正确。
  - `test/server/api_router_test.dart`：`GET /api/edit-models` 映射。
  - `test/server/pipeline_server_test.dart`：`/api/edit-models` 返回形状（`edit_models` 非空、含三模型 id）。
- 前端：`npm run lint`（oxlint）+ `npm run build`（`tsc -b && vite build`），重建 `web_build/`。
- 全量：`dart analyze lib bin test` 零告警、`flutter test` 全绿。

## 9. 影响文件

- 新增：`lib/pipeline/edit_models.dart`、`frontend/src/EditCostEstimator.tsx`、`test/pipeline/edit_models_test.dart`。
- 修改：`lib/server/api_router.dart`、`lib/server/pipeline_server.dart`、`frontend/src/App.tsx`、`frontend/src/App.css`、`test/server/api_router_test.dart`、`test/server/pipeline_server_test.dart`。
- 重建：`web_build/`。
- 文档：`README.md`（可选：在成本预估节加一句索引到本模式）。

## 10. 待确认假设

1. 预估器**不调用百炼、不碰 mp4**（已确认）。
2. 覆盖三个编辑模型、横向对比（已确认）。
3. 单输入「素材时长」+ 分辨率，输出时长按目录规则推导（已确认）。
4. 顶部模式切换（已确认）。
5. 计费公式放前端通用解释器、Dart 只持有并测目录数据（相对评审设计的小调整：不写重复的 Dart 计费函数，避免逻辑双写）。
