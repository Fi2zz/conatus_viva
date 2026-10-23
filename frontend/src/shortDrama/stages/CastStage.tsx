/// 定妆工序：角色卡 + 内嵌图片合成工具。
///
/// P1 的生成结果只留在工具内，不自动回填；P2 才写入剧级定妆资产。
import { useState } from "react";
import type { EpisodeBundle } from "../types";
import ImageStudio from "../../ImageStudio";

export default function CastStage({ bundle }: { bundle: EpisodeBundle }) {
  const entries = Object.entries(bundle.series.cast);
  const [selectedId, setSelectedId] = useState(entries[0]?.[0] ?? "");
  const selectedEntry =
    entries.find(([id]) => id === selectedId) ?? entries[0];
  const selected = selectedEntry?.[1] ?? null;
  const selectedKey = selectedEntry?.[0] ?? "";
  const prompt =
    selected === null
      ? ""
      : `角色定妆：${selected.name}。${selected.description}。竖屏半身像，统一暖色电影光，简洁背景，便于全季复用。`;

  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>03 定妆 · 图片合成</h2>
          <p>角色形象全季复用；P1 生成结果不自动回填，P2 才写入剧级资产。</p>
        </div>
        <span className="sd-pill">{entries.length} 角色</span>
      </header>

      {entries.length === 0 ? (
        <div className="sd-panel">
          <p className="sd-empty">还没有角色。先到「故事」工序添加角色。</p>
        </div>
      ) : (
        <>
          <div className="sd-panel">
            <h3>角色</h3>
            <div className="sd-cast-grid">
              {entries.map(([id, member]) => (
                <button
                  type="button"
                  key={id}
                  className={`sd-cast-card${id === selectedKey ? " sel" : ""}`}
                  onClick={() => setSelectedId(id)}
                >
                  <b>{member.name}</b>
                  <span>{id}</span>
                  <p>{member.description || "暂无描述"}</p>
                  <small>{member.voice_id ?? "未分配 voice_id"}</small>
                </button>
              ))}
            </div>
          </div>

          <div className="sd-embed">
            <ImageStudio
              key={selectedKey}
              initialPrompt={prompt}
              contextLabel={`定妆 · ${selected?.name ?? selectedKey} · 生成结果暂不自动回填`}
            />
          </div>
        </>
      )}
    </section>
  );
}
