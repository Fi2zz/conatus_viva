/// 右栏检视：选中镜头或工序的真实数据；P1 不提供伪造的运行状态。
import type { PlanShot, ShotKind } from "./model";
import { formatSeconds, formatYuan, routeLabel } from "./model";
import { episodeAssetUrl } from "./asset";
import type { DramaShotState, StoryboardShot, StepView } from "./types";
import { stepStatusLabel } from "./view";

const KIND_LABELS: Record<ShotKind, string> = {
  speak_off: "画外音",
  insert: "插入",
  listen_face: "反应·听",
  action: "动作",
  establishing: "定场",
};

interface Props {
  step: StepView;
  shot: StoryboardShot | null;
  planShot: PlanShot | null;
  shotState: DramaShotState | null;
  seriesId: string;
  episodeId: string;
}

export default function Inspector({
  step,
  shot,
  planShot,
  shotState,
  seriesId,
  episodeId,
}: Props) {
  const asset = (path: string | null | undefined): string | null =>
    path === null || path === undefined
      ? null
      : episodeAssetUrl(seriesId, episodeId, path);
  return (
    <aside className="sd-inspector">
      <div className="sd-insp-head">
        <span>检视</span>
        <b>{shot?.id ?? `STEP ${step.key.toUpperCase()}`}</b>
      </div>

      {shot ? (
        <>
          <div className="sd-insp-preview">
            {shotState?.frame.path ? (
              <img
                className="sd-frame-img"
                src={asset(shotState.frame.path) ?? ""}
                alt={`${shot.id} 首帧`}
              />
            ) : (
              <div className="sd-frame">
                <span>首帧</span>
                <small>{shot.framing} · 9:16</small>
              </div>
            )}
            <div>
              <h3>{KIND_LABELS[shot.kind]}</h3>
              <p>{shot.line.trim() === "" ? "无台词" : `「${shot.line}」`}</p>
              <div className="sd-tags">
                <span>{shot.framing}</span>
                <span>{shot.speaker ?? "—"}</span>
                <span className={planShot?.route === "i2v" ? "hot" : ""}>
                  {planShot ? routeLabel(planShot.route) : "未生成"}
                </span>
                <span className={shotState?.clip.status === "succeeded" ? "" : "miss"}>
                  {shotState?.clip.status === "succeeded"
                    ? "片段已生成"
                    : "片段未完成"}
                </span>
              </div>
            </div>
          </div>

          {shotState?.clip.path && (
            <video
              className="sd-insp-video"
              controls
              src={asset(shotState.clip.path) ?? ""}
            />
          )}

          <dl className="sd-kv">
            <div>
              <dt>镜号</dt>
              <dd className="mono">{shot.id}</dd>
            </div>
            <div>
              <dt>时长</dt>
              <dd>{planShot ? formatSeconds(planShot.duration_s) : "未生成计划"}</dd>
            </div>
            <div>
              <dt>台词</dt>
              <dd>{shot.line.trim() === "" ? "—" : shot.line}</dd>
            </div>
            <div>
              <dt>画面</dt>
              <dd>{shot.visual ?? "—"}</dd>
            </div>
            <div>
              <dt>运动</dt>
              <dd>{shot.motion ?? "—"}</dd>
            </div>
            <div>
              <dt>首帧状态</dt>
              <dd>{shotState?.frame.status ?? "待生成"}</dd>
            </div>
            <div>
              <dt>片段状态</dt>
              <dd>{shotState?.clip.status ?? "待生成"}</dd>
            </div>
            <div>
              <dt>本镜成本</dt>
              <dd className="mono">
                {formatYuan(
                  (shotState?.frame.cost_yuan ?? 0) +
                    (shotState?.clip.cost_yuan ?? 0),
                )}
              </dd>
            </div>
          </dl>

          <div className="sd-note">
            首帧/片段来自本集 state.json；hash 不一致会显示「已过期」，重跑不会重复扣费。
          </div>
        </>
      ) : (
        <>
          <div className="sd-insp-step">
            <h3>{step.key}</h3>
            <p>{step.summary}</p>
            <div className="sd-tags">
              <span>{stepStatusLabel(step)}</span>
              <span>{step.wired ? "已接入" : "未接入"}</span>
            </div>
          </div>
          <dl className="sd-kv">
            <div>
              <dt>累计成本</dt>
              <dd className="mono">{formatYuan(step.cost_yuan)}</dd>
            </div>
            <div>
              <dt>产出</dt>
              <dd>{step.summary}</dd>
            </div>
            <div>
              <dt>错误</dt>
              <dd>{step.detail.trim() === "" ? "无" : step.detail}</dd>
            </div>
          </dl>
          <div className="sd-note">
            P1 只建立状态与创作闭环；未接入工序不会显示假进度或假成本。
          </div>
        </>
      )}
    </aside>
  );
}
