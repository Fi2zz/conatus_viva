/// 声音工序占位：P3 接逐句配音与主讲人。
import type { EpisodeBundle } from "../types";

export default function VoiceStage({ bundle }: { bundle: EpisodeBundle }) {
  const lines =
    bundle.storyboard?.shots.filter((shot) => shot.line.trim() !== "") ?? [];
  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>06 声音</h2>
          <p>逐句角色配音与可选主讲人；音频先行动态改镜头时长。</p>
        </div>
        <span className="sd-pill">未接入</span>
      </header>
      <div className="sd-panel">
        <p className="sd-empty">
          当前 {lines.length} 句台词。P3 接入后在这里显示音频条与配音状态。
        </p>
      </div>
    </section>
  );
}
