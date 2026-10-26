# P2 验收记录（定妆 + 画面）

日期：2026-10-26
计划：`docs/superpowers/plans/2026-10-26-drama-workbench-p2.md`
设计：`docs/superpowers/specs/2026-10-23-drama-workbench-design.md`（含 §13 修订）

## 离线结果

| 命令 | 结果 |
|---|---|
| `make analyze` | No issues found |
| `make test-dart` | 394 tests passed |
| `make test-web` | vitest 62 passed / oxlint / check:dialogs 全绿 |
| `cd frontend && npm run build` | 构建成功 |
| `make web` | `web_build/` 与源码一致 |
| `flutter build macos --debug` | `Viva.app` 构建成功 |

## 覆盖点

- 产物 hash：`test/pipeline/drama/hashes_test.dart`。
- 新格式估算：`test/pipeline/drama/cost_test.dart`、`pricing_test.dart`。
- 竖屏 ffmpeg：`test/pipeline/ffmpeg_test.dart`（真实 ffmpeg 输出 1080×1920）。
- 媒体网关：`test/pipeline/drama/media_gateway_test.dart`（缺 key 先失败、本地片段可播放）。
- 定妆/画面执行器：`test/pipeline/drama/runner_test.dart`（缓存、force、并发、取消、部分失败、降级、stale）。
- run/资产端点：`test/server/drama_run_api_test.dart`（202、轮询、assets、路径逃逸 400、预算 409、`episode_busy` 409、voice 501）。
- 设置 API：`test/server/settings_api_test.dart`（不回声、清除、启动加载、无 store 501）。
- 工序推导：`test/pipeline/drama/steps_test.dart`（cast/frame stale 与成本）。

## 真实 smoke

- 脚本：`test/manual/drama_real_smoke.dart`，默认 skip；`RUN_REAL_DRAMA=1` 才执行。
- Key 来源：macOS 系统钥匙串（设置页写入），不从 `.env` 读取。
- 结果：**通过**。服务端估算 ¥0.85，实际 ¥0.85；生成 1 张定妆图 + 1 张首帧 + 1 条 3 秒 i2v，clip 时长校验通过。
- 说明：smoke 通过 `security find-generic-password` 读取 key，证明「设置页 → Swift Keychain → 读取」链路可用；smoke 的临时目录在结束后删除，未入库。

## 手工检查

- 设置页保存后无需重启即可读取新 key；真实 smoke 已证明。
- 定妆生成后显示「待采用」，采用后写入 `series.json`；真实 smoke 走完采用 → 画面。
- 画面时间轴、批量/单镜/降级、费用闸门已通过前端 SSR 测试与代码路径核对；未做完整的人工点击回归。
- 空态与未接入 voice/edit/pack 不显示假进度。
- 已知边界：本轮未在 GUI 里逐项点击全部按钮；真实 smoke 覆盖了后端真实链路，UI 交互以 vitest/SSR 为准。

## 评审修复

- 降级 `degrade:true` 现在按本地 kenburns 估算（0 元），并识别已降级 clip 为当前产物，不再误报 stale。
- 只有 `target != frame` 才要求计划单；无计划也可以生成首帧。
- `priceYuanPerSecond` 改用配置解析后的 `pricing.i2vYuanPerSecond`，计划单与估算一致。
- `runs/<id>` 读取/取消校验 series/episode 归属，跨集访问 404。
- Inspector 显示中文产物状态、hash 短码与错误；运行失败时面板显示 `run.error || run.error`。
- 设置按钮上移到右下角底部栏上方，避免遮挡「导出 / 投放包」。

