/// 定妆工序占位：P2 接角色形象生成与持久化。
import type { EpisodeBundle } from "../types";

export default function CastStage({ bundle }: { bundle: EpisodeBundle }) {
  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>03 定妆</h2>
          <p>角色形象图全季复用；P2 接图片合成与审批。</p>
        </div>
        <span className="sd-pill">未接入</span>
      </header>
      <div className="sd-panel">
        <p className="sd-empty">
          当前有 {Object.keys(bundle.series.cast).length} 个角色。
          P1 先在工作台里保留入口；P2 才会生成并写回定妆图。
        </p>
      </div>
    </section>
  );
}
