/// 分镜工序（P1 只读骨架；Task 10 接可编辑表格与 LLM 草稿）。
import { formatSeconds, formatYuan } from "../model";
import type { EpisodeBundle } from "../types";

export default function BoardStage({ bundle }: { bundle: EpisodeBundle }) {
  const board = bundle.storyboard;
  const plan = bundle.plan;
  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>04 分镜 · 计划单</h2>
          <p>分镜表与计划单是同一份数据的两个视图。</p>
        </div>
        <span className="sd-pill">{board?.shots.length ?? 0} 镜</span>
      </header>
      <div className="sd-panel">
        {board === null ? (
          <p className="sd-empty">
            还没有分镜表。下一提交可在工作台生成草稿或手动添加镜头。
          </p>
        ) : (
          <>
            <dl className="sd-kv">
              <div>
                <dt>镜头</dt>
                <dd>{board.shots.length}</dd>
              </div>
              <div>
                <dt>总时长</dt>
                <dd>
                  {plan ? formatSeconds(plan.totals.duration_s) : "未生成计划单"}
                </dd>
              </div>
              <div>
                <dt>i2v</dt>
                <dd>{plan ? `${plan.totals.i2v_seconds}s` : "—"}</dd>
              </div>
              <div>
                <dt>预估</dt>
                <dd>{plan ? formatYuan(plan.totals.estimated_yuan) : "—"}</dd>
              </div>
            </dl>
            <p className="sd-note">
              {plan === null
                ? "保存分镜表后会自动生成计划单。"
                : `计划单剩余 ¥${plan.totals.remaining_yuan.toFixed(2)}`}
            </p>
          </>
        )}
      </div>
    </section>
  );
}
