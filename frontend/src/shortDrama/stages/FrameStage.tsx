/// 画面工序占位：P2 接首帧 / i2v / t2v 编排。
import type { EpisodeBundle } from "../types";

export default function FrameStage({ bundle }: { bundle: EpisodeBundle }) {
  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>05 画面</h2>
          <p>首帧、静帧、微动、i2v/t2v 会在这一工序逐镜生成。</p>
        </div>
        <span className="sd-pill">未接入</span>
      </header>
      <div className="sd-panel">
        <p className="sd-empty">
          当前 {bundle.storyboard?.shots.length ?? 0} 镜。
          P2 接入后才显示真实缩略图、缓存与费用闸门。
        </p>
      </div>
    </section>
  );
}
