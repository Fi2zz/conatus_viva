/// 渲染计划单：路由选择、时长解析、预算分配与确定性序列化（纯 Dart，无 Flutter 依赖）。
///
/// 输入是 [Storyboard]（分镜表），输出是 [RenderPlan]（每镜走哪条渲染路由、
/// 买多少 i2v 秒数、花多少钱、哪些被预算降级）。本模块只做纯函数计算，
/// 不读配置、不发网络、不碰 ffmpeg。
///
/// 单价 [buildRenderPlan.priceYuanPerSecond] 由调用方传入（必传，无默认值）；
/// 定价事实源在 `generation_models.dart`，这里不硬编码价格。
///
/// 序列化是 canonical idempotent，wire name 一律 snake_case。
library;

import 'frame.dart';
import 'storyboard.dart';

/// 单镜渲染路由。
enum ShotRoute { kenburns, micro, i2v }

/// 计划单固定使用的 i2v 生成参数（输出为 `i2v_generation` 对象）。
const String kPlanI2vModel = 'wan2.6-i2v-flash';
const String kPlanI2vResolution = '720P';
const int kPlanI2vWidth = 720;
const int kPlanI2vHeight = 1280;

/// `ShotPriority` → 排序权重。不能依赖枚举声明顺序（声明序是
/// hook,turn,payoff,normal，权重是 hook=0,payoff=1,turn=2,normal=3），
/// 用 switch 显式映射。
int priorityRank(ShotPriority priority) {
  switch (priority) {
    case ShotPriority.hook:
      return 0;
    case ShotPriority.payoff:
      return 1;
    case ShotPriority.turn:
      return 2;
    case ShotPriority.normal:
      return 3;
  }
}

/// 单镜时长解析（公开，供测试直接调用）。
///
/// - 显式 [Shot.durationS]（解析阶段已保证有限且 >0）：`<0.8` 夹到 0.8 记
///   `duration_raised:<id>`，`>30` 夹到 30 记 `duration_clamped:<id>`，结果用
///   `_round1`（四舍五入到一位小数）。
/// - 缺省：按台词估算；空台词 `2.0`，否则
///   `ceil1(clamp(chars / 4.5, 1.2, 30.0))`（向上取整到一位小数，例如
///   11 runes → `11/4.5 = 2.444…` → 2.5）。
double resolveDuration(Shot shot, List<String> warnings) {
  final explicit = shot.durationS;
  if (explicit != null) {
    var d = explicit;
    if (d < 0.8) {
      warnings.add('duration_raised:${shot.id}');
      d = 0.8;
    }
    if (d > 30) {
      warnings.add('duration_clamped:${shot.id}');
      d = 30.0;
    }
    return _round1(d);
  }

  final chars = shot.line.trim().runes.length;
  if (chars == 0) return 2.0;
  final estimate = (chars / 4.5).clamp(1.2, 30.0).toDouble();
  return _ceil1(estimate);
}

/// 单个镜头的计划结果。
///
/// `framing` / `speaker` / `line` / `priority` 是从 [Storyboard] 的 [Shot]
/// 原样透传的 UI 展示字段（不参与路由、预算与计费计算）。
class PlannedShot {
  const PlannedShot({
    required this.shotId,
    required this.kind,
    required this.route,
    required this.avatar,
    required this.durationS,
    required this.i2vSeconds,
    required this.costYuan,
    required this.framing,
    this.speaker,
    required this.line,
    required this.priority,
    this.downgradeReason,
  });

  final String shotId;
  final ShotKind kind;
  final ShotRoute route;
  final bool avatar;
  final double durationS;
  final int i2vSeconds;
  final double costYuan;
  final String? downgradeReason;

  /// 景别，解析阶段缺省为 `unknown`。
  final String framing;

  /// 发言角色 id；无发言角色时为 null。
  final String? speaker;

  /// 台词，允许空串。
  final String line;

  /// 镜头优先级；wire name 见 [shotPriorityToWire]。
  final ShotPriority priority;

  Map<String, Object?> toJson() => <String, Object?>{
    'shot_id': shotId,
    'kind': shotKindToWire(kind),
    'route': route.name,
    'avatar': avatar,
    'duration_s': durationS,
    'i2v_seconds': i2vSeconds,
    'cost_yuan': costYuan,
    'downgrade_reason': downgradeReason,
    'framing': framing,
    'speaker': speaker,
    'line': line,
    'priority': shotPriorityToWire(priority),
  };
}

/// 计划单汇总。
class PlanTotals {
  const PlanTotals({
    required this.durationS,
    required this.i2vSeconds,
    required this.estimatedYuan,
    required this.remainingYuan,
  });

  final double durationS;
  final int i2vSeconds;
  final double estimatedYuan;
  final double remainingYuan;

  Map<String, Object?> toJson() => <String, Object?>{
    'duration_s': durationS,
    'i2v_seconds': i2vSeconds,
    'estimated_yuan': estimatedYuan,
    'remaining_yuan': remainingYuan,
  };
}

/// 渲染计划单。
class RenderPlan {
  const RenderPlan({
    required this.contentId,
    required this.title,
    required this.frame,
    required this.budgetYuan,
    required this.priceYuanPerSecond,
    required this.maxI2vSeconds,
    required this.shots,
    required this.totals,
    required this.counts,
    required this.warnings,
  });

  final String contentId;
  final String title;
  final FrameSize frame;
  final double budgetYuan;
  final double priceYuanPerSecond;
  final int maxI2vSeconds;
  final List<PlannedShot> shots;
  final PlanTotals totals;

  /// 三键计数，固定顺序 `kenburns` / `micro` / `i2v`（零值也保留）。
  final Map<String, int> counts;
  final List<String> warnings;

  Map<String, Object?> toJson() => <String, Object?>{
    'content_id': contentId,
    'title': title,
    'frame': frame.toJson(),
    'i2v_generation': <String, Object?>{
      'model': kPlanI2vModel,
      'resolution': kPlanI2vResolution,
      'width': kPlanI2vWidth,
      'height': kPlanI2vHeight,
    },
    'budget_yuan': budgetYuan,
    'price_yuan_per_second': priceYuanPerSecond,
    'max_i2v_seconds': maxI2vSeconds,
    'shots': <Object?>[for (final shot in shots) shot.toJson()],
    'totals': totals.toJson(),
    'counts': <String, int>{
      'kenburns': counts['kenburns'] ?? 0,
      'micro': counts['micro'] ?? 0,
      'i2v': counts['i2v'] ?? 0,
    },
    'warnings': warnings,
  };
}

/// i2v 单镜秒数的夹紧边界（`need` 夹紧与 `i2v_min_duration_raised` /
/// `i2v_capped` 判定共用，避免魔法数字散落）。
const int _i2vMinSeconds = 2;
const int _i2vMaxSeconds = 10;

/// 构建渲染计划单（纯函数，确定性）。
RenderPlan buildRenderPlan({
  required Storyboard storyboard,
  required double priceYuanPerSecond,
  double? budgetYuan,
  int maxI2vSeconds = 0,
}) {
  if (!priceYuanPerSecond.isFinite || priceYuanPerSecond <= 0) {
    throw ArgumentError('priceYuanPerSecond 必须是有限正数：$priceYuanPerSecond');
  }
  if (budgetYuan != null && (!budgetYuan.isFinite || budgetYuan <= 0)) {
    throw ArgumentError('budgetYuan 必须是有限正数：$budgetYuan');
  }
  if (maxI2vSeconds < 0) {
    throw ArgumentError('maxI2vSeconds 必须 >= 0：$maxI2vSeconds');
  }

  final budget = budgetYuan ?? storyboard.budgetYuan;
  var capSeconds = (budget / priceYuanPerSecond).floor();
  if (maxI2vSeconds > 0 && maxI2vSeconds < capSeconds) {
    capSeconds = maxI2vSeconds;
  }

  final planWarnings = <String>[];

  // 时长解析（保持输入顺序）。
  final durations = <String, double>{};
  for (final shot in storyboard.shots) {
    durations[shot.id] = resolveDuration(shot, planWarnings);
  }

  // i2v 候选：所有 action，以及 priority != normal 的 listen_face。
  final originalIndex = <String, int>{
    for (var i = 0; i < storyboard.shots.length; i++) storyboard.shots[i].id: i,
  };
  final candidates = <Shot>[
    for (final shot in storyboard.shots)
      if (shot.kind == ShotKind.action ||
          (shot.kind == ShotKind.listenFace &&
              shot.priority != ShotPriority.normal))
        shot,
  ];
  candidates.sort((a, b) {
    final rankDelta = priorityRank(a.priority) - priorityRank(b.priority);
    if (rankDelta != 0) return rankDelta;
    return originalIndex[a.id]!.compareTo(originalIndex[b.id]!);
  });

  // 预算分配：整镜分配，不足则整镜降级，不部分分配。
  var remaining = capSeconds;
  final i2vSecondsByShot = <String, int>{};
  final downgraded = <String>{};
  for (final shot in candidates) {
    final d = durations[shot.id]!;
    final ceilDuration = d.ceil();
    var need = ceilDuration;
    if (need < _i2vMinSeconds) need = _i2vMinSeconds;
    if (need > _i2vMaxSeconds) need = _i2vMaxSeconds;
    if (need <= remaining) {
      // 只有真的分到 i2v 才记录 min/cap 两条 warning。
      if (ceilDuration < _i2vMinSeconds) {
        planWarnings.add('i2v_min_duration_raised:${shot.id}');
      }
      if (ceilDuration > _i2vMaxSeconds) {
        planWarnings.add('i2v_capped:${shot.id}');
      }
      i2vSecondsByShot[shot.id] = need;
      remaining -= need;
    } else {
      downgraded.add(shot.id);
    }
  }

  if (candidates.isNotEmpty && i2vSecondsByShot.isEmpty) {
    planWarnings.add('no_i2v_budget');
  }

  // 输出镜头（保持输入顺序）。
  final plannedShots = <PlannedShot>[];
  var totalDuration = 0.0;
  var totalI2vSeconds = 0;
  var totalCost = 0.0;
  for (final shot in storyboard.shots) {
    final d = durations[shot.id]!;
    final i2vSeconds = i2vSecondsByShot[shot.id] ?? 0;
    final route = switch (shot.kind) {
      ShotKind.speakOff ||
      ShotKind.insert ||
      ShotKind.establishing => ShotRoute.kenburns,
      ShotKind.listenFace ||
      ShotKind.action => i2vSeconds > 0 ? ShotRoute.i2v : ShotRoute.micro,
    };
    final cost = _round2(i2vSeconds * priceYuanPerSecond);
    plannedShots.add(
      PlannedShot(
        shotId: shot.id,
        kind: shot.kind,
        route: route,
        avatar: shot.kind == ShotKind.speakOff && shot.line.trim().isNotEmpty,
        durationS: d,
        i2vSeconds: i2vSeconds,
        costYuan: cost,
        framing: shot.framing,
        speaker: shot.speaker,
        line: shot.line,
        priority: shot.priority,
        downgradeReason: downgraded.contains(shot.id)
            ? 'budget_insufficient'
            : null,
      ),
    );
    totalDuration += d;
    totalI2vSeconds += i2vSeconds;
    totalCost += cost;
  }

  final estimatedYuan = _round2(totalCost);
  final rawRemaining = _round2(budget - estimatedYuan);
  final remainingYuan = rawRemaining < 0 ? 0.0 : rawRemaining;

  var kenburns = 0;
  var micro = 0;
  var i2vCount = 0;
  for (final shot in plannedShots) {
    switch (shot.route) {
      case ShotRoute.kenburns:
        kenburns++;
      case ShotRoute.micro:
        micro++;
      case ShotRoute.i2v:
        i2vCount++;
    }
  }

  // 解析期 warning 在前、计划期 warning 在后，去重且保持首次出现顺序。
  final warnings = <String>{...storyboard.warnings, ...planWarnings}.toList();

  return RenderPlan(
    contentId: storyboard.contentId,
    title: storyboard.title,
    frame: storyboard.frame,
    budgetYuan: _round2(budget),
    priceYuanPerSecond: _round2(priceYuanPerSecond),
    maxI2vSeconds: maxI2vSeconds,
    shots: plannedShots,
    totals: PlanTotals(
      durationS: _round1(totalDuration),
      i2vSeconds: totalI2vSeconds,
      estimatedYuan: estimatedYuan,
      remainingYuan: remainingYuan,
    ),
    counts: <String, int>{
      'kenburns': kenburns,
      'micro': micro,
      'i2v': i2vCount,
    },
    warnings: warnings,
  );
}

/// 保留 1 位小数（返回 double）。
double _round1(double x) => (x * 10).round() / 10.0;

/// 向上取整到 1 位小数（返回 double）。用于台词时长估算。
double _ceil1(double x) => (x * 10).ceil() / 10.0;

/// 保留 2 位小数（返回 double）。
double _round2(double x) => (x * 100).round() / 100.0;
