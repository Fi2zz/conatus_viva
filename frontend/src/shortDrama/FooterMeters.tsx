/// 底栏：实际成本、镜头数与真实素材指标；P1 未产生的指标显示 `—`。
import { formatYuan } from "./model";
import { budgetPercent } from "./view";

interface Props {
  actualYuan: number;
  totalYuan: number;
  shotCount: number;
  hookCount: number;
}

export default function FooterMeters({
  actualYuan,
  totalYuan,
  shotCount,
  hookCount,
}: Props) {
  const pct = budgetPercent(actualYuan, totalYuan);
  return (
    <footer className="sd-footer">
      <div className="sd-meter">
        本集成本 <b>{formatYuan(actualYuan)}</b>
        <span className="sd-bar">
          <i style={{ width: `${pct}%` }} />
        </span>
        <span className="sd-sub">/ {formatYuan(totalYuan)}</span>
      </div>
      <div className="sd-meter">
        工时 <b>—</b>
        <span className="sd-sub">P1 不统计跨会话</span>
      </div>
      <div className="sd-meter">
        镜头 <b>{shotCount}</b>
      </div>
      <div className="sd-meter">
        可测素材 <b>—</b>
      </div>
      <div className="sd-meter">
        前 3 秒 <b>{hookCount}</b>
      </div>
      <div className="sd-foot-right">
        <span className="sd-eta">出片 P3 接入</span>
        <button type="button" className="sd-btn-mini" disabled title="P3 接入导出">
          导出投放包
        </button>
        <button
          type="button"
          className="sd-btn-mini primary"
          disabled
          title="P3 接入合成"
        >
          出片
        </button>
      </div>
    </footer>
  );
}
