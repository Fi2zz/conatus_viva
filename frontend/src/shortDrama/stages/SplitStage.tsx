/// 拆片工序（P1 只读骨架；Task 10 接可编辑与 LLM）。
import type { EpisodeBundle } from "../types";

export default function SplitStage({ bundle }: { bundle: EpisodeBundle }) {
  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>01 拆片 · 源文本</h2>
          <p>先把故事贴进来；P1 下一提交会接可编辑与 LLM 拆片。</p>
        </div>
        <span className="sd-pill">P1 骨架</span>
      </header>
      <div className="sd-panel">
        <h3>故事文本</h3>
        <textarea
          className="sd-story-text"
          rows={10}
          readOnly
          value={bundle.episode.source.text}
          placeholder="还没有故事文本"
        />
      </div>
      <div className="sd-panel">
        <h3>节拍</h3>
        {bundle.episode.story.beats.length === 0 ? (
          <p className="sd-empty">暂无节拍；拆片后在这里显示。</p>
        ) : (
          <ol className="sd-beats">
            {bundle.episode.story.beats.map((beat) => (
              <li key={beat.id}>
                <b>{beat.label}</b>
                <span>{beat.summary}</span>
              </li>
            ))}
          </ol>
        )}
      </div>
    </section>
  );
}
