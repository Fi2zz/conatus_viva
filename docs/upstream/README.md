# 上游反提交：conatus

viva 是 conatus `team / workflow / doc` 的第一个真实消费者。这里记录「viva 需要、
但应该长在 conatus 里」的改动，以及按 conatus 仓库规范落成的补丁。

**边界规则**：领域词不进上游（短剧 / 镜头 / 方言 / 人民币 / 百炼 / ffmpeg 全部留在 viva）；
通用机制才提 PR。任何本地绕行都必须在本目录的 [ledger.md](ledger.md) 挂账。

## 补丁

| 文件 | 包 | 抬头 | 基线 | 状态 |
|---|---|---|---|---|
| `patches/0001-foundation-tool-result-meta.patch` | `conatus_foundation` | `feat(foundation): ToolResult 支持宿主侧元数据` | conatus `master` | 可直接应用 |
| `patches/0002-workflow-node-run-meta.patch` | `conatus_workflow` | `feat(workflow): 节点展示元数据与运行期 meta` | **0001 之上（stacked）** | 需先应用 0001 |

## 这两个 PR 有多通用（诚实版）

| 改动 | 判定 | 说明 |
|---|---|---|
| `ToolResult.meta` / `withMeta` | **通用载体** | 任何工具宿主都可能要成本 / 缓存 / 产物指纹；不引入领域语义 |
| `WorkflowNode.label` / `metadata` | **通用数据模型** | 补齐 `WorkflowDefinition.metadata` 之外缺失的节点级展示信息 |
| `RunNode.meta` / `recordNodeMeta` | **通用** | 运行期账本、可视化、预算核对都能用 |
| ToolNode 执行时自动合并 meta | **半通用（桥）** | `NodeExecutor` 返回类型只有 `Object?`，这是不改签名的折中；若将来 `NodeExecutor` 改为返回执行结果对象，这条应删除 |
| 需求来源 | **单一消费者** | 目前只有 viva 在用；「第二个消费者零改动可用」尚未验证，PR 描述里不要包装成「已证明通用」 |

要变成「真通用」还需要两件事：

1. 一个域无关的示例（如三节点「下载 → 转换 → 汇总」批处理），用 meta 记
   bytes / cache，作为第二场景证据；
2. 把 `0002` 拆成 **2a**（`label` / `metadata`，纯数据模型，最安全）与 **2b**
   （`RunNode.meta` + 自动合并，行为层）。2a 先落，2b 在 PR 描述里明确
   「桥接方案，等 NodeExecutor 签名演进后移除」。

## 应用

```bash
cd ~/REPO/conatus

# PR 1
git switch -c feat/foundation-tool-result-meta
git apply /Users/fitz/REPO/conatus_viva/docs/upstream/patches/0001-foundation-tool-result-meta.patch
dart analyze --fatal-infos packages/conatus_foundation
dart test packages/conatus_foundation/test
git add -A && git commit -m 'feat(foundation): ToolResult 支持宿主侧元数据'

# PR 2（stacked：先带上 0001 的改动）
git switch master
git switch -c feat/workflow-node-run-meta
git apply /Users/fitz/REPO/conatus_viva/docs/upstream/patches/0001-foundation-tool-result-meta.patch
git apply /Users/fitz/REPO/conatus_viva/docs/upstream/patches/0002-workflow-node-run-meta.patch
dart analyze --fatal-infos packages/conatus_workflow
dart test packages/conatus_workflow/test
git add -A && git commit -m 'feat(workflow): 节点展示元数据与运行期 meta'
```

> `0002` 的 `CHANGELOG.md` hunk 以 0001 之后的文件为基线；单独对 `master` 应用会在
> CHANGELOG 处冲突，属于 stacked PR 的预期行为。代码部分（workflow 五个文件）
> 本身只依赖 0001 的 `ToolResult.meta`。

## 验证记录（在 conatus 源码快照上执行）

- `dart analyze --fatal-infos packages/conatus_foundation` → No issues
- `dart test packages/conatus_foundation/test` → 223 passed
- `dart analyze --fatal-infos packages/conatus_workflow` → No issues
- `dart test packages/conatus_workflow/test` → 126 passed（含新增 6 个）
- 两个补丁依次应用到 `master` 快照后，10 个文件与开发树逐字节一致
- `dart format --output=none --set-exit-if-changed`：补丁内全部 6 个 Dart 文件
  在包的语言版本（`conatus_workflow` 为 3.6，legacy 风格）下无改动
- 领域词扫描：两份补丁不含短剧领域词汇（画面 / 分镜 / 剧本 / episode）与
  人民币键名（`cost_yuan`），grep 为空

## 兼容性

- 新增字段全部可选，缺省行为与今天完全一致。
- `WorkflowNode.toJson` 在未填 `label` / `metadata` 时不输出新键；旧 JSON 可读，
  新 JSON 被旧代码忽略未知字段。
- `NodeExecutor` 签名不变——没有改成「返回执行结果对象」的破坏性方案。
- `WorkflowEngine` 的新方法带缺省空实现，自定义引擎不实现也能编译。

## PR 描述模板

```markdown
### 背景
viva（媒体生产流水线）是第一个真实消费者：需要把「节点花了多少钱 / 命中没命中缓存」
从工具执行一路带到运行图，否则可视化编排层只能另存一份影子账本。

### 改动
- ToolResult 增加宿主侧 meta（模型不可见）与 withMeta 合并辅助。
- WorkflowNode 增加 label / metadata；RunNode 增加运行期 meta。
- 工具节点执行时自动合并 ToolResult.meta；新增 WorkflowEngine.recordNodeMeta。

### 兼容性
全部为可选新增；缺省行为不变；NodeExecutor 签名不变。

### 验证
dart analyze --fatal-infos <包> + dart test <包>
新增测试：<测试文件>
```
