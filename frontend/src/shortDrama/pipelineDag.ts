/// 短剧工作台「画布视图」的静态工序 DAG（设计预览）。
///
/// 8 个工序节点与连线取自 `prototype/short-drama-console.html`（不修改原型）。
/// 画布视图是**设计预览**，只有「分镜」与「画面」两个节点允许从计划单派生
/// 数字，其余节点一律显示「未接入」，不编造任何运行时状态 / 成本。
import { formatYuan, type Plan } from "./model";

export type DagNodeKey =
  | "rip"
  | "story"
  | "cast"
  | "board"
  | "frame"
  | "voice"
  | "edit"
  | "pack";

export interface DagNode {
  key: DagNodeKey;
  idx: string;
  name: string;
  x: number;
  y: number;
}

export interface DagEdge {
  from: DagNodeKey;
  to: DagNodeKey;
}

/// 节点画布宽度 / 高度，用于画布定位与连线锚点（与原型一致）。
export const DAG_NODE_W = 170;
export const DAG_NODE_H = 84;

export const DAG_NODES: DagNode[] = [
  { key: "rip", idx: "01", name: "拆片", x: 16, y: 36 },
  { key: "story", idx: "02", name: "故事", x: 240, y: 36 },
  { key: "cast", idx: "03", name: "定妆", x: 16, y: 206 },
  { key: "board", idx: "04", name: "分镜", x: 240, y: 206 },
  { key: "frame", idx: "05", name: "画面", x: 464, y: 36 },
  { key: "voice", idx: "06", name: "声音", x: 464, y: 206 },
  { key: "edit", idx: "07", name: "剪辑", x: 672, y: 120 },
  { key: "pack", idx: "08", name: "打包", x: 672, y: 300 },
];

export const DAG_EDGES: DagEdge[] = [
  { from: "rip", to: "story" },
  { from: "story", to: "board" },
  { from: "cast", to: "board" },
  { from: "board", to: "frame" },
  { from: "board", to: "voice" },
  { from: "frame", to: "edit" },
  { from: "voice", to: "edit" },
  { from: "edit", to: "pack" },
];

/// 每个工序节点的辅助文案。只有「分镜」与「画面」从计划单派生：
/// - 分镜：`${shots.length} 镜`
/// - 画面：`${counts.i2v} 镜 i2v · ¥${totals.estimated_yuan}`
/// 其余一律「未接入」。
export function dagNodeMeta(key: DagNodeKey, plan: Plan): string {
  switch (key) {
    case "board":
      return `${plan.shots.length} 镜`;
    case "frame":
      return `${plan.counts.i2v} 镜 i2v · ${formatYuan(plan.totals.estimated_yuan)}`;
    default:
      return "未接入";
  }
}

/// 画布横幅文案：设计预览，工序状态尚未接入 conatus。
export const DAG_BANNER = "设计预览 · 工序状态未接入 conatus";
