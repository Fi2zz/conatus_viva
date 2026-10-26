/// 短剧费用估算与计划单构建（纯 Dart，无 Flutter 依赖）。
///
/// 价格只来自注入的 [DramaPricing]（由目录 + 配置解析）；前端只展示
/// 服务端估算，不重算。已缓存且 hash 一致的产物默认不出现在 items 中。
library;

import '../generation_models.dart';
import '../render_plan.dart';
import '../storyboard.dart';
import 'episode.dart';
import 'hashes.dart';
import 'plan_view.dart';
import 'pricing.dart';
import 'run_target.dart';
import 'series.dart';
import 'state.dart';
import 'store.dart';

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

/// 计划单 t2v 单价；目录缺失直接抛错，不静默回退。
double defaultDramaT2vPriceYuanPerSecond() {
  final model = findVideoModel('wan3.0-video');
  final price = model?.defaultPrices['720P'];
  if (price == null) {
    throw StateError('视频目录缺少 wan3.0-video / 720P 的价格');
  }
  return price;
}

/// 按本集设置构建确定性计划单。
RenderPlan buildDramaPlan({
  required Storyboard storyboard,
  required DramaEpisode episode,
  double? priceYuanPerSecond,
  double? t2vPriceYuanPerSecond,
}) => buildRenderPlan(
  storyboard: storyboard,
  priceYuanPerSecond:
      priceYuanPerSecond ?? defaultDramaI2vPriceYuanPerSecond(),
  budgetYuan: episode.settings.i2vBudgetYuan,
  maxI2vSeconds: episode.settings.maxI2vSeconds,
  t2vPriceYuanPerSecond:
      t2vPriceYuanPerSecond ?? defaultDramaT2vPriceYuanPerSecond(),
  totalBudgetYuan: episode.settings.totalBudgetYuan,
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

/// 无法估价的项（LLM）。
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

/// 预算快照（总预算 + i2v 子预算）。
class DramaBudgetSnapshot {
  const DramaBudgetSnapshot({
    required this.totalYuan,
    required this.actualYuan,
    required this.remainingYuan,
    required this.i2vTotalYuan,
    required this.i2vActualYuan,
    required this.i2vRemainingYuan,
  });

  final double totalYuan;
  final double actualYuan;
  final double remainingYuan;
  final double i2vTotalYuan;
  final double i2vActualYuan;
  final double i2vRemainingYuan;

  Map<String, Object?> toJson() => <String, Object?>{
    'total_yuan': totalYuan,
    'actual_yuan': actualYuan,
    'remaining_yuan': remainingYuan,
    'i2v_total_yuan': i2vTotalYuan,
    'i2v_actual_yuan': i2vActualYuan,
    'i2v_remaining_yuan': i2vRemainingYuan,
  };
}

/// 一次运行的估算结果；服务端是唯一报价来源。
class DramaEstimate {
  const DramaEstimate({
    required this.items,
    required this.totalEstimatedYuan,
    required this.i2vEstimatedYuan,
    required this.unpriced,
    required this.budget,
  });

  final List<DramaEstimateItem> items;
  final double totalEstimatedYuan;
  final double i2vEstimatedYuan;
  final List<DramaUnpricedItem> unpriced;
  final DramaBudgetSnapshot budget;

  Map<String, Object?> toJson() => <String, Object?>{
    'items': <Object?>[for (final item in items) item.toJson()],
    'total_estimated_yuan': totalEstimatedYuan,
    'i2v_estimated_yuan': i2vEstimatedYuan,
    'unpriced': <Object?>[for (final item in unpriced) item.toJson()],
    'budget': budget.toJson(),
  };
}

/// 估算步骤；`story` / `storyboard` 只产生 LLM 未估价项。
enum DramaEstimateStep { story, storyboard, cast, frame }

/// 一次估算请求；旧的 `targets` 格式已删除。
class DramaEstimateRequest {
  const DramaEstimateRequest({
    required this.step,
    this.castIds = const <String>[],
    this.shotIds = const <String>[],
    this.target = DramaRunTarget.all,
    this.force = false,
    this.degrade = false,
  });

  final DramaEstimateStep step;
  final List<String> castIds;
  final List<String> shotIds;
  final DramaRunTarget target;
  final bool force;
  final bool degrade;
}

DramaEstimateRequest parseDramaEstimateRequest(Map<String, Object?> body) {
  final rawStep = body['step'];
  if (rawStep is! String) {
    throw ArgumentError.value(rawStep, 'step', 'must be a string');
  }
  final step = DramaEstimateStep.values
      .where((candidate) => candidate.name == rawStep)
      .firstOrNull;
  if (step == null) {
    throw ArgumentError.value(rawStep, 'step', 'unknown estimate step');
  }
  final targetRaw = body['target'];
  final target = targetRaw == null
      ? DramaRunTarget.all
      : DramaRunTarget.values
            .where((candidate) => candidate.name == targetRaw)
            .firstOrNull;
  if (target == null) {
    throw ArgumentError.value(targetRaw, 'target', 'unknown run target');
  }
  return DramaEstimateRequest(
    step: step,
    castIds: _stringList(body['cast_ids'], 'cast_ids'),
    shotIds: _stringList(body['shot_ids'], 'shot_ids'),
    target: target,
    force: body['force'] == null ? false : _bool(body['force'], 'force'),
    degrade: body['degrade'] == null ? false : _bool(body['degrade'], 'degrade'),
  );
}

List<String> _stringList(Object? raw, String field) {
  if (raw == null) return const <String>[];
  if (raw is! List) throw ArgumentError.value(raw, field, 'must be a list');
  return <String>[
    for (final item in raw)
      if (item is String && item.trim().isNotEmpty)
        item.trim()
      else
        throw ArgumentError.value(item, field, 'must be a non-empty string'),
  ];
}

bool _bool(Object? raw, String field) {
  if (raw is bool) return raw;
  throw ArgumentError.value(raw, field, 'must be a boolean');
}

/// 估算一次 run；服务端只认这个结果。
DramaEstimate estimateDrama({
  required DramaSeries series,
  required DramaEpisode episode,
  required Storyboard? storyboard,
  required Map<String, Object?>? planJson,
  required DramaEpisodeState state,
  required DramaEstimateRequest request,
  required DramaPricing pricing,
  required DramaStore store,
}) {
  final items = <DramaEstimateItem>[];
  final unpriced = <DramaUnpricedItem>[];

  if (request.step == DramaEstimateStep.story ||
      request.step == DramaEstimateStep.storyboard) {
    unpriced.add(
      DramaUnpricedItem(
        kind: 'llm',
        id: request.step.name,
        reason: 'llm_pricing_unavailable',
      ),
    );
  } else if (request.step == DramaEstimateStep.cast) {
    _estimateCast(
      series: series,
      storyboard: storyboard,
      request: request,
      pricing: pricing,
      store: store,
      items: items,
    );
  } else {
    _estimateFrame(
      series: series,
      episode: episode,
      storyboard: storyboard,
      planJson: planJson,
      state: state,
      request: request,
      pricing: pricing,
      store: store,
      items: items,
    );
  }

  final i2vActual = _i2vActual(state, storyboard, planJson);
  final i2vBudget = episode.settings.i2vBudgetYuan;
  final i2vEstimated = items
      .where((item) => item.kind == 'clip')
      .fold<double>(0, (sum, item) => sum + item.subtotalYuan);
  final total = items.fold<double>(0, (sum, item) => sum + item.subtotalYuan);
  final actual = state.actualYuan;
  final budget = episode.settings.totalBudgetYuan;
  return DramaEstimate(
    items: List<DramaEstimateItem>.unmodifiable(items),
    totalEstimatedYuan: total,
    i2vEstimatedYuan: i2vEstimated,
    unpriced: List<DramaUnpricedItem>.unmodifiable(unpriced),
    budget: DramaBudgetSnapshot(
      totalYuan: budget,
      actualYuan: actual,
      remainingYuan: (budget - actual).clamp(0, double.infinity).toDouble(),
      i2vTotalYuan: i2vBudget,
      i2vActualYuan: i2vActual,
      i2vRemainingYuan: (i2vBudget - i2vActual)
          .clamp(0, double.infinity)
          .toDouble(),
    ),
  );
}

void _estimateCast({
  required DramaSeries series,
  required Storyboard? storyboard,
  required DramaEstimateRequest request,
  required DramaPricing pricing,
  required DramaStore store,
  required List<DramaEstimateItem> items,
}) {
  final ids = request.castIds.isEmpty
      ? _referencedSpeakers(storyboard)
      : request.castIds;
  final model = series.defaults.castImageModel;
  const size = '1K';
  final price = pricing.imagePrice(model, size);
  for (final id in ids) {
    final member = series.cast[id];
    if (member == null) {
      throw ArgumentError.value(id, 'cast_ids', 'unknown cast');
    }
    final hash = dramaCastHash(member: member, model: model, size: size);
    if (!request.force && _castCached(series, store, member, hash)) {
      continue;
    }
    items.add(
      DramaEstimateItem(
        kind: 'image',
        id: id,
        model: model,
        quantity: 1,
        unit: 'image',
        priceYuan: price,
        subtotalYuan: price,
        estimated: true,
      ),
    );
  }
}

void _estimateFrame({
  required DramaSeries series,
  required DramaEpisode episode,
  required Storyboard? storyboard,
  required Map<String, Object?>? planJson,
  required DramaEpisodeState state,
  required DramaEstimateRequest request,
  required DramaPricing pricing,
  required DramaStore store,
  required List<DramaEstimateItem> items,
}) {
  final shots = storyboard?.shots ?? const <Shot>[];
  if (shots.isEmpty) return;
  final selected = request.shotIds.isEmpty
      ? shots
      : <Shot>[
          for (final id in request.shotIds)
            shots.firstWhere(
              (shot) => shot.id == id,
              orElse: () => throw ArgumentError.value(id, 'shot_ids', 'unknown shot'),
            ),
        ];
  final wantFrame =
      request.target == DramaRunTarget.frame || request.target == DramaRunTarget.all;
  final wantClip =
      request.target == DramaRunTarget.clip || request.target == DramaRunTarget.all;
  final plan = planJson == null ? null : DramaPlanView(planJson);
  if (wantClip && plan == null) {
    throw StateError('plan_required');
  }
  final frameModel = series.defaults.frameImageModel;
  final clipModel = series.defaults.clipVideoModel;
  final resolution = series.defaults.resolution;
  const size = '1K';
  final framePrice = pricing.imagePrice(frameModel, size);

  for (final shot in selected) {
    final avatarHash = _approvedAvatarHash(series, shot.speaker);
    final frameHash = dramaFrameHash(
      shot: shot,
      castAvatarHash: avatarHash,
      model: frameModel,
      size: size,
    );
    final route = request.degrade
        ? ShotRoute.kenburns
        : (plan == null ? ShotRoute.micro : plan.routeFor(shot.id));
    final isT2v = route == ShotRoute.t2v;
    final frameCached = isT2v
        ? true
        : _frameCached(
            store: store,
            state: state,
            seriesId: series.seriesId,
            episodeId: episode.episodeId,
            shotId: shot.id,
            hash: frameHash,
          );
    final needFrame = !frameCached || (request.force && wantFrame);
    if (!isT2v && ((wantFrame && needFrame) || (wantClip && !frameCached))) {
      items.add(
        DramaEstimateItem(
          kind: 'image',
          id: shot.id,
          model: frameModel,
          quantity: 1,
          unit: 'image',
          priceYuan: framePrice,
          subtotalYuan: framePrice,
          estimated: true,
        ),
      );
    }
    if (!wantClip) continue;
    if (route == ShotRoute.t2v) {
      final t2vModel = series.defaults.t2vModel;
      final duration = plan!.durationFor(shot.id).ceil().clamp(2, 10);
      final clipHash = dramaClipHash(
        shot: shot,
        frameHash: frameHash,
        route: route.name,
        model: t2vModel,
        resolution: resolution,
        i2vSeconds: 0,
      );
      if (!request.force &&
          _clipCached(
            store: store,
            state: state,
            seriesId: series.seriesId,
            episodeId: episode.episodeId,
            shotId: shot.id,
            hash: clipHash,
          )) {
        continue;
      }
      final price = pricing.videoPrice(t2vModel, resolution);
      items.add(
        DramaEstimateItem(
          kind: 't2v',
          id: shot.id,
          model: t2vModel,
          quantity: duration.toDouble(),
          unit: 'second',
          priceYuan: price,
          subtotalYuan: price * duration,
          estimated: true,
        ),
      );
      continue;
    }
    final i2vSeconds = route == ShotRoute.i2v
        ? plan!.i2vSecondsFor(shot.id)
        : 0;
    final clipHash = dramaClipHash(
      shot: shot,
      frameHash: frameHash,
      route: route.name,
      model: route == ShotRoute.i2v ? clipModel : 'ffmpeg',
      resolution: resolution,
      i2vSeconds: i2vSeconds,
    );
    final degradedHash = route == ShotRoute.i2v
        ? dramaClipHash(
            shot: shot,
            frameHash: frameHash,
            route: ShotRoute.kenburns.name,
            model: 'ffmpeg',
            resolution: resolution,
            i2vSeconds: 0,
          )
        : null;
    if (!request.force &&
        (_clipCached(
              store: store,
              state: state,
              seriesId: series.seriesId,
              episodeId: episode.episodeId,
              shotId: shot.id,
              hash: clipHash,
            ) ||
            (degradedHash != null &&
                _clipCached(
                  store: store,
                  state: state,
                  seriesId: series.seriesId,
                  episodeId: episode.episodeId,
                  shotId: shot.id,
                  hash: degradedHash,
                )))) {
      continue;
    }
    if (route == ShotRoute.i2v) {
      final price = pricing.videoPrice(clipModel, resolution);
      final quantity = i2vSeconds.toDouble();
      items.add(
        DramaEstimateItem(
          kind: 'clip',
          id: shot.id,
          model: clipModel,
          quantity: quantity,
          unit: 'second',
          priceYuan: price,
          subtotalYuan: price * quantity,
          estimated: true,
        ),
      );
    } else {
      final quantity = plan!.durationFor(shot.id).ceilToDouble();
      items.add(
        DramaEstimateItem(
          kind: 'local',
          id: shot.id,
          model: 'ffmpeg',
          quantity: quantity,
          unit: 'second',
          priceYuan: 0,
          subtotalYuan: 0,
          estimated: true,
        ),
      );
    }
  }
}

Set<String> _referencedSpeakers(Storyboard? storyboard) {
  final out = <String>{};
  for (final shot in storyboard?.shots ?? const <Shot>[]) {
    final speaker = shot.speaker;
    if (speaker != null && speaker.trim().isNotEmpty) out.add(speaker);
  }
  return out;
}

String? _approvedAvatarHash(DramaSeries series, String? speaker) {
  if (speaker == null) return null;
  final avatar = series.cast[speaker]?.avatar;
  return avatar != null && avatar.approved ? avatar.sourceHash : null;
}

bool _castCached(
  DramaSeries series,
  DramaStore store,
  DramaCastMember member,
  String hash,
) {
  final avatar = member.avatar;
  if (avatar == null || avatar.sourceHash != hash) return false;
  return store.seriesAssetFile(series.seriesId, avatar.path).existsSync();
}

bool _frameCached({
  required DramaStore store,
  required DramaEpisodeState state,
  required String seriesId,
  required String episodeId,
  required String shotId,
  required String hash,
}) {
  final artifact = state.shots[shotId]?.frame;
  if (artifact == null ||
      artifact.status != DramaStatus.succeeded ||
      artifact.sourceHash != hash ||
      artifact.path == null) {
    return false;
  }
  return store.assetFile(seriesId, episodeId, artifact.path!).existsSync();
}

bool _clipCached({
  required DramaStore store,
  required DramaEpisodeState state,
  required String seriesId,
  required String episodeId,
  required String shotId,
  required String hash,
}) {
  final artifact = state.shots[shotId]?.clip;
  if (artifact == null ||
      artifact.status != DramaStatus.succeeded ||
      artifact.sourceHash != hash ||
      artifact.path == null) {
    return false;
  }
  return store.assetFile(seriesId, episodeId, artifact.path!).existsSync();
}

double _i2vActual(
  DramaEpisodeState state,
  Storyboard? storyboard,
  Map<String, Object?>? planJson,
) {
  if (planJson == null) return 0;
  final plan = DramaPlanView(planJson);
  var total = 0.0;
  for (final shot in storyboard?.shots ?? const <Shot>[]) {
    if (plan.routeFor(shot.id) != ShotRoute.i2v) continue;
    total += state.shots[shot.id]?.clip.costYuan ?? 0;
  }
  return total;
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
