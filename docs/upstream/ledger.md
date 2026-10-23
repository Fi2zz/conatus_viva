# 反提交账本

规则只有一条：**任何「本该在 conatus、但先在 viva 绕行」的实现都必须在这里挂一行**，
否则半年后收不回来。每行记录：期望改动、归属包、上游状态、本地绕行位置。

状态取值：`已落补丁` / `待设计` / `待提` / `不做（留 viva）` / `新包`。

## 已落补丁

| 期望改动 | 包 | 状态 | 位置 |
|---|---|---|---|
| `ToolResult.meta` + `withMeta` | `conatus_foundation` | 已落补丁（0001） | `patches/0001-foundation-tool-result-meta.patch` |
| `WorkflowNode.label` / `metadata` | `conatus_workflow` | 已落补丁（0002） | `patches/0002-workflow-node-run-meta.patch` |
| `RunNode.meta` + `WorkflowEngine.recordNodeMeta` | `conatus_workflow` | 已落补丁（0002） | 同上 |
| 工具节点自动把 `ToolResult.meta` 合入运行图 | `conatus_workflow` | 已落补丁（0002） | 同上 |

## 待设计 / 待提

| 期望改动 | 包 | 状态 | 本地绕行 |
|---|---|---|---|
| 预算单位（现在只有美元 `dailyBudget`，且 `CostTracker` 无实现） | `conatus_agent` | 待设计：单位无关的预算缝 | viva 先用 `ToolGuard` 做「本集预算」硬闸门 |
| 节点级 `timeout` / `retry` 策略（`attempts` 已有，策略没有） | `conatus_workflow` | 待提 | 无，暂时由工具内部重试 |
| 条件分支 `else`（现在是两条互斥 `when`） | `conatus_workflow` | 待设计 | 两条互斥节点 |
| run 级预算与并发度 | `conatus_workflow` | 待设计 | viva 在宿主层限流 |
| 结构化文档块的锚定与列表操作（分镜表是 JSON 数组，现在是文本块） | `conatus_doc` | 待设计：先跑真实剧本修订，攒需求 | 分镜表暂用纯文本块 + 自建 JSON |
| 长任务租约 / 心跳（批次 80 集需要） | `conatus_team` | 待设计 | viva 自建批次队列 |
| MCP server（`conatus_mcp` 只有 client） | 新包 | 待评估 | 先复用 viva 内嵌 HTTP API |

## 不做（留 viva）

| 东西 | 理由 |
|---|---|
| 短剧域模型（series / episode / shot / beat / cast） | 领域词不进通用编排引擎 |
| 百炼客户端（图 / 视频 / TTS 方言） | 厂商接入属于应用层；conatus 只保留 TTS 能力缝 |
| ffmpeg 参数与素材库 | 执行细节 |
| 画布 / 时间轴 UI | conatus 是运行时框架，不是 GUI |
| 人民币计价与单集成本口径 | 属于业务账本；上游只收通用 meta |

## 收口检查

提 PR 前逐条过：

1. 这个改动第二个消费者（非短剧场景）会用吗？
2. 新增字段是否全部可选、默认行为是否不变？
3. 旧 JSON 能读吗？新 JSON 被旧代码读取时只是忽略未知字段吗？
4. 包内单测覆盖了缺字段 / 未知字段 / 空值吗？
5. `dart analyze --fatal-infos` + 受影响包 `dart test` 通过了吗？
6. README / CHANGELOG 同步了吗？
7. 有没有把领域词写进上游 API 或测试名？
