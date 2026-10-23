/// 剪辑工序：P1 先放编辑成本对比，P3 接竖屏合成。
import EditCostEstimator from "../../EditCostEstimator";

export default function EditStage() {
  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>07 剪辑 · 成本对比</h2>
          <p>编辑模型成本只读对比；P3 才接竖屏合成、混音与字幕。</p>
        </div>
        <span className="sd-pill">只读</span>
      </header>
      <div className="sd-embed">
        <EditCostEstimator />
      </div>
    </section>
  );
}
