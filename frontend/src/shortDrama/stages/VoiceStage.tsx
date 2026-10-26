/// 声音工序：逐句 TTS、实测时长与音频先行回写。
///
/// 生成配音只写 assets/audio；时长回写必须由用户点「应用实测时长」，
/// 回写后已有片段会因 hash 变化显示 stale，不会静默重跑付费产物。
import { useState } from "react";
import { dramaApi } from "../api";
import { episodeAssetUrl } from "../asset";
import { useDramaRun } from "../run";
import type { DramaEstimate, EpisodeBundle } from "../types";
import { formatSeconds } from "../model";
import DramaCostGate from "../DramaCostGate";
import SpeakerStudio from "../../SpeakerStudio";

interface Props {
  bundle: EpisodeBundle;
  onBundle: (bundle: EpisodeBundle) => void;
  onReload: () => void;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

function statusLabel(status: string | undefined): string {
  switch (status) {
    case "succeeded":
      return "已完成";
    case "running":
      return "运行中";
    case "failed":
      return "失败";
    case "stale":
      return "已过期";
    case "interrupted":
      return "已中断";
    default:
      return "待生成";
  }
}

export default function VoiceStage({ bundle, onBundle, onReload }: Props) {
  const shots = bundle.storyboard?.shots ?? [];
  const lines = shots.filter((shot) => shot.line.trim() !== "");
  const [estimate, setEstimate] = useState<DramaEstimate | null>(null);
  const [error, setError] = useState("");
  const [reconciling, setReconciling] = useState(false);
  const run = useDramaRun(
    bundle.series.series_id,
    bundle.episode.episode_id,
    onReload,
  );

  const planDuration = (shotId: string, fallback: number | null) =>
    bundle.plan?.shots.find((item) => item.shot_id === shotId)?.duration_s ??
    fallback ??
    0;

  const diffs = lines
    .map((shot) => {
      const measured = bundle.state.shots[shot.id]?.audio.duration_s;
      if (measured == null) return null;
      const from = planDuration(shot.id, shot.duration_s);
      const to = round1(measured);
      if (Math.abs(to - round1(from)) < 0.1) return null;
      return { shotId: shot.id, from, to };
    })
    .filter((item): item is { shotId: string; from: number; to: number } =>
      item !== null,
    );

  const ask = async () => {
    setError("");
    try {
      const next = await dramaApi.estimate(
        bundle.series.series_id,
        bundle.episode.episode_id,
        { step: "voice" },
      );
      setEstimate(next);
    } catch (cause) {
      setError(messageOf(cause));
    }
  };

  const confirm = async () => {
    setEstimate(null);
    await run.startStep("voice");
  };

  const applyDurations = async () => {
    setReconciling(true);
    setError("");
    try {
      const result = await dramaApi.reconcileAudio(
        bundle.series.series_id,
        bundle.episode.episode_id,
        true,
      );
      if (result.bundle !== undefined) onBundle(result.bundle);
      onReload();
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setReconciling(false);
    }
  };

  const asset = (path: string | null | undefined): string | null =>
    path === null || path === undefined
      ? null
      : episodeAssetUrl(
          bundle.series.series_id,
          bundle.episode.episode_id,
          path,
        );

  const runPanel =
    run.run !== null || run.busy ? (
      <div className="sd-panel sd-run-panel">
        <div className="sd-run-head">
          <b>{run.busy ? "配音生成中…" : "最近一次配音运行"}</b>
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
        {(run.error !== "" || run.run?.error != null) && (
          <div className="sd-alert">{run.error || run.run?.error}</div>
        )}
        {run.run !== null && (
          <ul className="sd-run-log">
            {run.run.logs.slice(-10).map((line, index) => (
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
          <h2>06 声音 · 逐句配音</h2>
          <p>单句 TTS 写入剧集资产；实测时长需你确认后才回写分镜与计划。</p>
        </div>
        <span className="sd-pill">{lines.length} 句</span>
      </header>

      <div className="sd-panel">
        <div className="sd-actions">
          <button
            type="button"
            className="sd-btn primary"
            disabled={run.busy || lines.length === 0}
            onClick={() => void ask()}
          >
            生成全部配音
          </button>
          {diffs.length > 0 && (
            <button
              type="button"
              className="sd-btn"
              disabled={reconciling || run.busy}
              onClick={() => void applyDurations()}
            >
              {reconciling ? "回写中…" : `应用实测时长（${diffs.length} 句）`}
            </button>
          )}
        </div>
        {diffs.length > 0 && (
          <ul className="sd-warnings">
            {diffs.map((diff) => (
              <li key={diff.shotId}>
                {diff.shotId}: 计划 {formatSeconds(diff.from)} → 实测{" "}
                {formatSeconds(diff.to)}；应用后已有片段会显示「已过期」
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="sd-panel">
        <h3>台词</h3>
        {lines.length === 0 ? (
          <p className="sd-empty">还没有台词。先到「分镜」工序补台词。</p>
        ) : (
          <ol className="sd-line-list">
            {lines.map((shot) => {
              const audio = bundle.state.shots[shot.id]?.audio;
              return (
                <li key={shot.id}>
                  <b className="mono">{shot.id}</b>
                  <span>{shot.speaker ?? "—"}</span>
                  <p>「{shot.line}」</p>
                  <small>
                    {statusLabel(audio?.status)}
                    {audio?.duration_s != null &&
                      ` · ${formatSeconds(audio.duration_s)}`}
                    {audio?.error != null && ` · ${audio.error}`}
                  </small>
                  {audio?.path != null && (
                    <audio
                      className="sd-audio-player"
                      controls
                      src={asset(audio.path) ?? ""}
                    />
                  )}
                </li>
              );
            })}
          </ol>
        )}
      </div>

      {error !== "" && <div className="sd-alert">{error}</div>}
      {runPanel}

      <details className="sd-panel">
        <summary>主讲人导读（通用工具，非逐句角色配音）</summary>
        <div className="sd-embed">
          <SpeakerStudio
            initialTheme={lines[0]?.line ?? ""}
            contextLabel="主讲人导读 · 独立任务，不写回剧集"
          />
        </div>
      </details>

      {estimate !== null && (
        <DramaCostGate
          estimate={estimate}
          busy={run.busy}
          onCancel={() => setEstimate(null)}
          onConfirm={() => void confirm()}
        />
      )}
    </section>
  );
}
