/// `/api/drama/*` 的二级路由与 HTTP 处理（纯 Dart，无 Flutter 依赖）。
///
/// 一级路由由 `api_router.dart` 统一落到 `ApiRoute.drama`；这里再按
/// `req.uri.pathSegments` 分发。所有 ID 先校验，所有 JSON 写入走
/// `DramaStore` 的原子写；失败统一返回 `{error, code}`。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../errors.dart';
import '../storyboard.dart';
import 'cost.dart';
import 'episode.dart';
import 'hash.dart';
import 'ids.dart';
import 'json.dart';
import 'llm.dart';
import 'pricing.dart';
import 'runner.dart';
import 'run_target.dart';
import 'series.dart';
import 'steps.dart';
import 'store.dart';

/// 二级动作。
enum DramaRoute {
  listSeries,
  createSeries,
  getSeries,
  updateSeries,
  deleteSeries,
  createEpisode,
  getEpisode,
  updateEpisode,
  deleteEpisode,
  saveStoryboard,
  replan,
  estimate,
  extractStory,
  draftStoryboard,
  runStep,
  runShot,
  runStatus,
  cancelRun,
  asset,
  seriesAsset,
}

/// 解析 `api/drama/...` 路径；未知返回 null。
DramaRoute? parseDramaRoute(String method, List<String> segments) {
  if (segments.length < 3 ||
      segments[0] != 'api' ||
      segments[1] != 'drama' ||
      segments[2] != 'series') {
    return null;
  }
  if (segments.length == 3) {
    if (method == 'GET') return DramaRoute.listSeries;
    if (method == 'POST') return DramaRoute.createSeries;
    return null;
  }
  if (segments.length == 4) {
    if (method == 'GET') return DramaRoute.getSeries;
    if (method == 'PUT') return DramaRoute.updateSeries;
    if (method == 'DELETE') return DramaRoute.deleteSeries;
    return null;
  }
  if (segments.length >= 6 &&
      segments[4] == 'assets' &&
      method == 'GET') {
    return DramaRoute.seriesAsset;
  }
  if (segments.length == 5 &&
      segments[4] == 'episodes' &&
      method == 'POST') {
    return DramaRoute.createEpisode;
  }
  if (segments.length >= 8 &&
      segments[4] == 'episodes' &&
      segments[6] == 'assets' &&
      method == 'GET') {
    return DramaRoute.asset;
  }
  if (segments.length == 6 && segments[4] == 'episodes') {
    if (method == 'GET') return DramaRoute.getEpisode;
    if (method == 'PUT') return DramaRoute.updateEpisode;
    if (method == 'DELETE') return DramaRoute.deleteEpisode;
    return null;
  }
  if (segments.length == 7 && segments[4] == 'episodes') {
    final action = segments[6];
    if (method == 'PUT' && action == 'storyboard') return DramaRoute.saveStoryboard;
    if (method == 'POST' && action == 'plan') return DramaRoute.replan;
    if (method == 'POST' && action == 'estimate') return DramaRoute.estimate;
    if (method == 'POST' && action == 'story:extract') return DramaRoute.extractStory;
    if (method == 'POST' && action == 'storyboard:draft') {
      return DramaRoute.draftStoryboard;
    }
    return null;
  }
  if (segments.length == 8 && segments[4] == 'episodes') {
    if (segments[6] == 'runs') {
      if (method == 'GET') return DramaRoute.runStatus;
      if (method == 'POST' && segments[7].endsWith(':cancel')) {
        return DramaRoute.cancelRun;
      }
      return null;
    }
    if (method == 'POST') {
      final kind = segments[6];
      final action = segments[7];
      if (kind == 'steps' && action.endsWith(':run')) return DramaRoute.runStep;
      if (kind == 'shots' && action.endsWith(':run')) return DramaRoute.runShot;
    }
  }
  return null;
}

/// 处理 `/api/drama/*`。
class DramaController {
  DramaController({
    required this.store,
    required this.drafts,
    required this.priceYuanPerSecond,
    DramaPricing? pricing,
    this.runner,
    this.maxBodyBytes = 2 * 1024 * 1024,
  }) : pricing = pricing ?? DramaPricing.catalog();

  final DramaStore store;
  final DramaDraftService drafts;
  final double priceYuanPerSecond;
  final DramaPricing pricing;
  final DramaRunner? runner;
  final int maxBodyBytes;

  Map<String, bool> get _capabilities => <String, bool>{
    'cast': runner != null,
    'frame': runner != null,
    'voice': false,
    'edit': false,
    'pack': false,
  };

  Future<void> handle(HttpRequest req) async {
    final segments = req.uri.pathSegments;
    final route = parseDramaRoute(req.method, segments);
    if (route == null) {
      await _error(req, HttpStatus.notFound, 'not found', 'not_found');
      return;
    }

    final seriesId = segments.length > 3 ? segments[3] : null;
    final episodeId = segments.length > 5 && segments[4] == 'episodes'
        ? segments[5]
        : null;
    if (seriesId != null && !isDramaId(seriesId)) {
      await _error(req, HttpStatus.badRequest, 'invalid series id', 'invalid_id');
      return;
    }
    if (episodeId != null && !isDramaId(episodeId)) {
      await _error(req, HttpStatus.badRequest, 'invalid episode id', 'invalid_id');
      return;
    }

    try {
      switch (route) {
        case DramaRoute.listSeries:
          await _listSeries(req);
        case DramaRoute.createSeries:
          await _createSeries(req);
        case DramaRoute.getSeries:
          await _getSeries(req, seriesId!);
        case DramaRoute.updateSeries:
          await _updateSeries(req, seriesId!);
        case DramaRoute.deleteSeries:
          await _deleteSeries(req, seriesId!);
        case DramaRoute.createEpisode:
          await _createEpisode(req, seriesId!);
        case DramaRoute.getEpisode:
          await _getEpisode(req, seriesId!, episodeId!);
        case DramaRoute.updateEpisode:
          await _updateEpisode(req, seriesId!, episodeId!);
        case DramaRoute.deleteEpisode:
          await _deleteEpisode(req, seriesId!, episodeId!);
        case DramaRoute.saveStoryboard:
          await _saveStoryboard(req, seriesId!, episodeId!);
        case DramaRoute.replan:
          await _replan(req, seriesId!, episodeId!);
        case DramaRoute.estimate:
          await _estimate(req, seriesId!, episodeId!);
        case DramaRoute.extractStory:
          await _extractStory(req, seriesId!, episodeId!);
        case DramaRoute.draftStoryboard:
          await _draftStoryboard(req, seriesId!, episodeId!);
        case DramaRoute.runStep:
          await _runStep(req, seriesId!, episodeId!, segments[7]);
        case DramaRoute.runShot:
          await _runShot(req, seriesId!, episodeId!, segments[7]);
        case DramaRoute.runStatus:
          await _getRun(req, episodeId!, segments[7]);
        case DramaRoute.cancelRun:
          await _cancelRun(req, episodeId!, segments[7]);
        case DramaRoute.asset:
          await _getAsset(
            req,
            seriesId!,
            episodeId!,
            segments.sublist(7).join('/'),
          );
        case DramaRoute.seriesAsset:
          await _getSeriesAsset(req, seriesId!, segments.sublist(5).join('/'));
      }
    } on FormatException catch (e) {
      await _error(req, HttpStatus.badRequest, e.message, 'invalid_body');
    } on ArgumentError catch (e) {
      await _error(
        req,
        HttpStatus.badRequest,
        e.message?.toString() ?? 'invalid argument',
        'invalid_body',
      );
    } on FileSystemException catch (e) {
      await _error(req, HttpStatus.notFound, 'not found: ${e.path}', 'not_found');
    } on StateError catch (e) {
      await _error(req, HttpStatus.conflict, e.message, 'conflict');
    } on ConfigException catch (e) {
      await _error(
        req,
        HttpStatus.badGateway,
        '未配置 DASHSCOPE_API_KEY：${e.message}',
        'upstream_unavailable',
      );
    } on PipelineError catch (e) {
      if (e.message.startsWith('draft_schema:')) {
        await _error(req, HttpStatus.unprocessableEntity, e.message, 'schema_invalid');
      } else {
        await _error(req, HttpStatus.internalServerError, e.message, 'internal');
      }
    } on Object catch (e) {
      await _error(req, HttpStatus.internalServerError, '$e', 'internal');
    }
  }

  Future<void> _listSeries(HttpRequest req) async {
    final list = <Map<String, Object?>>[];
    for (final series in store.listSeries()) {
      list.add(<String, Object?>{
        ...series.toJson(),
        'episode_count': store.listEpisodes(series.seriesId).length,
      });
    }
    await _sendJson(req, HttpStatus.ok, <String, Object?>{'series': list});
  }

  Future<void> _createSeries(HttpRequest req) async {
    final body = await _bodyOrError(req);
    if (body == null) return;
    final series = _bodyModel(
      () => DramaSeries.create(
        seriesId: requireJsonString(body['series_id'], 'series_id'),
        title: requireJsonString(body['title'], 'title'),
        logline: optionalJsonString(body['logline'], 'logline') ?? '',
        dialect: optionalJsonString(body['dialect'], 'dialect') ?? 'mandarin',
        plannedEpisodes: optionalJsonInt(body['planned_episodes'], 'planned_episodes') ?? 1,
        totalBudgetYuan:
            optionalJsonNumber(body['total_budget_yuan'], 'total_budget_yuan') ?? 120,
        i2vBudgetYuan:
            optionalJsonNumber(body['i2v_budget_yuan'], 'i2v_budget_yuan') ?? 20,
      ),
    );
    store.createSeries(series);
    await _sendJson(req, HttpStatus.created, <String, Object?>{'series': series.toJson()});
  }

  Future<void> _getSeries(HttpRequest req, String seriesId) async {
    final series = store.readSeries(seriesId);
    final episodes = <Map<String, Object?>>[
      for (final episode in store.listEpisodes(seriesId)) _episodeSummary(episode),
    ];
    await _sendJson(req, HttpStatus.ok, <String, Object?>{
      'series': series.toJson(),
      'episodes': episodes,
    });
  }

  Future<void> _updateSeries(HttpRequest req, String seriesId) async {
    final body = await _bodyOrError(req);
    if (body == null) return;
    final series = _bodyModel(
      () => DramaSeries.fromJson(asJsonMap(body['series'], 'series')),
    );
    if (series.seriesId != seriesId) {
      throw const FormatException('series_id 与路径不一致');
    }
    // PUT 是更新，不是隐式创建；缺失应 404。
    store.readSeries(seriesId);
    store.writeSeries(series);
    await _sendJson(req, HttpStatus.ok, <String, Object?>{
      'series': series.toJson(),
      'episodes': <Object?>[
        for (final episode in store.listEpisodes(seriesId)) _episodeSummary(episode),
      ],
    });
  }

  Future<void> _deleteSeries(HttpRequest req, String seriesId) async {
    store.deleteSeries(seriesId);
    await _sendNoContent(req);
  }

  Future<void> _createEpisode(HttpRequest req, String seriesId) async {
    final body = await _bodyOrError(req);
    if (body == null) return;
    final series = store.readSeries(seriesId);
    final existing = store.listEpisodes(seriesId);
    final number = _bodyModel(
      () => optionalJsonInt(body['number'], 'number') ?? existing.length + 1,
    );
    if (number <= 0) throw const FormatException('number 必须 > 0');
    final episodeId = _bodyModel(
      () => optionalJsonString(body['episode_id'], 'episode_id') ??
          'ep${number.toString().padLeft(2, '0')}',
    );
    if (!isDramaId(episodeId)) {
      throw const FormatException('episode_id 非法');
    }
    if (existing.any((e) => e.episodeId == episodeId)) {
      throw StateError('episode_exists');
    }
    final episode = _bodyModel(
      () => DramaEpisode.create(
        series: series,
        episodeId: episodeId,
        title: optionalJsonString(body['title'], 'title') ?? episodeId,
        number: number,
      ),
    );
    store.createEpisode(episode);
    await _sendJson(req, HttpStatus.created, <String, Object?>{'episode': episode.toJson()});
  }

  Future<void> _getEpisode(
    HttpRequest req,
    String seriesId,
    String episodeId,
  ) async {
    final series = store.readSeries(seriesId);
    final episode = store.readEpisode(seriesId, episodeId);
    await _sendJson(req, HttpStatus.ok, await _bundle(series, episode));
  }

  Future<void> _updateEpisode(
    HttpRequest req,
    String seriesId,
    String episodeId,
  ) async {
    final body = await _bodyOrError(req);
    if (body == null) return;
    final episode = _bodyModel(
      () => DramaEpisode.fromJson(asJsonMap(body['episode'], 'episode')),
    );
    if (episode.seriesId != seriesId || episode.episodeId != episodeId) {
      throw const FormatException('episode ids 与路径不一致');
    }
    // PUT 是更新，不是隐式创建；缺失应 404。
    store.readEpisode(seriesId, episodeId);
    store.writeEpisode(episode);
    final board = store.readStoryboard(seriesId, episodeId);
    if (board != null) _writePlan(seriesId, episodeId, episode, board);
    await _sendJson(
      req,
      HttpStatus.ok,
      await _bundle(store.readSeries(seriesId), episode),
    );
  }

  Future<void> _deleteEpisode(
    HttpRequest req,
    String seriesId,
    String episodeId,
  ) async {
    store.deleteEpisode(seriesId, episodeId);
    await _sendNoContent(req);
  }

  Future<void> _saveStoryboard(
    HttpRequest req,
    String seriesId,
    String episodeId,
  ) async {
    final body = await _bodyOrError(req);
    if (body == null) return;
    final board = _bodyModel(
      () => Storyboard.fromJson(asJsonMap(body['storyboard'], 'storyboard')),
    );
    if (board.contentId != episodeId) {
      throw const FormatException('storyboard.content_id 与路径不一致');
    }
    final episode = store.readEpisode(seriesId, episodeId);
    store.writeStoryboard(seriesId, episodeId, board);
    _writePlan(seriesId, episodeId, episode, board);
    await _sendJson(
      req,
      HttpStatus.ok,
      await _bundle(store.readSeries(seriesId), episode),
    );
  }

  Future<void> _replan(
    HttpRequest req,
    String seriesId,
    String episodeId,
  ) async {
    final episode = store.readEpisode(seriesId, episodeId);
    final board = store.readStoryboard(seriesId, episodeId);
    if (board == null) throw const FormatException('storyboard 不存在');
    _writePlan(seriesId, episodeId, episode, board);
    await _sendJson(
      req,
      HttpStatus.ok,
      await _bundle(store.readSeries(seriesId), episode),
    );
  }

  Future<void> _estimate(
    HttpRequest req,
    String seriesId,
    String episodeId,
  ) async {
    final body = await _bodyOrError(req);
    if (body == null) return;
    final request = _bodyModel(() => parseDramaEstimateRequest(body));
    final series = store.readSeries(seriesId);
    final episode = store.readEpisode(seriesId, episodeId);
    final estimate = estimateDrama(
      series: series,
      episode: episode,
      state: store.readState(seriesId, episodeId),
      storyboard: store.readStoryboard(seriesId, episodeId),
      planJson: store.readPlanJson(seriesId, episodeId),
      request: request,
      pricing: pricing,
      store: store,
    );
    await _sendJson(req, HttpStatus.ok, estimate.toJson());
  }

  Future<void> _extractStory(
    HttpRequest req,
    String seriesId,
    String episodeId,
  ) async {
    final body = req.contentLength == 0 ? null : await _bodyOrError(req);
    if (req.contentLength != 0 && body == null) return;
    final series = store.readSeries(seriesId);
    final stored = store.readEpisode(seriesId, episodeId);
    final text = body == null
        ? null
        : _bodyModel(() => optionalJsonString(body['text'], 'text'));
    final episode = text == null
        ? stored
        : stored.copyWith(
            source: DramaSource(kind: stored.source.kind, text: text),
          );
    final result = await drafts.extract(series: series, episode: episode);
    await _sendJson(req, HttpStatus.ok, result.toJson());
  }

  Future<void> _draftStoryboard(
    HttpRequest req,
    String seriesId,
    String episodeId,
  ) async {
    final series = store.readSeries(seriesId);
    final episode = store.readEpisode(seriesId, episodeId);
    final result = await drafts.draftStoryboard(series: series, episode: episode);
    await _sendJson(req, HttpStatus.ok, result.toJson());
  }

  Future<void> _runStep(
    HttpRequest req,
    String seriesId,
    String episodeId,
    String action,
  ) async {
    if (runner == null) {
      await _error(req, HttpStatus.notImplemented, '该工序尚未接入', 'not_wired');
      return;
    }
    final key = action.split(':').first;
    final step = dramaStepFromKey(key);
    if (step != DramaStep.cast && step != DramaStep.frame) {
      await _error(req, HttpStatus.notImplemented, '该工序尚未接入', 'not_wired');
      return;
    }
    final body = await _bodyOrError(req) ?? <String, Object?>{};
    final DramaEstimateRequest request;
    try {
      request = parseDramaEstimateRequest(<String, Object?>{
        ...body,
        'step': step == DramaStep.cast ? 'cast' : 'frame',
      });
    } on ArgumentError catch (e) {
      await _error(req, HttpStatus.badRequest, '${e.message}', 'invalid_body');
      return;
    }
    final series = store.readSeries(seriesId);
    final episode = store.readEpisode(seriesId, episodeId);
    final estimate = estimateDrama(
      series: series,
      episode: episode,
      state: store.readState(seriesId, episodeId),
      storyboard: store.readStoryboard(seriesId, episodeId),
      planJson: store.readPlanJson(seriesId, episodeId),
      request: request,
      pricing: pricing,
      store: store,
    );
    if (estimate.totalEstimatedYuan > estimate.budget.remainingYuan) {
      await _error(
        req,
        HttpStatus.conflict,
        '估算 ¥${estimate.totalEstimatedYuan.toStringAsFixed(2)} 超过剩余预算 '
        '¥${estimate.budget.remainingYuan.toStringAsFixed(2)}',
        'budget_exceeded',
      );
      return;
    }
    if (estimate.i2vEstimatedYuan > estimate.budget.i2vRemainingYuan) {
      await _error(
        req,
        HttpStatus.conflict,
        'i2v 估算 ¥${estimate.i2vEstimatedYuan.toStringAsFixed(2)} 超过剩余 i2v 预算 '
        '¥${estimate.budget.i2vRemainingYuan.toStringAsFixed(2)}',
        'budget_exceeded',
      );
      return;
    }
    try {
      final run = await runner!.startStep(
        seriesId: seriesId,
        episodeId: episodeId,
        step: step!,
        castIds: request.castIds,
        shotIds: request.shotIds,
        target: request.target,
        force: request.force,
      );
      await _sendJson(req, HttpStatus.accepted, <String, Object?>{
        'run_id': run.id,
      });
    } on StateError catch (e) {
      await _error(req, HttpStatus.conflict, e.message, e.message);
    } on ArgumentError catch (e) {
      await _error(req, HttpStatus.badRequest, '${e.message}', 'invalid_body');
    }
  }

  Future<void> _runShot(
    HttpRequest req,
    String seriesId,
    String episodeId,
    String action,
  ) async {
    if (runner == null) {
      await _error(req, HttpStatus.notImplemented, '该工序尚未接入', 'not_wired');
      return;
    }
    final shotId = action.split(':').first;
    final body = await _bodyOrError(req) ?? <String, Object?>{};
    final targetRaw = body['target'];
    final target = targetRaw == null
        ? DramaRunTarget.all
        : DramaRunTarget.values
              .where((candidate) => candidate.name == targetRaw)
              .firstOrNull;
    if (target == null) {
      await _error(req, HttpStatus.badRequest, 'target 非法', 'invalid_body');
      return;
    }
    final force = body['force'] == true;
    final degrade = body['degrade'] == true;
    final series = store.readSeries(seriesId);
    final episode = store.readEpisode(seriesId, episodeId);
    final estimate = estimateDrama(
      series: series,
      episode: episode,
      state: store.readState(seriesId, episodeId),
      storyboard: store.readStoryboard(seriesId, episodeId),
      planJson: store.readPlanJson(seriesId, episodeId),
      request: DramaEstimateRequest(
        step: DramaEstimateStep.frame,
        shotIds: <String>[shotId],
        target: target,
        force: force,
      ),
      pricing: pricing,
      store: store,
    );
    if (estimate.totalEstimatedYuan > estimate.budget.remainingYuan ||
        estimate.i2vEstimatedYuan > estimate.budget.i2vRemainingYuan) {
      await _error(req, HttpStatus.conflict, '估算超过剩余预算', 'budget_exceeded');
      return;
    }
    try {
      final run = await runner!.startShot(
        seriesId: seriesId,
        episodeId: episodeId,
        shotId: shotId,
        target: target,
        force: force,
        degrade: degrade,
      );
      await _sendJson(req, HttpStatus.accepted, <String, Object?>{
        'run_id': run.id,
      });
    } on StateError catch (e) {
      await _error(req, HttpStatus.conflict, e.message, e.message);
    } on ArgumentError catch (e) {
      await _error(req, HttpStatus.badRequest, '${e.message}', 'invalid_body');
    }
  }

  Future<void> _getRun(
    HttpRequest req,
    String episodeId,
    String runId,
  ) async {
    final run = runner?.run(runId);
    if (run == null) {
      await _error(req, HttpStatus.notFound, 'run 不存在', 'not_found');
      return;
    }
    await _sendJson(req, HttpStatus.ok, run.toJson());
  }

  Future<void> _cancelRun(
    HttpRequest req,
    String episodeId,
    String action,
  ) async {
    if (runner == null) {
      await _error(req, HttpStatus.notImplemented, 'run 不可用', 'not_wired');
      return;
    }
    final runId = action.split(':').first;
    if (runner!.run(runId) == null) {
      await _error(req, HttpStatus.notFound, 'run 不存在', 'not_found');
      return;
    }
    await runner!.cancel(runId);
    await _sendJson(req, HttpStatus.accepted, <String, Object?>{
      'status': 'cancelling',
    });
  }

  Future<void> _getAsset(
    HttpRequest req,
    String seriesId,
    String episodeId,
    String relativePath,
  ) async {
    final File file;
    try {
      file = store.assetFile(seriesId, episodeId, relativePath);
    } on ArgumentError catch (e) {
      await _error(req, HttpStatus.badRequest, '${e.message}', 'path_escape');
      return;
    }
    await _sendFile(req, file);
  }

  Future<void> _getSeriesAsset(
    HttpRequest req,
    String seriesId,
    String relativePath,
  ) async {
    final File file;
    try {
      file = store.seriesAssetFile(seriesId, relativePath);
    } on ArgumentError catch (e) {
      await _error(req, HttpStatus.badRequest, '${e.message}', 'path_escape');
      return;
    }
    await _sendFile(req, file);
  }

  Future<void> _sendFile(HttpRequest req, File file) async {
    if (!file.existsSync() || FileSystemEntity.isDirectorySync(file.path)) {
      await _error(req, HttpStatus.notFound, 'asset 不存在', 'not_found');
      return;
    }
    final type = _contentType(file.path);
    if (type == null) {
      await _error(req, HttpStatus.notFound, '不支持的资源类型', 'not_found');
      return;
    }
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.parse(type);
    await req.response.addStream(file.openRead());
    await req.response.close();
  }

  static String? _contentType(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'mp4':
        return 'video/mp4';
      case 'wav':
        return 'audio/wav';
      case 'srt':
        return 'text/plain; charset=utf-8';
      default:
        return null;
    }
  }

  Future<Map<String, Object?>> _bundle(
    DramaSeries series,
    DramaEpisode episode,
  ) async {
    runner?.recoverOrphan(series.seriesId, episode.episodeId);
    final board = store.readStoryboard(series.seriesId, episode.episodeId);
    final planJson = store.readPlanJson(series.seriesId, episode.episodeId);
    final state = store.readState(series.seriesId, episode.episodeId);
    final steps = deriveDramaSteps(
      series: series,
      episode: episode,
      storyboard: board,
      planJson: planJson,
      state: state,
      wired: runner == null ? kP1WiredSteps : kDramaWiredSteps,
    );
    return <String, Object?>{
      'series': series.toJson(),
      'episode': episode.toJson(),
      'storyboard': board?.toJson(),
      'plan': planJson,
      'state': state.toJson(),
      'steps': <Object?>[for (final step in steps) step.toJson()],
      'capabilities': _capabilities,
    };
  }

  void _writePlan(
    String seriesId,
    String episodeId,
    DramaEpisode episode,
    Storyboard board,
  ) {
    final plan = buildDramaPlan(
      storyboard: board,
      episode: episode,
      priceYuanPerSecond: priceYuanPerSecond,
    );
    store.writePlanJson(seriesId, episodeId, plan.toJson());
    final state = store
        .readState(seriesId, episodeId)
        .withStoryboardHash(dramaHash(board.toJson()))
        .withPlanHash(dramaPlanHash(storyboard: board, episode: episode));
    store.writeState(seriesId, episodeId, state);
  }

  Map<String, Object?> _episodeSummary(DramaEpisode episode) =>
      <String, Object?>{
        'episode_id': episode.episodeId,
        'number': episode.number,
        'title': episode.title,
      };

  T _bodyModel<T>(T Function() parse) {
    try {
      return parse();
    } on PipelineError catch (e) {
      throw FormatException(e.message);
    }
  }

  Future<Map<String, Object?>?> _bodyOrError(HttpRequest req) async {
    final result = await _readBody(req);
    if (result is _BodyOk) return result.value;
    if (result is _BodyTooLarge) {
      await _error(req, HttpStatus.requestEntityTooLarge, '请求体过大', 'body_too_large');
    } else {
      await _error(req, HttpStatus.badRequest, 'invalid JSON body', 'invalid_body');
    }
    return null;
  }

  Future<_BodyResult> _readBody(HttpRequest req) async {
    if (req.contentLength > maxBodyBytes) return const _BodyTooLarge();
    final chunks = <int>[];
    await for (final chunk in req) {
      chunks.addAll(chunk);
      if (chunks.length > maxBodyBytes) return const _BodyTooLarge();
    }
    try {
      final decoded = jsonDecode(utf8.decode(chunks));
      if (decoded is! Map) return const _BodyInvalid();
      return _BodyOk(asJsonMap(decoded, 'body'));
    } on Object {
      return const _BodyInvalid();
    }
  }

  Future<void> _sendJson(
    HttpRequest req,
    int status,
    Map<String, Object?> body,
  ) async {
    final data = utf8.encode(jsonEncode(body));
    req.response
      ..statusCode = status
      ..headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8')
      ..headers.set(HttpHeaders.contentLengthHeader, data.length)
      ..add(data);
    await req.response.close();
  }

  Future<void> _sendNoContent(HttpRequest req) async {
    req.response.statusCode = HttpStatus.noContent;
    await req.response.close();
  }

  Future<void> _error(
    HttpRequest req,
    int status,
    String message,
    String code,
  ) => _sendJson(req, status, <String, Object?>{
    'error': message,
    'code': code,
  });
}

sealed class _BodyResult {
  const _BodyResult();
}

class _BodyOk extends _BodyResult {
  const _BodyOk(this.value);
  final Map<String, Object?> value;
}

class _BodyTooLarge extends _BodyResult {
  const _BodyTooLarge();
}

class _BodyInvalid extends _BodyResult {
  const _BodyInvalid();
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
