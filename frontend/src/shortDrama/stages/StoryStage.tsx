/// 故事工序：编辑 logline、梗概、节拍、角色与本集设置。
import { useState } from "react";
import { DramaApiError, dramaApi } from "../api";
import type {
  DramaBeat,
  DramaCastMember,
  EpisodeBundle,
} from "../types";

interface Props {
  bundle: EpisodeBundle;
  onReload: () => void;
}

function messageOf(error: unknown): string {
  if (error instanceof DramaApiError) return error.message;
  if (error instanceof Error) return error.message;
  return String(error);
}

function nextBeatId(beats: DramaBeat[]): string {
  const used = new Set(beats.map((beat) => beat.id));
  let index = beats.length + 1;
  while (used.has(`b${index}`)) index += 1;
  return `b${index}`;
}

function nextCastId(cast: Record<string, DramaCastMember>): string {
  let index = Object.keys(cast).length + 1;
  while (cast[`role${index}`] !== undefined) index += 1;
  return `role${index}`;
}

export default function StoryStage({ bundle, onReload }: Props) {
  const [logline, setLogline] = useState(bundle.episode.story.logline);
  const [synopsis, setSynopsis] = useState(bundle.episode.story.synopsis);
  const [beats, setBeats] = useState<DramaBeat[]>(bundle.episode.story.beats);
  const [cast, setCast] = useState<Record<string, DramaCastMember>>(
    bundle.series.cast,
  );
  const [dialect, setDialect] = useState(bundle.episode.settings.dialect);
  const [total, setTotal] = useState(String(bundle.episode.settings.total_budget_yuan));
  const [i2v, setI2v] = useState(String(bundle.episode.settings.i2v_budget_yuan));
  const [target, setTarget] = useState(
    String(bundle.episode.settings.target_duration_s),
  );
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const updateBeat = (id: string, patch: Partial<DramaBeat>) => {
    setBeats((current) =>
      current.map((beat) => (beat.id === id ? { ...beat, ...patch } : beat)),
    );
  };

  const updateCast = (id: string, patch: Partial<DramaCastMember>) => {
    setCast((current) => {
      const member = current[id];
      if (member === undefined) return current;
      return { ...current, [id]: { ...member, ...patch } };
    });
  };

  const save = async () => {
    setError("");
    if (logline.trim() === "" || synopsis.trim() === "") {
      setError("logline 和梗概都不能为空");
      return;
    }
    const totalValue = Number(total);
    const i2vValue = Number(i2v);
    const targetValue = Number(target);
    if (!Number.isFinite(totalValue) || totalValue <= 0) {
      setError("总预算必须是有限正数");
      return;
    }
    if (!Number.isFinite(i2vValue) || i2vValue <= 0) {
      setError("i2v 预算必须是有限正数");
      return;
    }
    if (!Number.isFinite(targetValue) || targetValue <= 0) {
      setError("目标时长必须是有限正数");
      return;
    }
    if (Object.keys(cast).length === 0) {
      setError("至少需要一个角色");
      return;
    }
    setBusy(true);
    try {
      await dramaApi.updateSeries(bundle.series.series_id, {
        ...bundle.series,
        cast,
      });
      await dramaApi.updateEpisode(
        bundle.series.series_id,
        bundle.episode.episode_id,
        {
          ...bundle.episode,
          story: {
            ...bundle.episode.story,
            logline: logline.trim(),
            synopsis: synopsis.trim(),
            beats,
          },
          settings: {
            ...bundle.episode.settings,
            dialect,
            total_budget_yuan: totalValue,
            i2v_budget_yuan: i2vValue,
            target_duration_s: targetValue,
          },
        },
      );
      onReload();
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>02 故事 · 梗概与角色</h2>
          <p>角色与节拍在保存后成为剧集事实源；分镜表会引用这里的角色 id。</p>
        </div>
        <span className="sd-pill">{Object.keys(cast).length} 角色</span>
      </header>

      <div className="sd-panel">
        <h3>故事</h3>
        <div className="sd-form-grid">
          <label className="sd-field">
            <span>logline</span>
            <input
              value={logline}
              onChange={(event) => setLogline(event.target.value)}
              placeholder="一句话说清这集的核心冲突"
            />
          </label>
          <label className="sd-field">
            <span>梗概</span>
            <textarea
              rows={5}
              value={synopsis}
              onChange={(event) => setSynopsis(event.target.value)}
              placeholder="这一集发生了什么"
            />
          </label>
        </div>
      </div>

      <div className="sd-panel">
        <h3>节拍</h3>
        <div className="sd-beats-edit">
          {beats.map((beat) => (
            <div className="sd-beat-row" key={beat.id}>
              <input
                className="sd-cell-id"
                value={beat.id}
                onChange={(event) => updateBeat(beat.id, { id: event.target.value })}
              />
              <input
                value={beat.label}
                onChange={(event) => updateBeat(beat.id, { label: event.target.value })}
                placeholder="名称"
              />
              <input
                className="sd-cell-line"
                value={beat.summary}
                onChange={(event) =>
                  updateBeat(beat.id, { summary: event.target.value })
                }
                placeholder="内容"
              />
              <button
                type="button"
                className="sd-icon-btn"
                title="删除节拍"
                onClick={() => setBeats(beats.filter((item) => item.id !== beat.id))}
              >
                ×
              </button>
            </div>
          ))}
        </div>
        <button
          type="button"
          className="sd-btn ghost"
          onClick={() =>
            setBeats([
              ...beats,
              {
                id: nextBeatId(beats),
                label: "新节拍",
                summary: "",
                target_s: null,
                weight: null,
              },
            ])
          }
        >
          ＋ 添加节拍
        </button>
      </div>

      <div className="sd-panel">
        <h3>角色</h3>
        <div className="sd-cast-edit">
          {Object.entries(cast).map(([id, member]) => (
            <div className="sd-cast-row" key={id}>
              <span className="sd-cast-id mono">{id}</span>
              <input
                value={member.name}
                onChange={(event) => updateCast(id, { name: event.target.value })}
                placeholder="名字"
              />
              <input
                className="sd-cell-line"
                value={member.description}
                onChange={(event) =>
                  updateCast(id, { description: event.target.value })
                }
                placeholder="外形/人设"
              />
              <input
                value={member.voice_id ?? ""}
                onChange={(event) =>
                  updateCast(id, { voice_id: event.target.value || null })
                }
                placeholder="voice_id"
              />
              <input
                className="sd-cell-duration"
                value={member.dialect ?? ""}
                onChange={(event) =>
                  updateCast(id, { dialect: event.target.value || null })
                }
                placeholder="方言"
              />
              <button
                type="button"
                className="sd-icon-btn"
                title="删除角色"
                onClick={() => {
                  const next = { ...cast };
                  delete next[id];
                  setCast(next);
                }}
              >
                ×
              </button>
            </div>
          ))}
        </div>
        <button
          type="button"
          className="sd-btn ghost"
          onClick={() => {
            const id = nextCastId(cast);
            setCast({
              ...cast,
              [id]: {
                name: "新角色",
                description: "",
                voice_id: null,
                dialect: dialect || null,
                avatar: null,
              },
            });
          }}
        >
          ＋ 添加角色
        </button>
      </div>

      <div className="sd-panel">
        <h3>本集设置</h3>
        <div className="sd-form-grid four">
          <label className="sd-field">
            <span>方言</span>
            <input value={dialect} onChange={(event) => setDialect(event.target.value)} />
          </label>
          <label className="sd-field">
            <span>总预算（元）</span>
            <input
              type="number"
              min={0.01}
              step={0.01}
              value={total}
              onChange={(event) => setTotal(event.target.value)}
            />
          </label>
          <label className="sd-field">
            <span>i2v 预算（元）</span>
            <input
              type="number"
              min={0.01}
              step={0.01}
              value={i2v}
              onChange={(event) => setI2v(event.target.value)}
            />
          </label>
          <label className="sd-field">
            <span>目标时长（秒）</span>
            <input
              type="number"
              min={1}
              step={1}
              value={target}
              onChange={(event) => setTarget(event.target.value)}
            />
          </label>
        </div>
      </div>

      {error !== "" && <div className="sd-alert">{error}</div>}
      <div className="sd-actions">
        <button
          type="button"
          className="sd-btn primary"
          disabled={busy}
          onClick={() => void save()}
        >
          {busy ? "保存中…" : "保存故事与设置"}
        </button>
        <span className="sd-hint">
          保存设置后，若已有分镜表会自动重算计划单。
        </span>
      </div>
    </section>
  );
}
