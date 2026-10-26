/// 剪辑工序：本地 ffmpeg 合成竖屏成片与同名 SRT。
import { useState } from "react";
import { episodeOutUrl } from "../asset";
import { useDramaRun } from "../run";
import type { EpisodeBundle } from "../types";
import EditCostEstimator from "../../EditCostEstimator";

interface Props {
  bundle: EpisodeBundle;
  onReload: () => void;
}

export default function EditStage({ bundle, onReload }: Props) {
  const [error, setError] = useState("");
  const run = useDramaRun(
    bundle.series.series_id,
    bundle.episode.episode_id,
    onReload,
  );
  const editStep = bundle.steps.find((step) => step.key === "edit");
  const ready = editStep?.status === "succeeded";
  const finalUrl = episodeOutUrl(
    bundle.series.series_id,
    bundle.episode.episode_id,
    "final.mp4",
  );
  const srtUrl = episodeOutUrl(
    bundle.series.series_id,
    bundle.episode.episode_id,
    "final.srt",
  );

  const start = async () => {
    setError("");
    try {
      await run.startStep("edit");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    }
  };

  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>07 剪辑 · 竖屏合成</h2>
          <p>本地 ffmpeg 合成，零外部费用；失败可直接重试，不重复扣费。</p>
        </div>
        <span className="sd-pill">{ready ? "已合成" : "待合成"}</span>
      </header>

      {!ready ? (
        <div className="sd-panel">
          <p className="sd-hint">
            合成前需要：画面全部完成、台词配音全部完成。时长回写后已有成片会显示「已过期」。
          </p>
          <div className="sd-actions">
            <button
              type="button"
              className="sd-btn primary"
              disabled={run.busy}
              onClick={() => void start()}
            >
              {run.busy ? "合成中…" : "合成竖屏成片"}
            </button>
          </div>
        </div>
      ) : (
        <div className="sd-panel">
          <h3>成片</h3>
          <video className="sd-clip-player" controls src={finalUrl} />
          <div className="sd-actions">
            <a className="sd-btn" href={srtUrl} download>
              下载 SRT
            </a>
            <button
              type="button"
              className="sd-btn ghost"
              disabled={run.busy}
              onClick={() => void start()}
            >
              重新合成
            </button>
          </div>
        </div>
      )}

      {(run.error !== "" || run.run?.error != null) && (
        <div className="sd-alert">{run.error || run.run?.error}</div>
      )}
      {run.busy && run.run === null && (
        <div className="sd-hint">正在准备合成…</div>
      )}
      {run.run !== null && (
        <div className="sd-panel sd-run-panel">
          <ul className="sd-run-log">
            {run.run.logs.slice(-10).map((line, index) => (
              <li key={`${index}-${line}`}>{line}</li>
            ))}
          </ul>
        </div>
      )}
      {error !== "" && <div className="sd-alert">{error}</div>}

      <details className="sd-panel">
        <summary>编辑模型成本对比（只读）</summary>
        <div className="sd-embed">
          <EditCostEstimator />
        </div>
      </details>
    </section>
  );
}
