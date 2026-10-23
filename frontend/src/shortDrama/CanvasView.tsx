/// 画布视图：静态 DAG 布局 + 真实工序状态；未接入节点显示「未接入」。
import type { StepKey, StepView } from "./types";
import {
  DAG_BANNER,
  DAG_EDGES,
  DAG_NODES,
  DAG_NODE_H,
  DAG_NODE_W,
  dagNodeMetaFromStep,
  dagNodeStep,
  type DagNode,
} from "./pipelineDag";

interface Props {
  steps: StepView[];
  selected: StepKey;
  onSelect: (key: StepKey) => void;
}

type Side = "l" | "r" | "t" | "b";

function anchor(node: DagNode, side: Side) {
  if (side === "l") return { x: node.x, y: node.y + DAG_NODE_H / 2 };
  if (side === "r") return { x: node.x + DAG_NODE_W, y: node.y + DAG_NODE_H / 2 };
  if (side === "t") return { x: node.x + DAG_NODE_W / 2, y: node.y };
  return { x: node.x + DAG_NODE_W / 2, y: node.y + DAG_NODE_H };
}

function edgePath(a: DagNode, b: DagNode): string {
  const horizontal = a.x !== b.x;
  const p = anchor(a, horizontal ? (a.x < b.x ? "r" : "l") : a.y < b.y ? "b" : "t");
  const q = anchor(b, horizontal ? (a.x < b.x ? "l" : "r") : a.y < b.y ? "t" : "b");
  if (horizontal) {
    const half = Math.max(18, Math.abs(q.x - p.x) / 2);
    return `M${p.x} ${p.y} C${p.x + half} ${p.y} ${q.x - half} ${q.y} ${q.x} ${q.y}`;
  }
  const half = Math.max(20, Math.abs(q.y - p.y) / 2);
  return `M${p.x} ${p.y} C${p.x} ${p.y + half} ${q.x} ${q.y - half} ${q.x} ${q.y}`;
}

export default function CanvasView({ steps, selected, onSelect }: Props) {
  const byKey = new Map(DAG_NODES.map((node) => [node.key, node]));
  const statusByStep = new Map(steps.map((step) => [step.key, step]));
  return (
    <section className="sd-canvas">
      <div className="sd-canvas-banner">{DAG_BANNER}</div>
      <div className="sd-canvas-scroll">
        <div className="sd-canvas-board">
          <svg className="sd-canvas-svg" width={850} height={420} viewBox="0 0 850 420">
            {DAG_EDGES.map((edge) => {
              const from = byKey.get(edge.from);
              const to = byKey.get(edge.to);
              if (from === undefined || to === undefined) return null;
              return (
                <path
                  key={`${edge.from}-${edge.to}`}
                  className="sd-edge"
                  d={edgePath(from, to)}
                />
              );
            })}
          </svg>
          {DAG_NODES.map((node) => {
            const stepKey = dagNodeStep(node.key);
            const step = stepKey === undefined ? undefined : statusByStep.get(stepKey);
            const isSelected = stepKey !== undefined && stepKey === selected;
            return (
              <button
                type="button"
                key={node.key}
                className={`sd-node st-${step?.status ?? "pending"}${
                  isSelected ? " sel" : ""
                }${step?.wired === false || step === undefined ? " unwired" : ""}`}
                style={{
                  left: node.x,
                  top: node.y,
                  width: DAG_NODE_W,
                  height: DAG_NODE_H,
                }}
                onClick={() => {
                  if (stepKey !== undefined) onSelect(stepKey);
                }}
              >
                <span className="sd-node-idx">{node.idx}</span>
                <span className="sd-node-name">{node.name}</span>
                <span className="sd-node-meta">
                  {dagNodeMetaFromStep(node.key, steps)}
                </span>
                <span className="sd-node-status">
                  {step === undefined || !step.wired ? "未接入" : step.status}
                </span>
              </button>
            );
          })}
          <p className="sd-canvas-note">
            实线 = 工序依赖；虚线区域（实验区）P4 接入，当前不显示假节点。
          </p>
        </div>
      </div>
    </section>
  );
}
