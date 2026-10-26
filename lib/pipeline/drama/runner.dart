/// 顺序执行器：逐项调用媒体网关、逐项落盘、单项失败不中断整批。
library;

import 'dart:async';
import 'dart:io';

import '../config.dart';
import '../generation_models.dart';
import '../render_plan.dart';
import '../storyboard.dart';
import 'episode.dart';
import 'hashes.dart';
import 'media_gateway.dart';
import 'plan_view.dart';
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
    if (step == DramaStep.frame) {
      if (board == null) {
        throw StateError('storyboard_required');
      }
      if (target != DramaRunTarget.frame && planJson == null) {
        throw StateError('plan_required');
      }
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
        degrade: false,
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
    final active = _runs.activeFor(seriesId, episodeId);
    if (active != null) throw StateError('episode_busy');
    final series = store.readSeries(seriesId);
    final episode = store.readEpisode(seriesId, episodeId);
    final board = store.readStoryboard(seriesId, episodeId);
    final planJson = store.readPlanJson(seriesId, episodeId);
    if (board == null) throw StateError('storyboard_required');
    if (target != DramaRunTarget.frame && planJson == null) {
      throw StateError('plan_required');
    }
    if (!board.shots.any((shot) => shot.id == shotId)) {
      throw ArgumentError.value(shotId, 'shot_id', 'unknown shot');
    }
    final run = _newRun(seriesId, episodeId, DramaStep.frame);
    _runs.add(run);
    unawaited(
      _execute(
        run: run,
        series: series,
        episode: episode,
        board: board,
        planJson: planJson,
        castIds: const <String>[],
        shotIds: <String>[shotId],
        target: target,
        force: force,
        degrade: degrade,
      ),
    );
    return run;
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
    required bool degrade,
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
          final result = await _runFrame(
            run: run,
            series: series,
            board: board!,
            planJson: planJson,
            shotIds: shotIds,
            target: target,
            force: force,
            degrade: degrade,
            state: state,
          );
          state = result.state;
          status = result.status;
          error = result.error;
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

  Future<({DramaEpisodeState state, DramaStatus status, String? error})>
  _runFrame({
    required DramaRun run,
    required DramaSeries series,
    required Storyboard board,
    required Map<String, Object?>? planJson,
    required List<String> shotIds,
    required DramaRunTarget target,
    required bool force,
    required bool degrade,
    required DramaEpisodeState state,
  }) async {
    var currentState = state;
    final plan = planJson == null ? null : DramaPlanView(planJson);
    final selected = shotIds.isEmpty
        ? board.shots
        : <Shot>[
            for (final id in shotIds)
              board.shots.firstWhere(
                (shot) => shot.id == id,
                orElse: () => throw ArgumentError.value(id, 'shot_id', 'unknown shot'),
              ),
          ];
    final wantFrame =
        target == DramaRunTarget.frame || target == DramaRunTarget.all;
    final wantClip =
        target == DramaRunTarget.clip || target == DramaRunTarget.all;
    final width = series.frame.width;
    final height = series.frame.height;
    final frameModel = series.defaults.frameImageModel;
    final clipModel = series.defaults.clipVideoModel;
    final resolution = series.defaults.resolution;
    const size = '1K';
    var failed = 0;
    String? error;

    for (final shot in selected) {
      if (run.cancelRequested) break;
      final avatar = shot.speaker == null
          ? null
          : series.cast[shot.speaker]?.avatar;
      final approved = avatar != null && avatar.approved;
      final avatarHash = approved ? avatar.sourceHash : null;
      final frameHash = dramaFrameHash(
        shot: shot,
        castAvatarHash: avatarHash,
        model: frameModel,
        size: size,
      );
      var shotState = currentState.shots[shot.id] ?? const DramaShotState();
      final route = plan == null
          ? ShotRoute.micro
          : (degrade ? ShotRoute.kenburns : plan.routeFor(shot.id));
      final isT2v = route == ShotRoute.t2v;
      final frameCached = isT2v
          ? true
          : _frameCached(
              seriesId: run.seriesId,
              episodeId: run.episodeId,
              shotId: shot.id,
              hash: frameHash,
              state: currentState,
            );
      final needFrame = !frameCached || (force && wantFrame);

      if (!isT2v && needFrame) {
        try {
          final refs = approved
              ? <File>[store.seriesAssetFile(series.seriesId, avatar.path)]
              : const <File>[];
          final result = await gateway.generateImage(
            model: frameModel,
            mode: refs.isEmpty ? ImageMode.t2i : ImageMode.i2i,
            prompt: _framePrompt(shot),
            baseDir: '${store.episodeDir(run.seriesId, run.episodeId)}'
                '/assets/frames/${shot.id}',
            contentId: frameHash,
            refFiles: refs,
            size: size,
            onLog: run.logs.add,
          );
          final fileName = File(result.path).uri.pathSegments.last;
          final relative = 'assets/frames/${shot.id}/$frameHash/$fileName';
          final frame = DramaArtifact(
            status: DramaStatus.succeeded,
            path: relative,
            sourceHash: frameHash,
            model: frameModel,
            costYuan: result.costYuan,
          );
          shotState = _withFrame(shotState, frame);
          currentState = currentState
              .withShot(shot.id, shotState)
              .withActualYuan(currentState.actualYuan + result.costYuan);
          store.writeState(run.seriesId, run.episodeId, currentState);
          run.items.add(
            DramaRunItem(
              id: shot.id,
              kind: 'frame',
              status: DramaStatus.succeeded,
              path: relative,
              costYuan: result.costYuan,
            ),
          );
          run.logs.add('首帧 ${shot.id} 完成：$relative');
        } on ConfigException catch (e) {
          error = '未配置 DASHSCOPE_API_KEY：${e.message}';
          run.logs.add(error);
          failed += 1;
          break;
        } on Object catch (e) {
          failed += 1;
          shotState = _withFrame(
            shotState,
            DramaArtifact(status: DramaStatus.failed, error: '$e'),
          );
          currentState = currentState.withShot(shot.id, shotState);
          store.writeState(run.seriesId, run.episodeId, currentState);
          run.items.add(
            DramaRunItem(
              id: shot.id,
              kind: 'frame',
              status: DramaStatus.failed,
              error: '$e',
            ),
          );
          run.logs.add('首帧 ${shot.id} 失败：$e');
          continue;
        }
      } else if (!isT2v && wantFrame) {
        run.items.add(
          DramaRunItem(
            id: shot.id,
            kind: 'frame',
            status: DramaStatus.skipped,
            path: shotState.frame.path,
          ),
        );
        run.logs.add('跳过首帧 ${shot.id}（缓存命中）');
      }

      if (!wantClip) continue;
      final frame = shotState.frame;
      if (!isT2v &&
          (frame.status != DramaStatus.succeeded || frame.path == null)) {
        continue;
      }
      final rawSeconds = plan!.i2vSecondsFor(shot.id);
      final i2vSeconds = route == ShotRoute.i2v
          ? (rawSeconds < 2 ? 2 : rawSeconds)
          : 0;
      final t2vSeconds = route == ShotRoute.t2v
          ? plan.durationFor(shot.id).ceil().clamp(2, 10)
          : 0;
      final clipHash = dramaClipHash(
        shot: shot,
        frameHash: frameHash,
        route: route.name,
        model: route == ShotRoute.i2v
            ? clipModel
            : (route == ShotRoute.t2v ? series.defaults.t2vModel : 'ffmpeg'),
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
      if (!force &&
          (_clipCached(
                seriesId: run.seriesId,
                episodeId: run.episodeId,
                shotId: shot.id,
                hash: clipHash,
                state: currentState,
              ) ||
              (degradedHash != null &&
                  _clipCached(
                    seriesId: run.seriesId,
                    episodeId: run.episodeId,
                    shotId: shot.id,
                    hash: degradedHash,
                    state: currentState,
                  )))) {
        run.items.add(
          DramaRunItem(
            id: shot.id,
            kind: route == ShotRoute.i2v
                ? 'clip'
                : (route == ShotRoute.t2v ? 't2v' : 'local_clip'),
            status: DramaStatus.skipped,
            path: shotState.clip.path,
          ),
        );
        run.logs.add('跳过片段 ${shot.id}（缓存命中）');
        continue;
      }
      try {
        final relative = 'assets/clips/${shot.id}/$clipHash.mp4';
        final outFile = store.assetFile(run.seriesId, run.episodeId, relative);
        DramaMediaResult result;
        if (route == ShotRoute.t2v) {
          final raw = File('${outFile.path}.raw.mp4');
          result = await gateway.generateT2vClip(
            model: series.defaults.t2vModel,
            resolution: resolution,
            prompt: (shot.visual ?? '').trim().isEmpty
                ? _framePrompt(shot)
                : shot.visual!,
            durationS: t2vSeconds,
            outFile: raw,
            onLog: run.logs.add,
          );
          await gateway.normalizeClip(
            input: raw,
            outFile: outFile,
            width: width,
            height: height,
          );
          if (raw.existsSync()) raw.deleteSync();
        } else if (route == ShotRoute.i2v) {
          final raw = File('${outFile.path}.raw.mp4');
          final frameFile = store.assetFile(
            run.seriesId,
            run.episodeId,
            frame.path!,
          );
          result = await gateway.generateI2vClip(
            model: clipModel,
            resolution: resolution,
            firstFrame: frameFile,
            prompt: shot.motion ?? '',
            durationS: i2vSeconds,
            outFile: raw,
            onLog: run.logs.add,
          );
          await gateway.normalizeClip(
            input: raw,
            outFile: outFile,
            width: width,
            height: height,
          );
          if (raw.existsSync()) raw.deleteSync();
        } else {
          final duration = plan.durationFor(shot.id).ceil();
          final frameFile = store.assetFile(
            run.seriesId,
            run.episodeId,
            frame.path!,
          );
          await gateway.renderLocalClip(
            image: frameFile,
            outFile: outFile,
            route: route,
            width: width,
            height: height,
            durationS: duration,
          );
          result = DramaMediaResult(
            path: outFile.path,
            costYuan: 0,
            model: 'ffmpeg',
            durationS: duration.toDouble(),
          );
        }
        final clip = DramaArtifact(
          status: DramaStatus.succeeded,
          path: relative,
          sourceHash: clipHash,
          model: result.model,
          costYuan: result.costYuan,
          durationS: result.durationS,
        );
        shotState = _withClip(shotState, clip);
        currentState = currentState
            .withShot(shot.id, shotState)
            .withActualYuan(currentState.actualYuan + result.costYuan);
        store.writeState(run.seriesId, run.episodeId, currentState);
        run.items.add(
          DramaRunItem(
            id: shot.id,
            kind: route == ShotRoute.i2v
                ? 'clip'
                : (route == ShotRoute.t2v ? 't2v' : 'local_clip'),
            status: DramaStatus.succeeded,
            path: relative,
            costYuan: result.costYuan,
          ),
        );
        run.logs.add('片段 ${shot.id} 完成：$relative');
      } on ConfigException catch (e) {
        error = '未配置 DASHSCOPE_API_KEY：${e.message}';
        run.logs.add(error);
        failed += 1;
        break;
      } on Object catch (e) {
        failed += 1;
        shotState = _withClip(
          shotState,
          DramaArtifact(status: DramaStatus.failed, error: '$e'),
        );
        currentState = currentState.withShot(shot.id, shotState);
        store.writeState(run.seriesId, run.episodeId, currentState);
        run.items.add(
          DramaRunItem(
            id: shot.id,
            kind: route == ShotRoute.i2v
                ? 'clip'
                : (route == ShotRoute.t2v ? 't2v' : 'local_clip'),
            status: DramaStatus.failed,
            error: '$e',
          ),
        );
        run.logs.add('片段 ${shot.id} 失败：$e');
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
      error: failed == 0 ? null : '$failed 个镜头生成失败',
    );
  }

  DramaShotState _withFrame(DramaShotState current, DramaArtifact frame) =>
      DramaShotState(
        frame: frame,
        clip: current.clip,
        audio: current.audio,
        review: current.review,
      );

  DramaShotState _withClip(DramaShotState current, DramaArtifact clip) =>
      DramaShotState(
        frame: current.frame,
        clip: clip,
        audio: current.audio,
        review: current.review,
      );

  bool _frameCached({
    required String seriesId,
    required String episodeId,
    required String shotId,
    required String hash,
    required DramaEpisodeState state,
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
    required String seriesId,
    required String episodeId,
    required String shotId,
    required String hash,
    required DramaEpisodeState state,
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

  static String _framePrompt(Shot shot) {
    final visual = (shot.visual ?? '').trim();
    final base = visual.isEmpty ? shot.line.trim() : visual;
    if (base.isEmpty) {
      return '${shot.framing}，${shotKindToWire(shot.kind)}，竖屏电影感画面';
    }
    return '$base。竖屏电影感画面，${shot.framing}';
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
