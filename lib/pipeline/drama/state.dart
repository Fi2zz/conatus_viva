/// 短剧一集的运行状态：工序、镜头产物、成本与活跃任务。
///
/// 工序状态**不在这里推导**：`steps.dart` 从产物与 `state.json` 推导。
/// 本文件只负责稳定序列化、默认值与原子状态的最小表达。
library;

import '../errors.dart';
import 'json.dart';

/// 产物 / 工序状态。
enum DramaStatus {
  pending,
  running,
  succeeded,
  failed,
  stale,
  skipped,
  interrupted,
}

/// 8 个工序的 wire key，顺序与原型一致。
const List<String> kDramaStepKeys = <String>[
  'split',
  'story',
  'cast',
  'board',
  'frame',
  'voice',
  'edit',
  'pack',
];

DramaStatus dramaStatusFromWire(String? raw) {
  for (final status in DramaStatus.values) {
    if (status.name == raw) return status;
  }
  return DramaStatus.pending;
}

/// 单个产物（首帧 / 视频 / 音频 / 定妆图）。
class DramaArtifact {
  const DramaArtifact({
    this.status = DramaStatus.pending,
    this.path,
    this.sourceHash,
    this.model,
    this.costYuan,
    this.durationS,
    this.error,
  });

  final DramaStatus status;
  final String? path;
  final String? sourceHash;
  final String? model;
  final double? costYuan;
  final double? durationS;
  final String? error;

  static DramaArtifact fromJson(Object? raw) {
    if (raw == null) return const DramaArtifact();
    final json = asJsonMap(raw, 'artifact');
    return DramaArtifact(
      status: dramaStatusFromWire(optionalJsonString(json['status'], 'artifact.status')),
      path: optionalJsonString(json['path'], 'artifact.path'),
      sourceHash: optionalJsonString(json['source_hash'], 'artifact.source_hash'),
      model: optionalJsonString(json['model'], 'artifact.model'),
      costYuan: optionalJsonNumber(json['cost_yuan'], 'artifact.cost_yuan'),
      durationS: optionalJsonNumber(json['duration_s'], 'artifact.duration_s'),
      error: optionalJsonString(json['error'], 'artifact.error'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status.name,
    'path': path,
    'source_hash': sourceHash,
    'model': model,
    'cost_yuan': costYuan,
    'duration_s': durationS,
    'error': error,
  };
}

/// 人审记录（P3 使用）。
class DramaReview {
  const DramaReview({this.status = 'pending', this.note});

  final String status;
  final String? note;

  static DramaReview fromJson(Object? raw) {
    if (raw == null) return const DramaReview();
    final json = asJsonMap(raw, 'review');
    return DramaReview(
      status: optionalJsonString(json['status'], 'review.status') ?? 'pending',
      note: optionalJsonString(json['note'], 'review.note'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status,
    'note': note,
  };
}

/// 单镜产物集合。
class DramaShotState {
  const DramaShotState({
    this.frame = const DramaArtifact(),
    this.clip = const DramaArtifact(),
    this.audio = const DramaArtifact(),
    this.review = const DramaReview(),
  });

  final DramaArtifact frame;
  final DramaArtifact clip;
  final DramaArtifact audio;
  final DramaReview review;

  static DramaShotState fromJson(Object? raw) {
    if (raw == null) return const DramaShotState();
    final json = asJsonMap(raw, 'shot');
    return DramaShotState(
      frame: DramaArtifact.fromJson(json['frame']),
      clip: DramaArtifact.fromJson(json['clip']),
      audio: DramaArtifact.fromJson(json['audio']),
      review: DramaReview.fromJson(json['review']),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'frame': frame.toJson(),
    'clip': clip.toJson(),
    'audio': audio.toJson(),
    'review': review.toJson(),
  };
}

/// 一个工序最近一次运行的状态与日志。
class DramaStepRun {
  DramaStepRun({
    this.status = DramaStatus.pending,
    this.attempts = 0,
    this.error,
    List<String> logs = const <String>[],
  }) : logs = logs.length > 200 ? logs.sublist(logs.length - 200) : List<String>.unmodifiable(logs);

  final DramaStatus status;
  final int attempts;
  final String? error;
  final List<String> logs;

  static DramaStepRun fromJson(Object? raw) {
    if (raw == null) return DramaStepRun();
    final json = asJsonMap(raw, 'step');
    final rawLogs = json['logs'];
    final logs = rawLogs == null
        ? const <String>[]
        : <String>[
            for (final line in asJsonList(rawLogs, 'step.logs'))
              requireJsonString(line, 'step.logs[]'),
          ];
    final attempts = optionalJsonInt(json['attempts'], 'step.attempts') ?? 0;
    return DramaStepRun(
      status: dramaStatusFromWire(optionalJsonString(json['status'], 'step.status')),
      attempts: attempts < 0 ? 0 : attempts,
      error: optionalJsonString(json['error'], 'step.error'),
      logs: logs,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'status': status.name,
    'attempts': attempts,
    'error': error,
    'logs': logs,
  };
}

/// 一集的完整状态。
class DramaEpisodeState {
  const DramaEpisodeState({
    required this.seriesId,
    required this.episodeId,
    required this.storyboardHash,
    required this.planHash,
    required this.steps,
    required this.shots,
    required this.activeRunId,
    required this.actualYuan,
    required this.estimatedRemainingYuan,
    required this.warnings,
  });

  factory DramaEpisodeState.empty(String seriesId, String episodeId) =>
      DramaEpisodeState(
        seriesId: seriesId,
        episodeId: episodeId,
        storyboardHash: null,
        planHash: null,
        steps: <String, DramaStepRun>{
          for (final key in kDramaStepKeys) key: DramaStepRun(),
        },
        shots: const <String, DramaShotState>{},
        activeRunId: null,
        actualYuan: 0,
        estimatedRemainingYuan: 0,
        warnings: const <String>[],
      );

  final String seriesId;
  final String episodeId;
  final String? storyboardHash;
  final String? planHash;
  final Map<String, DramaStepRun> steps;
  final Map<String, DramaShotState> shots;
  final String? activeRunId;
  final double actualYuan;
  final double estimatedRemainingYuan;
  final List<String> warnings;

  static DramaEpisodeState fromJson(Map<String, Object?> json) {
    final seriesId = requireJsonString(json['series_id'], 'series_id');
    final episodeId = requireJsonString(json['episode_id'], 'episode_id');
    final rawSteps = json['steps'];
    final steps = <String, DramaStepRun>{
      for (final key in kDramaStepKeys) key: DramaStepRun(),
    };
    if (rawSteps != null) {
      for (final entry in asJsonMap(rawSteps, 'steps').entries) {
        steps[entry.key] = DramaStepRun.fromJson(entry.value);
      }
    }
    final rawShots = json['shots'];
    final shots = <String, DramaShotState>{};
    if (rawShots != null) {
      for (final entry in asJsonMap(rawShots, 'shots').entries) {
        shots[entry.key] = DramaShotState.fromJson(entry.value);
      }
    }
    final warnings = <String>[];
    final rawWarnings = json['warnings'];
    if (rawWarnings != null) {
      for (final line in asJsonList(rawWarnings, 'warnings')) {
        warnings.add(requireJsonString(line, 'warnings[]'));
      }
    }
    return DramaEpisodeState(
      seriesId: seriesId,
      episodeId: episodeId,
      storyboardHash: optionalJsonString(json['storyboard_hash'], 'storyboard_hash'),
      planHash: optionalJsonString(json['plan_hash'], 'plan_hash'),
      steps: Map<String, DramaStepRun>.unmodifiable(steps),
      shots: Map<String, DramaShotState>.unmodifiable(shots),
      activeRunId: optionalJsonString(json['active_run'], 'active_run'),
      actualYuan: _costDouble(json, 'actual_yuan'),
      estimatedRemainingYuan: _costDouble(json, 'estimated_remaining_yuan'),
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  DramaEpisodeState withPlanHash(String? hash) => DramaEpisodeState(
    seriesId: seriesId,
    episodeId: episodeId,
    storyboardHash: storyboardHash,
    planHash: hash,
    steps: steps,
    shots: shots,
    activeRunId: activeRunId,
    actualYuan: actualYuan,
    estimatedRemainingYuan: estimatedRemainingYuan,
    warnings: warnings,
  );

  DramaEpisodeState withStoryboardHash(String? hash) => DramaEpisodeState(
    seriesId: seriesId,
    episodeId: episodeId,
    storyboardHash: hash,
    planHash: planHash,
    steps: steps,
    shots: shots,
    activeRunId: activeRunId,
    actualYuan: actualYuan,
    estimatedRemainingYuan: estimatedRemainingYuan,
    warnings: warnings,
  );

  DramaEpisodeState withStep(String key, DramaStepRun run) {
    if (!kDramaStepKeys.contains(key)) {
      throw PipelineError(ErrorClass.fatal, '未知工序：$key');
    }
    return DramaEpisodeState(
      seriesId: seriesId,
      episodeId: episodeId,
      storyboardHash: storyboardHash,
      planHash: planHash,
      steps: <String, DramaStepRun>{...steps, key: run},
      shots: shots,
      activeRunId: activeRunId,
      actualYuan: actualYuan,
      estimatedRemainingYuan: estimatedRemainingYuan,
      warnings: warnings,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'series_id': seriesId,
    'episode_id': episodeId,
    'storyboard_hash': storyboardHash,
    'plan_hash': planHash,
    'steps': <String, Object?>{
      for (final entry in steps.entries) entry.key: entry.value.toJson(),
    },
    'shots': <String, Object?>{
      for (final entry in shots.entries) entry.key: entry.value.toJson(),
    },
    'active_run': activeRunId,
    'cost': <String, Object?>{
      'actual_yuan': actualYuan,
      'estimated_remaining_yuan': estimatedRemainingYuan,
    },
    'warnings': warnings,
  };
}

double _costDouble(Map<String, Object?> json, String key) {
  final rawCost = json['cost'];
  if (rawCost is Map) {
    return optionalJsonNumber(rawCost[key], 'cost.$key') ?? 0;
  }
  return optionalJsonNumber(json[key], key) ?? 0;
}
