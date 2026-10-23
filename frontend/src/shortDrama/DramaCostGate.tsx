/// 短剧费用闸门：展示服务端 estimate 的分项与未估价项。
///
/// 有未估价项时必须勾选知悉；超预算时确认按钮禁用。不使用原生对话框。
import { useState } from "react";
import type { DramaEstimate } from "./types";
import { formatYuan } from "./model";

interface Props {
  estimate: DramaEstimate;
  busy: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}

export default function DramaCostGate({
  estimate,
  busy,
  onCancel,
  onConfirm,
}: Props) {
  const [ack, setAck] = useState(false);
  const needsAck = estimate.unpriced.length > 0;
  const overBudget =
    estimate.total_estimated_yuan > estimate.budget.remaining_yuan;
  const disabled = busy || overBudget || (needsAck && !ack);

  return (
    <div className="sd-gate" role="dialog" aria-modal="true">
      <div className="sd-gate-card">
        <header>
          <span>费用确认</span>
          <h3>本次将调用外部模型</h3>
          <p>所有金额以服务端估算为准，最终以实际账单结算。</p>
        </header>

        {estimate.items.length > 0 && (
          <table className="sd-gate-table">
            <thead>
              <tr>
                <th>项目</th>
                <th>模型</th>
                <th>数量</th>
                <th>小计</th>
              </tr>
            </thead>
            <tbody>
              {estimate.items.map((item) => (
                <tr key={`${item.kind}-${item.id}`}>
                  <td>
                    {item.kind} · {item.id}
                  </td>
                  <td className="mono">{item.model}</td>
                  <td>
                    {item.quantity} {item.unit}
                  </td>
                  <td className="mono">{formatYuan(item.subtotal_yuan)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {estimate.unpriced.length > 0 && (
          <div className="sd-gate-unpriced">
            <b>未估价项（以实际账单为准）</b>
            <ul>
              {estimate.unpriced.map((item) => (
                <li key={`${item.kind}-${item.id}`}>
                  {item.kind} · {item.id}（{item.reason}）
                </li>
              ))}
            </ul>
            <label className="sd-gate-check">
              <input
                type="checkbox"
                checked={ack}
                onChange={(event) => setAck(event.target.checked)}
              />
              我已知悉未估价项按实际账单计费
            </label>
          </div>
        )}

        <div className="sd-gate-budget">
          可估价合计 <b>{formatYuan(estimate.total_estimated_yuan)}</b>
          <span>
            预算剩余 {formatYuan(estimate.budget.remaining_yuan)} /{" "}
            {formatYuan(estimate.budget.total_yuan)}
          </span>
        </div>
        {overBudget && (
          <div className="sd-alert">估算超过剩余预算，请提高预算或减少任务。</div>
        )}

        <div className="sd-gate-actions">
          <button type="button" className="sd-btn ghost" onClick={onCancel} disabled={busy}>
            取消
          </button>
          <button
            type="button"
            className="sd-btn primary"
            onClick={onConfirm}
            disabled={disabled}
          >
            {busy ? "提交中…" : "确认执行"}
          </button>
        </div>
      </div>
    </div>
  );
}
