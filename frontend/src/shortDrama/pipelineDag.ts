/// 短剧工作台「画布视图」的工序 DAG（真实 steps 状态）。
///
/// 布局取自 `prototype/short-drama-console.html`（不修改原型）；节点状态
/// 只来自 `/api/drama` 返回的 steps，未接入节点显示「未接入」。
import { STEP_TO_DAG } from "./view";
import type { StepKey, StepView } from "./types";

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

/// 画布节点 → 工序 key。
export function dagNodeStep(key: DagNodeKey): StepKey | undefined {
  return (Object.keys(STEP_TO_DAG) as StepKey[]).find(
    (step) => STEP_TO_DAG[step] === key,
  );
}

/// 节点摘要来自真实 step；未接入显示「未接入」。
export function dagNodeMetaFromStep(
  key: DagNodeKey,
  steps: StepView[],
): string {
  const stepKey = dagNodeStep(key);
  if (stepKey === undefined) return "未接入";
  const step = steps.find((item) => item.key === stepKey);
  if (step === undefined || !step.wired) return "未接入";
  return step.summary === "" ? "待处理" : step.summary;
}

export const DAG_BANNER = "工序状态来自本地 state · 未接入项不显示进度";
