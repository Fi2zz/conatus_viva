/// 计划单摘要：镜头、时长、i2v、成本与 warnings。
import type { Plan } from "./model";
import { costByRoute, formatSeconds, formatYuan } from "./model";
import { budgetPercent } from "./view";

interface Props {
  plan: Plan | null;
  i2vBudgetYuan: number;
  totalBudgetYuan: number;
  actualYuan: number;
}

export default function PlanSummary({
  plan,
  i2vBudgetYuan,
  totalBudgetYuan,
  actualYuan,
}: Props) {
  if (plan === null) {
    return (
      <div className="sd-panel">
        <h3>计划单</h3>
        <p className="sd-empty">保存分镜表后自动生成计划单。</p>
      </div>
    );
  }
  const routeCost = costByRoute(plan.shots);
  const pct = budgetPercent(actualYuan, totalBudgetYuan);
  return (
    <div className="sd-panel sd-plan-summary">
      <h3>计划单</h3>
      <dl className="sd-kv">
        <div>
          <dt>镜头</dt>
          <dd>{plan.shots.length} 镜</dd>
        </div>
        <div>
          <dt>总时长</dt>
          <dd>{formatSeconds(plan.totals.duration_s)}</dd>
        </div>
        <div>
          <dt>i2v 秒数</dt>
          <dd>
            {plan.totals.i2v_seconds}s / 预算 {formatYuan(i2vBudgetYuan)}
          </dd>
        </div>
        <div>
          <dt>预估成本</dt>
          <dd className="mono">{formatYuan(plan.totals.estimated_yuan)}</dd>
        </div>
        <div>
          <dt>i2v 剩余</dt>
          <dd className="mono">{formatYuan(plan.totals.remaining_yuan)}</dd>
        </div>
        <div>
          <dt>总预算剩余</dt>
          <dd className="mono">{formatYuan(plan.totals.total_remaining_yuan ?? plan.totals.remaining_yuan)}</dd>
        </div>
        <div>
          <dt>路由</dt>
          <dd>
            静帧 {plan.counts.kenburns} · 微动 {plan.counts.micro} · i2v{" "}
            {plan.counts.i2v} · t2v {plan.counts.t2v ?? 0}
          </dd>
        </div>
      </dl>
      <div className="sd-cost-bars">
        <span>
          静帧 <b>{formatYuan(routeCost.kenburns)}</b>
        </span>
        <span>
          微动 <b>{formatYuan(routeCost.micro)}</b>
        </span>
        <span>
          i2v <b>{formatYuan(routeCost.i2v)}</b>
        </span>
        <span>
          t2v <b>{formatYuan(routeCost.t2v)}</b>
        </span>
      </div>
      <div className="sd-budget-line">
        本集实际 <b>{formatYuan(actualYuan)}</b> / 总预算{" "}
        {formatYuan(totalBudgetYuan)}
        <span className="sd-bar">
          <i style={{ width: `${pct}%` }} />
        </span>
      </div>
      {plan.warnings.length > 0 && (
        <ul className="sd-warnings">
          {plan.warnings.map((warning) => (
            <li key={warning}>{warning}</li>
          ))}
        </ul>
      )}
    </div>
  );
}
