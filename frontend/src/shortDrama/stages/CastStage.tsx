/// 定妆工序：角色卡 + 生成 / 采用 / 预览；生成结果写入剧级资产。
import { useState } from "react";
import { dramaApi } from "../api";
import { seriesAssetUrl } from "../asset";
import { useDramaRun } from "../run";
import type { DramaEstimate, EpisodeBundle, DramaSeries } from "../types";
import DramaCostGate from "../DramaCostGate";
import { formatYuan } from "../model";

interface Props {
  bundle: EpisodeBundle;
  onBundle: (bundle: EpisodeBundle) => void;
  onReload: () => void;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export default function CastStage({ bundle, onBundle, onReload }: Props) {
  const entries = Object.entries(bundle.series.cast);
  const [selectedId, setSelectedId] = useState(entries[0]?.[0] ?? "");
  const [estimate, setEstimate] = useState<DramaEstimate | null>(null);
  const [force, setForce] = useState(false);
  const [error, setError] = useState("");
  const [approving, setApproving] = useState(false);
  const selectedEntry =
    entries.find(([id]) => id === selectedId) ?? entries[0];
  const selected = selectedEntry?.[1] ?? null;
  const selectedKey = selectedEntry?.[0] ?? "";
  const run = useDramaRun(
    bundle.series.series_id,
    bundle.episode.episode_id,
    onReload,
  );

  const askEstimate = async (nextForce: boolean) => {
    setError("");
    try {
      const next = await dramaApi.estimate(
        bundle.series.series_id,
        bundle.episode.episode_id,
        { step: "cast", cast_ids: [selectedKey], force: nextForce },
      );
      setForce(nextForce);
      setEstimate(next);
    } catch (cause) {
      setError(messageOf(cause));
    }
  };

  const confirmRun = async () => {
    setEstimate(null);
    await run.startStep("cast", {
      cast_ids: [selectedKey],
      force,
    });
  };

  const approve = async () => {
    if (selected === null || selected.avatar === null) return;
    setApproving(true);
    setError("");
    try {
      const series: DramaSeries = {
        ...bundle.series,
        cast: {
          ...bundle.series.cast,
          [selectedKey]: {
            ...selected,
            avatar: { ...selected.avatar, approved: true },
          },
        },
      };
      const updated = await dramaApi.updateSeries(
        bundle.series.series_id,
        series,
      );
      onBundle({ ...bundle, series: updated.series });
      onReload();
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setApproving(false);
    }
  };

  const runPanel =
    run.run !== null || run.busy ? (
      <div className="sd-panel sd-run-panel">
        <div className="sd-run-head">
          <b>{run.busy ? "定妆生成中…" : "最近一次定妆运行"}</b>
          {run.busy && (
            <button
              type="button"
              className="sd-btn ghost"
              onClick={() => void run.cancel()}
            >
              取消
            </button>
          )}
        </div>
        {run.error !== "" && <div className="sd-alert">{run.error}</div>}
        {run.run !== null && (
          <ul className="sd-run-log">
            {run.run.logs.slice(-8).map((line, index) => (
              <li key={`${index}-${line}`}>{line}</li>
            ))}
          </ul>
        )}
      </div>
    ) : null;

  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>03 定妆 · 图片合成</h2>
          <p>角色形象全季复用；生成后需「采用」才计入工序完成。</p>
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
                  {member.avatar !== null ? (
                    <img
                      className="sd-cast-avatar"
                      src={seriesAssetUrl(
                        bundle.series.series_id,
                        member.avatar.path,
                      )}
                      alt={member.name}
                    />
                  ) : (
                    <div className="sd-cast-avatar empty">未生成</div>
                  )}
                  <b>{member.name}</b>
                  <span>{id}</span>
                  <p>{member.description || "暂无描述"}</p>
                  <small>
                    {member.avatar === null
                      ? "未生成"
                      : member.avatar.approved
                        ? "已采用"
                        : "待采用"}
                  </small>
                </button>
              ))}
            </div>
          </div>

          {selected !== null && (
            <div className="sd-panel">
              <h3>{selected.name}</h3>
              <p className="sd-hint">
                {selected.description || "暂无描述"} · 采用状态：
                {selected.avatar === null
                  ? "未生成"
                  : selected.avatar.approved
                    ? "已采用"
                    : "待采用"}
                {selected.avatar !== null &&
                  ` · 成本 ${formatYuan(selected.avatar.cost_yuan)}`}
              </p>
              <div className="sd-actions">
                <button
                  type="button"
                  className="sd-btn primary"
                  disabled={run.busy}
                  onClick={() => void askEstimate(selected.avatar !== null)}
                >
                  {selected.avatar === null ? "生成定妆" : "重新生成"}
                </button>
                {selected.avatar !== null && !selected.avatar.approved && (
                  <button
                    type="button"
                    className="sd-btn"
                    disabled={approving || run.busy}
                    onClick={() => void approve()}
                  >
                    {approving ? "采用中…" : "采用这张"}
                  </button>
                )}
              </div>
            </div>
          )}

          {error !== "" && <div className="sd-alert">{error}</div>}
          {runPanel}
        </>
      )}

      {estimate !== null && (
        <DramaCostGate
          estimate={estimate}
          busy={run.busy}
          onCancel={() => setEstimate(null)}
          onConfirm={() => void confirmRun()}
        />
      )}
    </section>
  );
}
