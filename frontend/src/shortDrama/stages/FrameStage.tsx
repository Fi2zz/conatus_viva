/// 画面工序：镜头选择 + 图片合成 / 文生视频 / 图生视频工具。
///
/// P1 结果只留在工具内；P2 才写入逐镜产物、缓存与费用闸门。
import { useState } from "react";
import type { EpisodeBundle } from "../types";
import ImageStudio from "../../ImageStudio";
import VideoStudio from "../../VideoStudio";

export default function FrameStage({ bundle }: { bundle: EpisodeBundle }) {
  const shots = bundle.storyboard?.shots ?? [];
  const [selectedId, setSelectedId] = useState(shots[0]?.id ?? "");
  const selected =
    shots.find((shot) => shot.id === selectedId) ?? shots[0] ?? null;

  if (selected === null) {
    return (
      <section className="sd-stage">
        <header className="sd-stage-head">
          <div>
            <h2>05 画面 · 生成</h2>
            <p>先有分镜表，才有镜头上下文。</p>
          </div>
          <span className="sd-pill">0 镜</span>
        </header>
        <div className="sd-panel">
          <p className="sd-empty">还没有镜头。先到「分镜」工序保存分镜表。</p>
        </div>
      </section>
    );
  }

  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>05 画面 · 生成</h2>
          <p>首帧/静帧、文生视频、图生视频都从这里进；P1 结果暂不写回剧集。</p>
        </div>
        <span className="sd-pill">{shots.length} 镜</span>
      </header>

      <div className="sd-panel">
        <h3>镜头</h3>
        <div className="sd-shot-strip">
          {shots.map((shot) => (
            <button
              type="button"
              key={shot.id}
              className={`sd-shot-chip${shot.id === selected.id ? " sel" : ""}`}
              onClick={() => setSelectedId(shot.id)}
            >
              <b>{shot.id}</b>
              <span>{shot.framing}</span>
              <small>{shot.kind}</small>
            </button>
          ))}
        </div>
        <p className="sd-hint">
          当前镜头：{selected.id} · {selected.visual ?? "未填写画面提示词"}
        </p>
      </div>

      <div className="sd-embed">
        <ImageStudio
          key={`img-${selected.id}`}
          initialPrompt={selected.visual ?? selected.line}
          contextLabel={`${selected.id} · 首帧/静帧（手动生成，暂不自动回填）`}
        />
      </div>

      <div className="sd-embed">
        <VideoStudio
          key={`i2v-${selected.id}`}
          mode="i2v"
          initialPrompt={selected.motion ?? ""}
          contextLabel={`${selected.id} · 图生视频（首帧需在上方手动选择）`}
        />
      </div>

      <div className="sd-embed">
        <VideoStudio
          key={`t2v-${selected.id}`}
          mode="t2v"
          initialPrompt={selected.visual ?? selected.line}
          contextLabel={`${selected.id} · 文生视频（无首帧镜头）`}
        />
      </div>
    </section>
  );
}
