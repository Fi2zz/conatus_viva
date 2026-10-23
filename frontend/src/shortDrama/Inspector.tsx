/// 右栏检视：选中镜头或工序的真实数据；P1 不提供伪造的运行状态。
import type { PlanShot, ShotKind } from "./model";
import { formatSeconds, formatYuan, routeLabel } from "./model";
import type { StoryboardShot, StepView } from "./types";
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
}

export default function Inspector({ step, shot, planShot }: Props) {
  return (
    <aside className="sd-inspector">
      <div className="sd-insp-head">
        <span>检视</span>
        <b>{shot?.id ?? `STEP ${step.key.toUpperCase()}`}</b>
      </div>

      {shot ? (
        <>
          <div className="sd-insp-preview">
            <div className="sd-frame">
              <span>首帧</span>
              <small>{shot.framing} · 9:16</small>
            </div>
            <div>
              <h3>{KIND_LABELS[shot.kind]}</h3>
              <p>{shot.line.trim() === "" ? "无台词" : `「${shot.line}」`}</p>
              <div className="sd-tags">
                <span>{shot.framing}</span>
                <span>{shot.speaker ?? "—"}</span>
                <span className={planShot?.route === "i2v" ? "hot" : ""}>
                  {planShot ? routeLabel(planShot.route) : "未生成"}
                </span>
                <span className="miss">P1 未接入缓存</span>
              </div>
            </div>
          </div>

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
              <dt>本镜成本</dt>
              <dd className="mono">{planShot ? formatYuan(planShot.cost_yuan) : "—"}</dd>
            </div>
          </dl>

          <div className="sd-note">
            时长与成本来自计划单；P2 才会写入首帧/视频产物并支持重跑。
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
