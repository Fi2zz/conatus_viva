/// 工作台展示层的纯函数：工序顺序、标签、预算百分比。
import type { StepKey, StepView } from "./types";

export { budgetPercent } from "./model";

export const STEP_ORDER: StepKey[] = [
  "split",
  "story",
  "cast",
  "board",
  "frame",
  "voice",
  "edit",
  "pack",
];

export const STEP_LABELS: Record<StepKey, string> = {
  split: "拆片",
  story: "故事",
  cast: "定妆",
  board: "分镜",
  frame: "画面",
  voice: "声音",
  edit: "剪辑",
  pack: "打包",
};

export const STEP_TO_DAG: Record<
  StepKey,
  "rip" | "story" | "cast" | "board" | "frame" | "voice" | "edit" | "pack"
> = {
  split: "rip",
  story: "story",
  cast: "cast",
  board: "board",
  frame: "frame",
  voice: "voice",
  edit: "edit",
  pack: "pack",
};

/// 工序状态文案；未接入优先，避免把「未实现」显示成「待处理」。
export function stepStatusLabel(step: StepView): string {
  if (!step.wired) return "未接入";
  switch (step.status) {
    case "pending":
      return "待处理";
    case "running":
      return "运行中";
    case "succeeded":
      return "完成";
    case "failed":
      return "失败";
    case "stale":
      return "已过期";
    case "skipped":
      return "已跳过";
    case "interrupted":
      return "已中断";
  }
}

export function findStep(
  steps: StepView[],
  key: StepKey,
): StepView | undefined {
  return steps.find((step) => step.key === key);
}
