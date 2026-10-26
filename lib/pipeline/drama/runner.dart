/// 顺序执行器：逐项调用媒体网关、逐项落盘、单项失败不中断整批。
library;

import 'dart:async';
import 'dart:io';

import '../config.dart';
import '../generation_models.dart';
import '../storyboard.dart';
import 'episode.dart';
import 'hashes.dart';
import 'media_gateway.dart';
import 'run_registry.dart';
import 'run_target.dart';
import 'series.dart';
import 'state.dart';
import 'steps.dart';
import 'store.dart';

export 'run_registry.dart'
    show DramaRun, DramaRunItem, DramaRunRegistry, DramaRunStatus;

class DramaRunner {
  DramaRunner({
    required this.store,
    required this.gateway,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DramaStore store;
  final DramaMediaGateway gateway;
  final DateTime Function() _now;
  final DramaRunRegistry _runs = DramaRunRegistry();
  int _seq = 0;

  DramaRun? run(String id) => _runs.get(id);

  DramaRun? activeFor(String seriesId, String episodeId) =>
      _runs.activeFor(seriesId, episodeId);

  Future<void> cancel(String runId) async {
    _runs.cancel(runId);
  }

  Future<DramaRun> startStep({
    required String seriesId,
    required String episodeId,
    required DramaStep step,
    List<String> castIds = const <String>[],
    List<String> shotIds = const <String>[],
    DramaRunTarget target = DramaRunTarget.all,
    bool force = false,
  }) async {
    if (step != DramaStep.cast && step != DramaStep.frame) {
      throw ArgumentError.value(step.name, 'step', 'step is not wired');
    }
    final active = _runs.activeFor(seriesId, episodeId);
    if (active != null) {
      throw StateError('episode_busy');
    }
    final series = store.readSeries(seriesId);
    final episode = store.readEpisode(seriesId, episodeId);
    final board = store.readStoryboard(seriesId, episodeId);
    final planJson = store.readPlanJson(seriesId, episodeId);
    if (step == DramaStep.frame && planJson == null) {
      throw StateError('plan_required');
    }
    final run = _newRun(seriesId, episodeId, step);
    _runs.add(run);
    unawaited(
      _execute(
        run: run,
        series: series,
        episode: episode,
        board: board,
        planJson: planJson,
        castIds: castIds,
        shotIds: shotIds,
        target: target,
        force: force,
      ),
    );
    return run;
  }

  Future<DramaRun> startShot({
    required String seriesId,
    required String episodeId,
    required String shotId,
    required DramaRunTarget target,
    bool force = false,
    bool degrade = false,
  }) async {
    if (target == DramaRunTarget.frame) {
      return startStep(
        seriesId: seriesId,
        episodeId: episodeId,
        step: DramaStep.frame,
        shotIds: <String>[shotId],
        target: DramaRunTarget.frame,
        force: force,
      );
    }
    // clip/all 由 Task 11 的 frame 执行器处理。
    return startStep(
      seriesId: seriesId,
      episodeId: episodeId,
      step: DramaStep.frame,
      shotIds: <String>[shotId],
      target: target,
      force: force,
    );
  }

  void recoverOrphan(String seriesId, String episodeId) {
    final state = store.readState(seriesId, episodeId);
    final active = state.activeRunId;
    if (active == null) return;
    if (_runs.get(active) != null) return;
    var next = state;
    for (final key in kDramaStepKeys) {
      if (state.steps[key]?.status == DramaStatus.running) {
        next = next.withStep(
          key,
          DramaStepRun(
            status: DramaStatus.interrupted,
            attempts: state.steps[key]?.attempts ?? 0,
            error: '进程重启，运行已中断',
            logs: state.steps[key]?.logs ?? const <String>[],
          ),
        );
      }
    }
    store.writeState(seriesId, episodeId, next.withActiveRun(null));
  }

  DramaRun _newRun(String seriesId, String episodeId, DramaStep step) {
    _seq += 1;
    return DramaRun(
      id: 'run-${_now().microsecondsSinceEpoch}-$_seq',
      seriesId: seriesId,
      episodeId: episodeId,
      step: step,
    );
  }

  Future<void> _execute({
    required DramaRun run,
    required DramaSeries series,
    required DramaEpisode episode,
    required Storyboard? board,
    required Map<String, Object?>? planJson,
    required List<String> castIds,
    required List<String> shotIds,
    required DramaRunTarget target,
    required bool force,
  }) async {
    var state = store.readState(run.seriesId, run.episodeId);
    state = _startStep(state, run);
    store.writeState(run.seriesId, run.episodeId, state);
    var status = DramaStatus.running;
    String? error;
    try {
      switch (run.step) {
        case DramaStep.cast:
          final result = await _runCast(
            run: run,
            series: series,
            board: board,
            castIds: castIds,
            force: force,
            state: state,
          );
          state = result.state;
          status = result.status;
          error = result.error;
        case DramaStep.frame:
          // Task 11 实现；这里保留显式失败，避免假完成。
          status = DramaStatus.failed;
          error = '画面执行器尚未接入';
        default:
          status = DramaStatus.failed;
          error = '该工序尚未接入';
      }
    } on ConfigException catch (e) {
      status = DramaStatus.failed;
      error = '未配置 DASHSCOPE_API_KEY：${e.message}';
      run.logs.add(error);
    } on Object catch (e) {
      status = DramaStatus.failed;
      error = '$e';
      run.logs.add('失败：$e');
    }

    state = _finishStep(state, run, status, error);
    store.writeState(run.seriesId, run.episodeId, state);
    run.actualYuan = state.actualYuan;
    final runStatus = switch (status) {
      DramaStatus.failed => DramaRunStatus.failed,
      DramaStatus.interrupted => DramaRunStatus.cancelled,
      _ => DramaRunStatus.completed,
    };
    run.finish(runStatus, error: error);
    _runs.finish(run);
  }

  Future<({DramaEpisodeState state, DramaStatus status, String? error})>
  _runCast({
    required DramaRun run,
    required DramaSeries series,
    required Storyboard? board,
    required List<String> castIds,
    required bool force,
    required DramaEpisodeState state,
  }) async {
    var currentSeries = series;
    var currentState = state;
    final ids = castIds.isEmpty
        ? _referencedSpeakers(board)
        : castIds;
    final model = series.defaults.castImageModel;
    const size = '1K';
    var failed = 0;
    String? error;

    for (final id in ids) {
      if (run.cancelRequested) break;
      final member = currentSeries.cast[id];
      if (member == null) {
        run.items.add(
          DramaRunItem(
            id: id,
            kind: 'cast',
            status: DramaStatus.failed,
            error: '角色不存在',
          ),
        );
        failed += 1;
        continue;
      }
      final hash = dramaCastHash(member: member, model: model, size: size);
      if (!force && _castCached(currentSeries, member, hash)) {
        run.items.add(
          DramaRunItem(
            id: id,
            kind: 'cast',
            status: DramaStatus.skipped,
            path: member.avatar?.path,
          ),
        );
        run.logs.add('跳过 $id（缓存命中）');
        continue;
      }
      try {
        final result = await gateway.generateImage(
          model: model,
          mode: ImageMode.t2i,
          prompt: _castPrompt(member),
          baseDir: '${store.seriesDir(run.seriesId)}/cast/$id',
          contentId: hash,
          size: size,
          onLog: run.logs.add,
        );
        final fileName = File(result.path).uri.pathSegments.last;
        final relative = 'cast/$id/$hash/$fileName';
        final avatar = DramaCastAvatar(
          path: relative,
          sourceHash: hash,
          model: model,
          costYuan: result.costYuan,
          approved: false,
        );
        currentSeries = currentSeries.withCastMember(
          member.copyWith(avatar: avatar),
        );
        store.writeSeries(currentSeries);
        currentState = currentState.withActualYuan(
          currentState.actualYuan + result.costYuan,
        );
        store.writeState(run.seriesId, run.episodeId, currentState);
        run.items.add(
          DramaRunItem(
            id: id,
            kind: 'cast',
            status: DramaStatus.succeeded,
            path: relative,
            costYuan: result.costYuan,
          ),
        );
        run.logs.add('完成 $id：$relative');
      } on ConfigException catch (e) {
        error = '未配置 DASHSCOPE_API_KEY：${e.message}';
        run.logs.add(error);
        failed += 1;
        break;
      } on Object catch (e) {
        failed += 1;
        run.items.add(
          DramaRunItem(
            id: id,
            kind: 'cast',
            status: DramaStatus.failed,
            error: '$e',
          ),
        );
        run.logs.add('失败 $id：$e');
      }
    }

    if (run.cancelRequested) {
      return (state: currentState, status: DramaStatus.interrupted, error: null);
    }
    if (error != null) {
      return (state: currentState, status: DramaStatus.failed, error: error);
    }
    return (
      state: currentState,
      status: failed == 0 ? DramaStatus.succeeded : DramaStatus.failed,
      error: failed == 0 ? null : '$failed 个角色生成失败',
    );
  }

  Set<String> _referencedSpeakers(Storyboard? board) {
    final out = <String>{};
    for (final shot in board?.shots ?? const <Shot>[]) {
      final speaker = shot.speaker;
      if (speaker != null && speaker.trim().isNotEmpty) out.add(speaker);
    }
    return out;
  }

  bool _castCached(DramaSeries series, DramaCastMember member, String hash) {
    final avatar = member.avatar;
    if (avatar == null || avatar.sourceHash != hash) return false;
    return store.seriesAssetFile(series.seriesId, avatar.path).existsSync();
  }

  static String _castPrompt(DramaCastMember member) =>
      '角色定妆：${member.name}。${member.description}。'
      '竖屏半身像，统一暖色电影光，简洁背景，便于全季复用。';

  DramaEpisodeState _startStep(DramaEpisodeState state, DramaRun run) {
    final key = dramaStepKey(run.step);
    final previous = state.steps[key];
    return state
        .withActiveRun(run.id)
        .withStep(
          key,
          DramaStepRun(
            status: DramaStatus.running,
            attempts: (previous?.attempts ?? 0) + 1,
            logs: previous?.logs ?? const <String>[],
          ),
        );
  }

  DramaEpisodeState _finishStep(
    DramaEpisodeState state,
    DramaRun run,
    DramaStatus status,
    String? error,
  ) {
    final key = dramaStepKey(run.step);
    final previous = state.steps[key];
    return state
        .withActiveRun(null)
        .withStep(
          key,
          DramaStepRun(
            status: status,
            attempts: previous?.attempts ?? 1,
            error: error,
            logs: run.logs,
          ),
        );
  }
}
