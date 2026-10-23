import { useCallback, useEffect, useRef, useState } from "react";
import "./shortDrama/ShortDrama.css";
import {
  costByRoute,
  formatSeconds,
  formatYuan,
  hookShots,
  routeLabel,
  timelineBlocks,
  type Plan,
  type PlanShot,
  type ShotKind,
} from "./shortDrama/model";
import {
  DAG_BANNER,
  DAG_EDGES,
  DAG_NODES,
  DAG_NODE_H,
  DAG_NODE_W,
  dagNodeMeta,
  type DagNode,
} from "./shortDrama/pipelineDag";

/// 镜头类型的展示标签（仅 UI 文案，不参与任何计算）。
const KIND_LABELS: Record<ShotKind, string> = {
  speak_off: "画外音",
  insert: "插入",
  listen_face: "反应·听",
  action: "动作",
  establishing: "定场",
};

type View = "prod" | "canvas";

/// 拉取计划单的原始结果（模块级，不含任何 setState，便于在 effect 里用
/// `.then` 链消费，避免同步 setState）。
type PlanResult =
  | { ok: true; plan: Plan }
  | { ok: false; kind: "not-found"; id: string }
  | { ok: false; kind: "http"; status: number; message?: string }
  | { ok: false; kind: "network" };

async function requestPlan(id: string): Promise<PlanResult> {
  try {
    const res = await fetch(`/api/short-drama/plans/${encodeURIComponent(id)}`);
    if (res.status === 404) return { ok: false, kind: "not-found", id };
    if (!res.ok) {
      const data = (await res.json().catch(() => ({}))) as { error?: string };
      return { ok: false, kind: "http", status: res.status, message: data.error };
    }
    return { ok: true, plan: (await res.json()) as Plan };
  } catch (e) {
    console.error("Failed to load short-drama plan:", e);
    return { ok: false, kind: "network" };
  }
}

/// 短剧工作台：产线视图（真实计划单数据）+ 画布视图（设计预览）。
///
/// 数据来自 `GET /api/short-drama/plans/<content_id>`（只读），本组件不发起
/// 任何付费操作；画布视图只展示静态工序 DAG，不编造运行时状态 / 成本。
export default function ShortDrama() {
  const [id, setId] = useState("ep07");
  const [plan, setPlan] = useState<Plan | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [view, setView] = useState<View>("prod");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  /// 请求序号：单调递增，用于丢弃迟到的旧响应，避免并发加载串台。
  const requestSeq = useRef(0);

  const applyResult = useCallback((targetId: string, r: PlanResult) => {
    if (r.ok) {
      setPlan(r.plan);
    } else if (r.kind === "not-found") {
      setError(
        `未找到计划单「${targetId}」，请先用 CLI 生成 pipeline_out/${targetId}/07_plan.json`,
      );
    } else if (r.kind === "network") {
      setError("加载计划单失败，请确认本地服务已启动");
    } else {
      setError(r.message ? `加载失败：${r.message}` : `加载失败（HTTP ${r.status}）`);
    }
  }, []);

  const load = useCallback(
    (targetId: string) => {
      const trimmed = targetId.trim();
      if (trimmed === "") {
        setError("请输入 content_id");
        setLoading(false);
        return;
      }
      // 抢占当前请求序号：只有最新一次请求的结果 / 收尾才允许落地状态，
      // 迟到的旧响应（含 setLoading(false)）会被丢弃，避免串台。
      const seq = ++requestSeq.current;
      setLoading(true);
      setError("");
      setPlan(null);
      setSelectedId(null);
      void requestPlan(trimmed)
        .then((r) => {
          if (seq !== requestSeq.current) return;
          applyResult(trimmed, r);
        })
        .finally(() => {
          if (seq === requestSeq.current) setLoading(false);
        });
    },
    [applyResult],
  );

  // 自动加载默认 content_id（复用带序号守卫的 load，避免双请求路径）。
  // 通过微任务推迟到 effect 返回后执行，避免同步 setState 触发 react 告警。
  useEffect(() => {
    queueMicrotask(() => void load("ep07"));
  }, [load]);

  const selected = selectedId
    ? (plan?.shots.find((s) => s.shot_id === selectedId) ?? null)
    : null;

  return (
    <div className="short-drama">
      <div className="sd-toolbar">
        <label className="sd-id">
          content_id
          <input
            value={id}
            onChange={(e) => setId(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") void load(id.trim());
            }}
            placeholder="ep07"
          />
        </label>
        <button
          type="button"
          className="sd-load"
          disabled={loading}
          onClick={() => void load(id.trim())}
        >
          {loading ? "加载中…" : "加载"}
        </button>

        <div className="sd-view-toggle" role="tablist">
          <button
            type="button"
            className={view === "prod" ? "active" : ""}
            onClick={() => setView("prod")}
          >
            产线视图
          </button>
          <button
            type="button"
            className={view === "canvas" ? "active" : ""}
            onClick={() => setView("canvas")}
          >
            画布视图
          </button>
        </div>
      </div>

      {loading && <div className="sd-status">正在加载计划单…</div>}

      {!loading && error && <div className="sd-error">{error}</div>}

      {!loading && !error && plan && view === "prod" && (
        <ProductionView
          plan={plan}
          selected={selected}
          onSelect={(s) => setSelectedId(s.shot_id)}
        />
      )}

      {!loading && !error && plan && view === "canvas" && (
        <CanvasView plan={plan} />
      )}
    </div>
  );
}

/// 产线视图：hook 条、等比例时间轴、选镜检视、成本构成与告警。
function ProductionView(props: {
  plan: Plan;
  selected: PlanShot | null;
  onSelect: (shot: PlanShot) => void;
}) {
  const { plan, selected, onSelect } = props;
  const blocks = timelineBlocks(plan.shots);
  const total = plan.shots.reduce((acc, s) => acc + s.duration_s, 0);
  const hook = hookShots(plan.shots);
  const routeCost = costByRoute(plan.shots);
  const pct =
    plan.budget_yuan > 0
      ? Math.min(100, (plan.totals.estimated_yuan / plan.budget_yuan) * 100)
      : 0;

  return (
    <div className="sd-prod">
      <header className="sd-plan-head">
        <h2>{plan.title || plan.content_id}</h2>
        <p className="sd-meta">
          {plan.content_id} · 画幅 {plan.frame.width}×{plan.frame.height} · 共{" "}
          {plan.shots.length} 镜 · {formatSeconds(plan.totals.duration_s)}
        </p>
        <div className="sd-budget">
          <div className="sd-budget-label">
            <span>预估成本</span>
            <span>
              {formatYuan(plan.totals.estimated_yuan)} /{" "}
              {formatYuan(plan.budget_yuan)}
            </span>
          </div>
          <div className="sd-budget-bar">
            <i style={{ width: `${pct}%` }} />
          </div>
        </div>
      </header>

      {plan.shots.length === 0 ? (
        <div className="sd-empty">
          暂无镜头数据，请先运行 CLI 生成计划单（pipeline_out/&lt;content_id&gt;/07_plan.json）。
        </div>
      ) : (
        <div className="sd-prod-body">
          <div className="sd-prod-main">
            <section className="sd-hook">
              <h3>前 3 秒 hook</h3>
              <div className="sd-hook-row">
                {hook.map((s) => (
                  <button
                    type="button"
                    key={s.shot_id}
                    className="sd-chip"
                    onClick={() => onSelect(s)}
                  >
                    {s.shot_id}
                    <span>{formatSeconds(s.duration_s)}</span>
                  </button>
                ))}
              </div>
            </section>

            <section className="sd-timeline">
              <h3>时间轴</h3>
              <div className="sd-timeline-bar">
                {blocks.map((b) => (
                  <button
                    type="button"
                    key={b.shot.shot_id}
                    className={`sd-block route-${b.shot.route}${
                      selected?.shot_id === b.shot.shot_id ? " selected" : ""
                    }`}
                    style={{ width: `${(b.width / total) * 100}%` }}
                    onClick={() => onSelect(b.shot)}
                    title={`${b.shot.shot_id} · ${routeLabel(b.shot.route)}`}
                  >
                    <span className="sd-block-id">{b.shot.shot_id}</span>
                    <span className="sd-block-route">
                      {routeLabel(b.shot.route)}
                    </span>
                    <span className="sd-block-nums">
                      {b.shot.i2v_seconds > 0
                        ? `i2v ${b.shot.i2v_seconds}s · `
                        : ""}
                      {formatYuan(b.shot.cost_yuan)}
                    </span>
                  </button>
                ))}
              </div>
              <div className="sd-lines">
                {plan.shots.map(
                  (s) =>
                    s.line.trim() !== "" && (
                      <div key={s.shot_id} className="sd-line">
                        <span className="sd-line-id">{s.shot_id}</span>
                        「{s.line}」
                      </div>
                    ),
                )}
              </div>
            </section>
          </div>

          <aside className="sd-inspect">
            {selected ? (
              <>
                <h3>镜头检视</h3>
                <dl className="sd-kv">
                  <dt>类型</dt>
                  <dd>{KIND_LABELS[selected.kind]}</dd>
                  <dt>景别</dt>
                  <dd>{selected.framing}</dd>
                  <dt>发言</dt>
                  <dd>{selected.speaker ?? "—"}</dd>
                  <dt>台词</dt>
                  <dd>{selected.line.trim() === "" ? "无台词" : selected.line}</dd>
                  <dt>路由</dt>
                  <dd>{routeLabel(selected.route)}</dd>
                  <dt>时长</dt>
                  <dd>{formatSeconds(selected.duration_s)}</dd>
                  <dt>i2v</dt>
                  <dd>{selected.i2v_seconds}s</dd>
                  <dt>成本</dt>
                  <dd>{formatYuan(selected.cost_yuan)}</dd>
                  <dt>降级</dt>
                  <dd>{selected.downgrade_reason ?? "无"}</dd>
                  <dt>头像</dt>
                  <dd>{selected.avatar ? "是" : "否"}</dd>
                </dl>
              </>
            ) : (
              <div className="sd-inspect-empty">点击时间轴上的镜头查看详情</div>
            )}

            <h3>成本构成</h3>
            <dl className="sd-kv">
              <dt>静帧推拉</dt>
              <dd>{formatYuan(routeCost.kenburns)}</dd>
              <dt>局部微动</dt>
              <dd>{formatYuan(routeCost.micro)}</dd>
              <dt>图生视频</dt>
              <dd>{formatYuan(routeCost.i2v)}</dd>
            </dl>

            <h3>告警</h3>
            {plan.warnings.length === 0 ? (
              <div className="sd-warn-none">无</div>
            ) : (
              <ul className="sd-warnings">
                {plan.warnings.map((w) => (
                  <li key={w}>{w}</li>
                ))}
              </ul>
            )}
          </aside>
        </div>
      )}
    </div>
  );
}

/// 画布视图：静态 8 工序 DAG，仅分镜 / 画面派生数字，其余「未接入」。
function CanvasView({ plan }: { plan: Plan }) {
  const byKey = new Map(DAG_NODES.map((n) => [n.key, n]));
  const paths = DAG_EDGES.map((e) => ({
    key: `${e.from}-${e.to}`,
    d: edgePath(byKey.get(e.from)!, byKey.get(e.to)!),
  }));

  return (
    <div className="sd-canvas">
      <div className="sd-canvas-banner">{DAG_BANNER}</div>
      <div className="sd-canvas-scroll">
        <div className="sd-canvas-board">
          <svg
            className="sd-canvas-svg"
            width={850}
            height={390}
            viewBox="0 0 850 390"
          >
            {paths.map((p) => (
              <path key={p.key} className="sd-edge" d={p.d} />
            ))}
          </svg>
          {DAG_NODES.map((n) => (
            <NodeCard key={n.key} node={n} plan={plan} />
          ))}
        </div>
      </div>
    </div>
  );
}

function NodeCard({ node, plan }: { node: DagNode; plan: Plan }) {
  return (
    <div
      className="sd-node"
      style={{ left: node.x, top: node.y, width: DAG_NODE_W, height: DAG_NODE_H }}
    >
      <span className="sd-node-idx">{node.idx}</span>
      <span className="sd-node-name">{node.name}</span>
      <span className="sd-node-meta">{dagNodeMeta(node.key, plan)}</span>
    </div>
  );
}

type Side = "l" | "r" | "t" | "b";

function anchorOf(n: DagNode, side: Side): { x: number; y: number } {
  if (side === "l") return { x: n.x, y: n.y + DAG_NODE_H / 2 };
  if (side === "r") return { x: n.x + DAG_NODE_W, y: n.y + DAG_NODE_H / 2 };
  if (side === "t") return { x: n.x + DAG_NODE_W / 2, y: n.y };
  return { x: n.x + DAG_NODE_W / 2, y: n.y + DAG_NODE_H };
}

function edgePath(a: DagNode, b: DagNode): string {
  let as: Side;
  let bs: Side;
  if (a.x < b.x) {
    as = "r";
    bs = "l";
  } else if (a.x > b.x) {
    as = "l";
    bs = "r";
  } else {
    as = a.y < b.y ? "b" : "t";
    bs = a.y < b.y ? "t" : "b";
  }
  const p = anchorOf(a, as);
  const q = anchorOf(b, bs);
  if (as === "r" || bs === "l") {
    const half = Math.max(18, Math.abs(q.x - p.x) / 2);
    return `M${p.x} ${p.y} C${p.x + half} ${p.y} ${q.x - half} ${q.y} ${q.x} ${q.y}`;
  }
  const h2 = Math.max(20, Math.abs(q.y - p.y) / 2);
  return `M${p.x} ${p.y} C${p.x} ${p.y + h2} ${q.x} ${q.y - h2} ${q.x} ${q.y}`;
}
