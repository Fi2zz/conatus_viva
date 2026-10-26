/// 画面工序：逐镜首帧 / i2v / 本地微动，带时间轴缩略图、缓存与降级。
import { useState } from "react";
import { dramaApi } from "../api";
import { episodeAssetUrl } from "../asset";
import { useDramaRun } from "../run";
import type {
  DramaEstimate,
  DramaArtifact,
  EpisodeBundle,
  StoryboardShot,
} from "../types";
import { formatYuan, routeLabel } from "../model";
import DramaCostGate from "../DramaCostGate";

interface Props {
  bundle: EpisodeBundle;
  selectedShotId: string | null;
  onSelectShot: (id: string) => void;
  onReload: () => void;
}

type Target = "frame" | "clip" | "all";

interface Pending {
  shotId: string | null;
  target: Target;
  force: boolean;
  degrade: boolean;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function statusOf(artifact: DramaArtifact | undefined): string {
  if (artifact === undefined) return "未生成";
  switch (artifact.status) {
    case "succeeded":
      return "已完成";
    case "running":
      return "运行中";
    case "failed":
      return "失败";
    case "stale":
      return "已过期";
    case "skipped":
      return "已跳过";
    case "interrupted":
      return "已中断";
    default:
      return "待生成";
  }
}

export default function FrameStage({
  bundle,
  selectedShotId,
  onSelectShot,
  onReload,
}: Props) {
  const shots = bundle.storyboard?.shots ?? [];
  const selected =
    shots.find((shot) => shot.id === selectedShotId) ?? shots[0] ?? null;
  const selectedState =
    selected === null ? undefined : bundle.state.shots[selected.id];
  const [estimate, setEstimate] = useState<DramaEstimate | null>(null);
  const [pending, setPending] = useState<Pending | null>(null);
  const [error, setError] = useState("");
  const run = useDramaRun(
    bundle.series.series_id,
    bundle.episode.episode_id,
    onReload,
  );

  const ask = async (next: Pending) => {
    setError("");
    try {
      const nextEstimate = await dramaApi.estimate(
        bundle.series.series_id,
        bundle.episode.episode_id,
        {
          step: "frame",
          target: next.target,
          shot_ids: next.shotId === null ? undefined : [next.shotId],
          force: next.force,
          degrade: next.degrade,
        },
      );
      setPending(next);
      setEstimate(nextEstimate);
    } catch (cause) {
      setError(messageOf(cause));
    }
  };

  const confirm = async () => {
    if (pending === null) return;
    const action = pending;
    setEstimate(null);
    setPending(null);
    if (action.shotId === null) {
      await run.startStep("frame", {
        target: action.target,
        force: action.force,
      });
    } else {
      await run.startShot(action.shotId, {
        target: action.target,
        force: action.force,
        degrade: action.degrade,
      });
    }
  };

  const plannedRoute = (shot: StoryboardShot) =>
    bundle.plan?.shots.find((item) => item.shot_id === shot.id)?.route ?? null;
  const planRoute = (shot: StoryboardShot): string => {
    const route = plannedRoute(shot);
    return route === null ? "未生成计划" : routeLabel(route);
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
          <b>{run.busy ? "画面生成中…" : "最近一次画面运行"}</b>
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

  if (shots.length === 0) {
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
          <p>首帧写入剧集资产；i2v 付费，kenburns/micro 本地零费用。</p>
        </div>
        <span className="sd-pill">{shots.length} 镜</span>
      </header>

      <div className="sd-panel">
        <div className="sd-actions">
          <button
            type="button"
            className="sd-btn primary"
            disabled={run.busy}
            onClick={() =>
              void ask({
                shotId: null,
                target: "frame",
                force: false,
                degrade: false,
              })
            }
          >
            生成全部首帧
          </button>
          <button
            type="button"
            className="sd-btn"
            disabled={run.busy || bundle.plan === null}
            onClick={() =>
              void ask({
                shotId: null,
                target: "clip",
                force: false,
                degrade: false,
              })
            }
          >
            生成全部片段
          </button>
          {bundle.plan === null && (
            <span className="sd-hint">先保存分镜表生成计划单，才能生成片段。</span>
          )}
        </div>
      </div>

      <div className="sd-panel">
        <h3>时间轴</h3>
        <div className="sd-shot-strip">
          {shots.map((shot) => {
            const shotState = bundle.state.shots[shot.id];
            const frame = shotState?.frame;
            const clip = shotState?.clip;
            const isT2v = plannedRoute(shot) === "t2v";
            return (
              <button
                type="button"
                key={shot.id}
                className={`sd-shot-chip${shot.id === selected?.id ? " sel" : ""}`}
                onClick={() => onSelectShot(shot.id)}
              >
                {frame?.path != null ? (
                  <img
                    className="sd-shot-thumb"
                    src={asset(frame.path) ?? ""}
                    alt={shot.id}
                  />
                ) : (
                  <div className="sd-shot-thumb empty">
                    {isT2v ? "t2v" : "无首帧"}
                  </div>
                )}
                <b>{shot.id}</b>
                <span>{frame ? statusOf(frame) : "未生成"}</span>
                <small>{clip ? `片段${statusOf(clip)}` : "无片段"}</small>
              </button>
            );
          })}
        </div>
      </div>

      {selected !== null && (
        <div className="sd-panel">
          <h3>
            {selected.id} · {planRoute(selected)}
          </h3>
          <p className="sd-hint">
            {selected.visual ?? selected.line ?? "未填写画面提示词"} · 首帧：
            {statusOf(selectedState?.frame)} · 片段：
            {statusOf(selectedState?.clip)}
          </p>
          <div className="sd-actions">
            {plannedRoute(selected) !== "t2v" && (
              <button
                type="button"
                className="sd-btn"
                disabled={run.busy}
                onClick={() =>
                  void ask({
                    shotId: selected.id,
                    target: "frame",
                    force: false,
                    degrade: false,
                  })
                }
              >
                生成首帧
              </button>
            )}
            <button
              type="button"
              className="sd-btn"
              disabled={run.busy || bundle.plan === null}
              onClick={() =>
                void ask({
                  shotId: selected.id,
                  target: "clip",
                  force: false,
                  degrade: false,
                })
              }
            >
              生成片段
            </button>
            <button
              type="button"
              className="sd-btn"
              disabled={run.busy || bundle.plan === null}
              onClick={() =>
                void ask({
                  shotId: selected.id,
                  target: "all",
                  force: true,
                  degrade: false,
                })
              }
            >
              重跑本镜
            </button>
            <button
              type="button"
              className="sd-btn ghost"
              disabled={run.busy || bundle.plan === null}
              onClick={() =>
                void ask({
                  shotId: selected.id,
                  target: "clip",
                  force: true,
                  degrade: true,
                })
              }
            >
              降级为静帧
            </button>
          </div>
          {selectedState?.clip.path != null && (
            <video
              className="sd-clip-player"
              controls
              src={asset(selectedState.clip.path) ?? ""}
            />
          )}
          {selectedState?.frame.cost_yuan != null && (
            <p className="sd-hint">
              本镜已花：首帧 {formatYuan(selectedState.frame.cost_yuan)} · 片段{" "}
              {formatYuan(selectedState.clip.cost_yuan ?? 0)}
            </p>
          )}
        </div>
      )}

      {error !== "" && <div className="sd-alert">{error}</div>}
      {runPanel}

      {estimate !== null && (
        <DramaCostGate
          estimate={estimate}
          busy={run.busy}
          onCancel={() => {
            setEstimate(null);
            setPending(null);
          }}
          onConfirm={() => void confirm()}
        />
      )}
    </section>
  );
}
