/// 声音工序：台词列表 + 主讲人导读工具。
///
/// P1 只提供主讲人整片口播；逐句角色配音在 P3 接入。
import type { EpisodeBundle } from "../types";
import SpeakerStudio from "../../SpeakerStudio";

export default function VoiceStage({ bundle }: { bundle: EpisodeBundle }) {
  const shots = bundle.storyboard?.shots ?? [];
  const lines = shots.filter((shot) => shot.line.trim() !== "");
  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>06 声音 · 台词与主讲人</h2>
          <p>P3 会按角色逐句配音；P1 先用主讲人工具生成导读/花絮。</p>
        </div>
        <span className="sd-pill">{lines.length} 句</span>
      </header>

      <div className="sd-panel">
        <h3>台词</h3>
        {lines.length === 0 ? (
          <p className="sd-empty">还没有台词。先到「分镜」工序补台词。</p>
        ) : (
          <ol className="sd-line-list">
            {lines.map((shot) => (
              <li key={shot.id}>
                <b className="mono">{shot.id}</b>
                <span>{shot.speaker ?? "—"}</span>
                <p>「{shot.line}」</p>
              </li>
            ))}
          </ol>
        )}
      </div>

      <div className="sd-embed">
        <SpeakerStudio
          initialTheme={lines[0]?.line ?? ""}
          contextLabel="主讲人导读 · 非逐句角色配音（逐句配音 P3 接入）"
        />
      </div>
    </section>
  );
}
