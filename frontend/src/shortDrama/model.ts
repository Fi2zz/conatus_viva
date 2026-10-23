/// 短剧工作台的数据模型与纯函数（无 React / 无 IO）。
///
/// 类型对应后端 `GET /api/short-drama/plans/<content_id>` 返回的 `07_plan.json`
/// （`render_plan.dart` 的 wire 格式，snake_case）。这里的纯函数只做展示层计算，
/// 不发明状态或成本：一切数字都来自计划单本身。

export type ShotRoute = "kenburns" | "micro" | "i2v";
export type ShotKind = "speak_off" | "insert" | "listen_face" | "action" | "establishing";
export type ShotPriority = "hook" | "turn" | "payoff" | "normal";

export interface PlanShot {
  shot_id: string;
  kind: ShotKind;
  route: ShotRoute;
  avatar: boolean;
  duration_s: number;
  i2v_seconds: number;
  cost_yuan: number;
  downgrade_reason: string | null;
  framing: string;
  speaker: string | null;
  line: string;
  priority: ShotPriority;
}

export interface PlanTotals {
  duration_s: number;
  i2v_seconds: number;
  estimated_yuan: number;
  remaining_yuan: number;
}

export interface PlanFrame {
  width: number;
  height: number;
}

export interface I2vGeneration {
  model: string;
  resolution: string;
  width: number;
  height: number;
}

export interface Plan {
  content_id: string;
  title: string;
  frame: PlanFrame;
  i2v_generation: I2vGeneration;
  budget_yuan: number;
  price_yuan_per_second: number;
  max_i2v_seconds: number;
  shots: PlanShot[];
  totals: PlanTotals;
  counts: Record<ShotRoute, number>;
  warnings: string[];
}

/// 前 `seconds` 秒的 hook 镜：按 `duration_s` 累计，直到累计时长 `>= seconds`
/// （含把累计推过线的那个「跨越镜」）。空输入返回 `[]`。
export function hookShots(shots: PlanShot[], seconds = 3): PlanShot[] {
  const out: PlanShot[] = [];
  let acc = 0;
  for (const s of shots) {
    out.push(s);
    acc += s.duration_s;
    if (acc >= seconds) break;
  }
  return out;
}

/// 时间轴铺镜：按输入顺序累加起始时间，每块宽度等于该镜 `duration_s`。
export function timelineBlocks(
  shots: PlanShot[],
): { shot: PlanShot; start: number; width: number }[] {
  const out: { shot: PlanShot; start: number; width: number }[] = [];
  let start = 0;
  for (const s of shots) {
    out.push({ shot: s, start, width: s.duration_s });
    start += s.duration_s;
  }
  return out;
}

/// 三条路由的成本构成，缺省键恒为零（不因无该路由镜头而缺键）。
export function costByRoute(shots: PlanShot[]): Record<ShotRoute, number> {
  const out: Record<ShotRoute, number> = { kenburns: 0, micro: 0, i2v: 0 };
  for (const s of shots) out[s.route] += s.cost_yuan;
  return out;
}

/// 路由 → 中文标签。
export function routeLabel(route: ShotRoute): string {
  switch (route) {
    case "kenburns":
      return "静帧推拉";
    case "micro":
      return "局部微动";
    case "i2v":
      return "图生视频";
  }
}

/// 金额：`¥` + 两位小数。
export function formatYuan(v: number): string {
  return `¥${v.toFixed(2)}`;
}

/// 时长：一位小数 + `s`。
export function formatSeconds(v: number): string {
  return `${v.toFixed(1)}s`;
}
