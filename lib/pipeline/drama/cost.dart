/// 短剧费用估算与计划单构建（纯 Dart，无 Flutter 依赖）。
///
/// 价格只来自 `generation_models.dart` 的目录默认价；P1 的 LLM/TTS 没有
/// 目录价，因此进 `unpriced`，不伪装成 0，也不计入预算估算。
library;

import '../generation_models.dart';
import '../render_plan.dart';
import '../storyboard.dart';
import 'episode.dart';
import 'series.dart';
import 'state.dart';

/// 计划单 i2v 单价；目录缺失直接抛错，不静默回退。
double defaultDramaI2vPriceYuanPerSecond() {
  final model = findVideoModel(kPlanI2vModel);
  final price = model?.defaultPrices[kPlanI2vResolution];
  if (price == null) {
    throw StateError(
      '视频目录缺少 $kPlanI2vModel / $kPlanI2vResolution 的价格',
    );
  }
  return price;
}

/// 按本集设置构建确定性计划单。
RenderPlan buildDramaPlan({
  required Storyboard storyboard,
  required DramaEpisode episode,
}) => buildRenderPlan(
  storyboard: storyboard,
  priceYuanPerSecond: defaultDramaI2vPriceYuanPerSecond(),
  budgetYuan: episode.settings.i2vBudgetYuan,
  maxI2vSeconds: episode.settings.maxI2vSeconds,
);

/// 一个可估价项。
class DramaEstimateItem {
  const DramaEstimateItem({
    required this.kind,
    required this.id,
    required this.model,
    required this.quantity,
    required this.unit,
    required this.priceYuan,
    required this.subtotalYuan,
    required this.estimated,
  });

  final String kind;
  final String id;
  final String model;
  final double quantity;
  final String unit;
  final double priceYuan;
  final double subtotalYuan;
  final bool estimated;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'id': id,
    'model': model,
    'quantity': quantity,
    'unit': unit,
    'price_yuan': priceYuan,
    'subtotal_yuan': subtotalYuan,
    'estimated': estimated,
  };
}

/// 无法估价的项（LLM / TTS）。
class DramaUnpricedItem {
  const DramaUnpricedItem({
    required this.kind,
    required this.id,
    required this.reason,
  });

  final String kind;
  final String id;
  final String reason;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'id': id,
    'reason': reason,
  };
}

/// 预算快照。
class DramaBudgetSnapshot {
  const DramaBudgetSnapshot({
    required this.totalYuan,
    required this.actualYuan,
    required this.remainingYuan,
  });

  final double totalYuan;
  final double actualYuan;
  final double remainingYuan;

  Map<String, Object?> toJson() => <String, Object?>{
    'total_yuan': totalYuan,
    'actual_yuan': actualYuan,
    'remaining_yuan': remainingYuan,
  };
}

/// 一次运行的估算结果；服务端是唯一报价来源。
class DramaEstimate {
  const DramaEstimate({
    required this.items,
    required this.totalEstimatedYuan,
    required this.unpriced,
    required this.budget,
  });

  final List<DramaEstimateItem> items;
  final double totalEstimatedYuan;
  final List<DramaUnpricedItem> unpriced;
  final DramaBudgetSnapshot budget;

  Map<String, Object?> toJson() => <String, Object?>{
    'items': <Object?>[for (final item in items) item.toJson()],
    'total_estimated_yuan': totalEstimatedYuan,
    'unpriced': <Object?>[for (final item in unpriced) item.toJson()],
    'budget': budget.toJson(),
  };
}

const Set<String> _knownTargets = <String>{'story', 'storyboard'};

/// P1 只规划 LLM 草稿；图片/视频/TTS 由 P2/P3 扩展。
DramaEstimate estimateDrama({
  required DramaSeries series,
  required DramaEpisode episode,
  required DramaEpisodeState state,
  Storyboard? storyboard,
  Map<String, Object?>? planJson,
  required Set<String> targets,
  bool force = false,
}) {
  for (final target in targets) {
    if (!_knownTargets.contains(target)) {
      throw ArgumentError.value(target, 'targets', 'unknown target');
    }
  }
  final sorted = targets.toList()..sort();
  final unpriced = <DramaUnpricedItem>[
    for (final target in sorted)
      DramaUnpricedItem(
        kind: 'llm',
        id: target,
        reason: 'llm_pricing_unavailable',
      ),
  ];
  final total = episode.settings.totalBudgetYuan;
  final actual = state.actualYuan;
  return DramaEstimate(
    items: const <DramaEstimateItem>[],
    totalEstimatedYuan: 0,
    unpriced: List<DramaUnpricedItem>.unmodifiable(unpriced),
    budget: DramaBudgetSnapshot(
      totalYuan: total,
      actualYuan: actual,
      remainingYuan: (total - actual).clamp(0, double.infinity).toDouble(),
    ),
  );
}
