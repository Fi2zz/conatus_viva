/// 拆片工序：编辑源文本、LLM 拆片、把草稿应用到剧/集。
import { useState } from "react";
import { DramaApiError, dramaApi } from "../api";
import type {
  DramaCastMember,
  DramaEstimate,
  DramaSeries,
  EpisodeBundle,
  StoryExtractResult,
} from "../types";
import DramaCostGate from "../DramaCostGate";

interface Props {
  bundle: EpisodeBundle;
  onBundle: (bundle: EpisodeBundle) => void;
  onReload: () => void;
}

function messageOf(error: unknown): string {
  if (error instanceof DramaApiError) return error.message;
  if (error instanceof Error) return error.message;
  return String(error);
}

function mergeCast(
  series: DramaSeries,
  castNew: Record<string, DramaCastMember>,
  castUpdates: Record<string, DramaCastMember>,
): Record<string, DramaCastMember> {
  const merged = { ...series.cast };
  for (const [id, member] of Object.entries(castNew)) {
    if (merged[id] === undefined) merged[id] = member;
  }
  for (const [id, member] of Object.entries(castUpdates)) {
    const current = merged[id];
    if (current === undefined) continue;
    merged[id] = {
      ...current,
      name: current.name.trim() === "" ? member.name : current.name,
      description:
        current.description.trim() === "" ? member.description : current.description,
      voice_id: current.voice_id ?? member.voice_id,
      dialect: current.dialect ?? member.dialect,
    };
  }
  return merged;
}

export default function SplitStage({ bundle, onBundle, onReload }: Props) {
  const [text, setText] = useState(bundle.episode.source.text);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [estimate, setEstimate] = useState<DramaEstimate | null>(null);
  const [result, setResult] = useState<StoryExtractResult | null>(null);

  const saveText = async () => {
    setBusy(true);
    setError("");
    try {
      const next = await dramaApi.updateEpisode(
        bundle.series.series_id,
        bundle.episode.episode_id,
        {
          ...bundle.episode,
          source: { ...bundle.episode.source, text },
        },
      );
      onBundle(next);
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setBusy(false);
    }
  };

  const askEstimate = async () => {
    setBusy(true);
    setError("");
    try {
      const next = await dramaApi.estimate(
        bundle.series.series_id,
        bundle.episode.episode_id,
        ["story"],
      );
      setEstimate(next);
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setBusy(false);
    }
  };

  const runExtract = async () => {
    setEstimate(null);
    setBusy(true);
    setError("");
    try {
      const next = await dramaApi.extractStory(
        bundle.series.series_id,
        bundle.episode.episode_id,
        text,
      );
      setResult(next);
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setBusy(false);
    }
  };

  const apply = async () => {
    if (result === null) return;
    setBusy(true);
    setError("");
    try {
      await dramaApi.updateSeries(bundle.series.series_id, {
        ...bundle.series,
        cast: mergeCast(bundle.series, result.cast_new, result.cast_updates),
      });
      await dramaApi.updateEpisode(
        bundle.series.series_id,
        bundle.episode.episode_id,
        {
          ...bundle.episode,
          source: { ...bundle.episode.source, text },
          story: {
            ...bundle.episode.story,
            logline: result.logline,
            synopsis: result.synopsis,
            beats: result.beats,
            source_hash: result.source_hash,
          },
        },
      );
      setResult(null);
      onReload();
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setBusy(false);
    }
  };

  const dirty = text !== bundle.episode.source.text;

  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>01 拆片 · 源文本</h2>
          <p>粘贴故事梗概或分场剧本；拆片只生成草稿，应用后才会写回剧集。</p>
        </div>
        <span className="sd-pill">{bundle.episode.story.beats.length} 拍</span>
      </header>

      <div className="sd-panel">
        <h3>故事文本</h3>
        <textarea
          className="sd-story-text"
          rows={12}
          value={text}
          onChange={(event) => setText(event.target.value)}
          placeholder="二舅拿着借条闯进堂屋……"
        />
        <div className="sd-actions">
          <button
            type="button"
            className="sd-btn ghost"
            disabled={busy || !dirty}
            onClick={() => void saveText()}
          >
            保存文本
          </button>
          <button
            type="button"
            className="sd-btn primary"
            disabled={busy || text.trim() === ""}
            onClick={() => void askEstimate()}
          >
            拆片
          </button>
        </div>
        {dirty && <p className="sd-hint">文本尚未保存；拆片会使用当前编辑内容。</p>}
      </div>

      {error !== "" && <div className="sd-alert">{error}</div>}

      {result !== null && (
        <div className="sd-panel sd-diff">
          <h3>拆片草稿 · 尚未应用</h3>
          <dl className="sd-kv">
            <div>
              <dt>logline</dt>
              <dd>{result.logline || "—"}</dd>
            </div>
            <div>
              <dt>梗概</dt>
              <dd>{result.synopsis || "—"}</dd>
            </div>
          </dl>
          <div className="sd-diff-grid">
            <div>
              <h4>节拍</h4>
              {result.beats.length === 0 ? (
                <p className="sd-empty">无</p>
              ) : (
                <ol className="sd-beats">
                  {result.beats.map((beat) => (
                    <li key={beat.id}>
                      <b>{beat.label}</b>
                      <span>{beat.summary}</span>
                    </li>
                  ))}
                </ol>
              )}
            </div>
            <div>
              <h4>角色建议</h4>
              <ul className="sd-cast-list">
                {Object.entries(result.cast_new).map(([id, member]) => (
                  <li key={`new-${id}`}>
                    <b>{member.name}</b>
                    <span className="sd-tag-new">新增</span>
                    <small>{id}</small>
                  </li>
                ))}
                {Object.entries(result.cast_updates).map(([id, member]) => (
                  <li key={`upd-${id}`}>
                    <b>{member.name}</b>
                    <span className="sd-tag-upd">补全</span>
                    <small>{id}</small>
                  </li>
                ))}
              </ul>
            </div>
          </div>
          {result.warnings.length > 0 && (
            <ul className="sd-warnings">
              {result.warnings.map((warning) => (
                <li key={warning}>{warning}</li>
              ))}
            </ul>
          )}
          <div className="sd-actions">
            <button
              type="button"
              className="sd-btn ghost"
              disabled={busy}
              onClick={() => setResult(null)}
            >
              丢弃
            </button>
            <button
              type="button"
              className="sd-btn primary"
              disabled={busy}
              onClick={() => void apply()}
            >
              应用到剧集
            </button>
          </div>
        </div>
      )}

      {estimate !== null && (
        <DramaCostGate
          estimate={estimate}
          busy={busy}
          onCancel={() => setEstimate(null)}
          onConfirm={() => void runExtract()}
        />
      )}
    </section>
  );
}
