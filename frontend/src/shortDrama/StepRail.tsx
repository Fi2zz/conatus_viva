/// 左栏 8 工序：状态点、摘要、成本与选中态。
import type { StepKey, StepView } from "./types";
import { STEP_LABELS, STEP_ORDER, stepStatusLabel } from "./view";
import { formatYuan } from "./model";

interface Props {
  steps: StepView[];
  selected: StepKey;
  onSelect: (key: StepKey) => void;
}

export default function StepRail({ steps, selected, onSelect }: Props) {
  const byKey = new Map(steps.map((step) => [step.key, step]));
  return (
    <aside className="sd-rail">
      <div className="sd-rail-head">
        <h2>工序</h2>
        <span>08 STEPS</span>
      </div>
      <ul className="sd-steps">
        {STEP_ORDER.map((key, index) => {
          const step = byKey.get(key);
          const status = step?.status ?? "pending";
          const wired = step?.wired ?? false;
          return (
            <li key={key}>
              <button
                type="button"
                className={`sd-step st-${status}${selected === key ? " sel" : ""}${
                  wired ? "" : " unwired"
                }`}
                onClick={() => onSelect(key)}
              >
                <span className="sd-step-idx">
                  {String(index + 1).padStart(2, "0")}
                </span>
                <span className="sd-step-name">{STEP_LABELS[key]}</span>
                <span className="sd-step-cost">
                  {formatYuan(step?.cost_yuan ?? 0)}
                </span>
                <span className="sd-step-meta">
                  {step === undefined ? "未接入" : step.summary}
                </span>
                <span className={`sd-dot st-${status}`} />
                <span className="sd-step-status">
                  {step === undefined ? "未接入" : stepStatusLabel(step)}
                </span>
              </button>
            </li>
          );
        })}
      </ul>
      <p className="sd-rail-note">
        P1 只接入拆片 / 故事 / 分镜；其余工序不显示假进度。
      </p>
    </aside>
  );
}
