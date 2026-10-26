/// 打包工序：成片、字幕、封面与 package.json 清单。
import { useState } from "react";
import { episodeOutUrl } from "../asset";
import { useDramaRun } from "../run";
import type { EpisodeBundle } from "../types";

interface Props {
  bundle: EpisodeBundle;
  onReload: () => void;
}

const FILES: { name: string; label: string }[] = [
  { name: "final.mp4", label: "成片 MP4" },
  { name: "final.srt", label: "字幕 SRT" },
  { name: "cover.png", label: "封面 PNG" },
  { name: "package.json", label: "清单 JSON" },
];

export default function PackStage({ bundle, onReload }: Props) {
  const [error, setError] = useState("");
  const run = useDramaRun(
    bundle.series.series_id,
    bundle.episode.episode_id,
    onReload,
  );
  const step = bundle.steps.find((item) => item.key === "pack");
  const ready = step?.status === "succeeded";

  const start = async () => {
    setError("");
    try {
      await run.startStep("pack");
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    }
  };

  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>08 打包</h2>
          <p>导出成片、字幕、封面与投放清单；多版本留给后续。</p>
        </div>
        <span className="sd-pill">{ready ? "已打包" : "待打包"}</span>
      </header>

      {!ready ? (
        <div className="sd-panel">
          <p className="sd-hint">
            打包前需要成片与字幕已完成；音频回写后请先重新合成。
          </p>
          <div className="sd-actions">
            <button
              type="button"
              className="sd-btn primary"
              disabled={run.busy}
              onClick={() => void start()}
            >
              {run.busy ? "打包中…" : "生成投放包"}
            </button>
          </div>
        </div>
      ) : (
        <div className="sd-panel">
          <h3>投放包</h3>
          <ul className="sd-line-list">
            {FILES.map((file) => (
              <li key={file.name}>
                <b className="mono">{file.name}</b>
                <span>{file.label}</span>
                <a
                  className="sd-btn"
                  href={episodeOutUrl(
                    bundle.series.series_id,
                    bundle.episode.episode_id,
                    file.name,
                  )}
                  download
                >
                  下载
                </a>
              </li>
            ))}
          </ul>
          <div className="sd-actions">
            <button
              type="button"
              className="sd-btn ghost"
              disabled={run.busy}
              onClick={() => void start()}
            >
              重新打包
            </button>
          </div>
        </div>
      )}

      {(run.error !== "" || run.run?.error != null) && (
        <div className="sd-alert">{run.error || run.run?.error}</div>
      )}
      {error !== "" && <div className="sd-alert">{error}</div>}
      {run.run !== null && (
        <div className="sd-panel sd-run-panel">
          <ul className="sd-run-log">
            {run.run.logs.slice(-10).map((line, index) => (
              <li key={`${index}-${line}`}>{line}</li>
            ))}
          </ul>
        </div>
      )}
    </section>
  );
}
