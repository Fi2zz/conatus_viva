/// 故事工序（P1 只读骨架；Task 10 接可编辑）。
import type { EpisodeBundle } from "../types";

export default function StoryStage({ bundle }: { bundle: EpisodeBundle }) {
  const { episode, series } = bundle;
  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>02 故事 · 梗概与角色</h2>
          <p>故事、节拍和角色会在同一张表单里编辑。</p>
        </div>
        <span className="sd-pill">P1 骨架</span>
      </header>
      <div className="sd-panel">
        <h3>故事</h3>
        <dl className="sd-kv">
          <div>
            <dt>logline</dt>
            <dd>{episode.story.logline || "—"}</dd>
          </div>
          <div>
            <dt>梗概</dt>
            <dd>{episode.story.synopsis || "—"}</dd>
          </div>
        </dl>
      </div>
      <div className="sd-panel">
        <h3>角色 · {Object.keys(series.cast).length}</h3>
        {Object.keys(series.cast).length === 0 ? (
          <p className="sd-empty">暂无角色；下一提交可在这里新增。</p>
        ) : (
          <div className="sd-cast-grid">
            {Object.entries(series.cast).map(([id, member]) => (
              <article key={id} className="sd-cast-card">
                <b>{member.name}</b>
                <span>{id}</span>
                <p>{member.description || "暂无描述"}</p>
                <small>{member.voice_id ?? "未分配 voice_id"}</small>
              </article>
            ))}
          </div>
        )}
      </div>
    </section>
  );
}
