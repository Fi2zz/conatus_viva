# P1 验收记录（短剧工作台骨架 + 创作闭环）

日期：2026-10-26
基线提交：`372469c`
验收范围：`docs/superpowers/plans/2026-10-23-drama-workbench-p1.md` 的 9 条验收清单。

## 命令结果

| 命令 | 结果 |
|---|---|
| `make analyze` | No issues found |
| `make test-dart` | 340 tests passed |
| `make test-web` | vitest / oxlint / check:dialogs 全部通过 |
| `cd frontend && npm run build` | 56 modules transformed，构建成功 |
| `make web` | `web_build/` 无 diff（已与源码一致） |

## 逐项证据

1. **新建剧/集、保存故事、拆片、生成分镜、编辑、保存、计划单重算**
   - `test/server/drama_api_test.dart`：`create series -> create episode -> bundle has 8 steps`、`save storyboard returns a deterministic plan`、`chinese line survives save and read`。
   - `test/pipeline/drama/llm_test.dart`：`extract parses beats, cast and source hash without writing`、`draft retries once and injects content_id/cast/id defaults`。
2. **未接入工序显示「未接入」，`run` 返回 501**
   - `test/server/drama_api_test.dart`：`unwired step run is 501`。
   - `frontend/src/shortDrama/view.test.ts`：`stepStatusLabel prioritizes unwired`。
3. **无剧/无集/无分镜空态不白屏**
   - `frontend/src/ShortDrama.tsx` 的三个空态分支（无剧、无集、加载/错误）均有显式渲染。
   - `frontend/src/shortDrama/stages/*.tsx` 在 `shots.length === 0` / `entries.length === 0` 时返回空态面板。
   - `frontend/src/shortDrama/workbench.test.tsx`：`renders every stage without crashing`。
   - 说明：本次未启动 macOS GUI 做真机点击，空态结论来自代码路径与 SSR smoke。
4. **费用闸门展示服务端估算；未估价项要求勾选**
   - `frontend/src/shortDrama/DramaCostGate.tsx`：`unpriced.length > 0` 时必须勾选，超预算禁用确认。
   - `test/pipeline/drama/cost_test.dart`：`P1 estimate marks LLM unpriced and keeps budget snapshot`。
5. **`make analyze` 零告警；`make test-dart` 全绿**
   - 见上表。
6. **`npm test && npm run lint && npm run build` 通过；`make web` 已提交**
   - 见上表；`git status --short web_build` 为空。
7. **不提交 `pipeline_out/`、`.env`、密钥**
   - `git status` 干净；`.gitignore` 已覆盖 `pipeline_out/` 与 `.env`。

## 结论

P1 的离线验收全部通过；唯一未做的是 macOS 真机点击空态，已作为已知边界记录。P2 的 UI 验收会在设置入口与画面工序完成后补做。
