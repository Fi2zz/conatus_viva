import 'dart:convert';
import 'dart:io';

import 'errors.dart';

/// Step-level status: `pending → running → succeeded | failed`
/// (spec §6 状态与迁移; `skipped` is implied by artifact presence).
enum StepStatus { pending, running, succeeded, failed }

/// Segment-level status for step 05 render: `pending → submitted →
/// downloading → succeeded`, bypass to `failed` / `degraded`
/// (spec §6 状态与迁移).
enum SegmentStatus {
  pending,
  submitted,
  downloading,
  succeeded,
  failed,
  degraded,
}

/// Cost accounting for one content run (spec §6 `cost` block).
///
/// [recordI2vSeconds] is the only mutator, so the invariant
/// `estimatedYuan = i2vSecondsTotal * 0.15` always holds; loading re-derives
/// the estimate from the total so a hand-edited file cannot drift.
class CostInfo {
  CostInfo({
    this.i2vSecondsTotal = 0,
    this.estimatedYuan = 0,
    this.degradedCount = 0,
  });

  /// 万相 i2v 计费单价（元 / 秒）。
  static const double yuanPerSecond = 0.15;

  int i2vSecondsTotal;
  double estimatedYuan;
  int degradedCount;

  /// Accumulates billed i2v seconds (called by the render step).
  void recordI2vSeconds(int seconds) {
    i2vSecondsTotal += seconds;
    estimatedYuan = i2vSecondsTotal * yuanPerSecond;
  }

  void recordDegraded() {
    degradedCount += 1;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'i2v_seconds_total': i2vSecondsTotal,
    'estimated_yuan': estimatedYuan,
    'degraded_count': degradedCount,
  };

  static CostInfo fromJson(Map<String, dynamic> json) {
    final total = json['i2v_seconds_total'];
    final degraded = json['degraded_count'];
    final seconds = total is num ? total.toInt() : 0;
    return CostInfo(
      i2vSecondsTotal: seconds,
      estimatedYuan: seconds * CostInfo.yuanPerSecond,
      degradedCount: degraded is num ? degraded.toInt() : 0,
    );
  }
}

/// A pipeline step record: `pending → running → succeeded | failed`
/// (spec §6 状态与迁移). `skipped` is implied by artifact presence, not state.
class StepState {
  StepState({
    this.status = StepStatus.pending,
    this.attempts = 0,
    List<String>? t,
    this.error,
  }) : t = t ?? <String>[];

  StepStatus status;
  int attempts;

  /// Timeline labels recorded as the step progresses (e.g. `start`, `end`).
  List<String> t;
  PipelineError? error;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'status': status.name,
    'attempts': attempts,
    't': t,
    'error': error?.toJson(),
  };

  static StepState fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final attempts = json['attempts'];
    return StepState(
      status: status == null
          ? StepStatus.pending
          : _enumByName(StepStatus.values, status, 'step status'),
      attempts: attempts is num ? attempts.toInt() : 0,
      t: _stringList(json['t'], 'step t'),
      error: _error(json['error']),
    );
  }
}

/// One segment of step 05 render:
/// `pending → submitted → downloading → succeeded`, bypass to `failed` /
/// `degraded` (spec §6 状态与迁移).
class SegmentState {
  SegmentState({
    required this.i,
    this.route = routeI2v,
    required this.audioS,
    required this.durationS,
    this.status = SegmentStatus.pending,
    this.attempts = 0,
    this.taskId,
    this.submittedAt,
    this.costSeconds = 0,
    this.error,
  });

  static const String routeI2v = 'i2v';
  static const String routeKenburns = 'kenburns';

  int i;
  String route;
  double audioS;
  int durationS;
  SegmentStatus status;
  int attempts;
  String? taskId;

  /// ISO-8601 timestamp of the last submission; read only via
  /// [resumableTask].
  String? submittedAt;

  /// Billed i2v seconds for this segment (0 for Ken Burns and after
  /// [markDegraded]).
  int costSeconds;
  PipelineError? error;

  /// Records a submitted i2v task. Costs are counted at submission (the
  /// provider bills on generation; official failures are not re-billed, so
  /// over-reporting here is the safe direction for the budget guard).
  void markSubmitted(String taskId, {DateTime? now}) {
    this.taskId = taskId;
    submittedAt = (now ?? DateTime.now()).toIso8601String();
    status = SegmentStatus.submitted;
    attempts += 1;
    if (route == routeI2v) costSeconds = durationS;
  }

  void markDownloading() {
    status = SegmentStatus.downloading;
  }

  void markSucceeded() {
    status = SegmentStatus.succeeded;
  }

  /// Audit rejection: never retry, fall back to Ken Burns at zero cost.
  /// [reason] is stored as an [ErrorClass.auditReject] error.
  void markDegraded(String reason) {
    status = SegmentStatus.degraded;
    route = routeKenburns;
    costSeconds = 0;
    error = PipelineError(ErrorClass.auditReject, reason);
  }

  void markFailed(ErrorClass cls, String message) {
    status = SegmentStatus.failed;
    error = PipelineError(cls, message);
  }

  /// The ONLY entry point for `stale_task` detection (spec §6): returns the
  /// persisted task id when it exists and [submittedAt] is strictly less than
  /// 24h before [now]; otherwise null (caller then resubmits or degrades).
  String? resumableTask({required DateTime now}) {
    final id = taskId;
    if (id == null) return null;
    final at = submittedAt;
    if (at == null) return null;
    final submitted = DateTime.tryParse(at);
    if (submitted == null) return null;
    if (now.isBefore(submitted.add(const Duration(hours: 24)))) return id;
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'i': i,
    'route': route,
    'audio_s': audioS,
    'duration_s': durationS,
    'status': status.name,
    'attempts': attempts,
    if (taskId != null) 'i2v': {'task_id': taskId, 'submitted_at': submittedAt},
    'cost_seconds': costSeconds,
    if (error != null) 'error': error!.toJson(),
  };

  static SegmentState fromJson(Map<String, dynamic> json) {
    final index = json['i'];
    final audioS = json['audio_s'];
    final durationS = json['duration_s'];
    final routeValue = json['route'];
    if (index is! int || audioS is! num || durationS is! int) {
      throw FormatException('segment must have numeric i/audio_s/duration_s');
    }
    if (routeValue is! String ||
        (routeValue != routeI2v && routeValue != routeKenburns)) {
      throw FormatException('invalid segment route: $routeValue');
    }
    String? taskId;
    String? submittedAt;
    final i2v = json['i2v'];
    if (i2v != null) {
      if (i2v is! Map<String, dynamic>) {
        throw FormatException('segment i2v must be an object');
      }
      final id = i2v['task_id'];
      final at = i2v['submitted_at'];
      if (id != null && id is! String) {
        throw FormatException('i2v.task_id must be a string');
      }
      if (at != null && at is! String) {
        throw FormatException('i2v.submitted_at must be a string');
      }
      taskId = id as String?;
      submittedAt = at as String?;
    }
    final status = json['status'];
    final attempts = json['attempts'];
    final costSeconds = json['cost_seconds'];
    return SegmentState(
      i: index,
      route: routeValue,
      audioS: audioS.toDouble(),
      durationS: durationS,
      status: status == null
          ? SegmentStatus.pending
          : _enumByName(SegmentStatus.values, status, 'segment status'),
      attempts: attempts is num ? attempts.toInt() : 0,
      taskId: taskId,
      submittedAt: submittedAt,
      costSeconds: costSeconds is num ? costSeconds.toInt() : 0,
      error: _error(json['error']),
    );
  }
}

/// The six pipeline steps tracked in `state.json` (spec §6 schema).
const List<String> kPipelineStepNames = <String>[
  'classify',
  'select',
  'script',
  'tts',
  'render',
  'compose',
];

/// `state.json` state machine for one content run (spec §6).
///
/// Rerun contract: [load] reads the persisted state, callers skip
/// `succeeded` steps/segments, resume `running` ones per the error class
/// table, and execute `pending`/`failed`. All writes go through [save],
/// which publishes atomically (write `state.json.tmp`, then rename) so a
/// crash never leaves a half-written file.
class ContentState {
  ContentState._(this.dir)
    : contentId = '',
      params = <String, String>{},
      segments = <SegmentState>[],
      cost = CostInfo(),
      _steps = <String, StepState>{};

  /// Loads `$dir/state.json`. A missing file yields a fresh instance with
  /// every step in [kPipelineStepNames] pending; a corrupt file throws
  /// [PipelineError] with [ErrorClass.fatal] (fail fast, spec §6).
  factory ContentState.load(String dir) {
    final file = File('$dir/$fileName');
    if (!file.existsSync()) {
      final fresh = ContentState._(dir);
      for (final name in kPipelineStepNames) {
        fresh._steps[name] = StepState();
      }
      return fresh;
    }
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('state.json root must be a JSON object');
      }
      return ContentState._fromJson(dir, decoded);
    } on PipelineError {
      rethrow;
    } catch (e) {
      throw PipelineError(ErrorClass.fatal, 'corrupt state.json in $dir: $e');
    }
  }

  static const String fileName = 'state.json';

  /// Working directory holding `state.json` (the artifact dir).
  final String dir;
  String contentId;
  Map<String, String> params;
  List<SegmentState> segments;
  CostInfo cost;

  final Map<String, StepState> _steps;

  /// Read-only view of all step records, keyed by step name.
  Map<String, StepState> get steps =>
      Map<String, StepState>.unmodifiable(_steps);

  /// Returns the record for [name], creating a pending one on first use so
  /// additional steps (e.g. `ingest`) work without schema changes.
  StepState step(String name) => _steps.putIfAbsent(name, StepState.new);

  String get _filePath => '$dir/$fileName';

  /// Atomically publishes the state: writes `state.json.tmp`, then renames
  /// it over `state.json` (spec §6 原子发布). IO failures are reported as
  /// [PipelineError] with [ErrorClass.fatal].
  void save() {
    try {
      final directory = Directory(dir);
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }
      final tmp = File('$_filePath.tmp');
      tmp.writeAsStringSync(jsonEncode(toJson()), flush: true);
      tmp.renameSync(_filePath);
    } on PipelineError {
      rethrow;
    } catch (e) {
      throw PipelineError(ErrorClass.fatal, 'failed to save $_filePath: $e');
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'content_id': contentId,
    'params': params,
    'steps': <String, dynamic>{
      for (final entry in _steps.entries) entry.key: entry.value.toJson(),
    },
    'segments': <dynamic>[for (final s in segments) s.toJson()],
    'cost': cost.toJson(),
  };

  static ContentState _fromJson(String dir, Map<String, dynamic> json) {
    final state = ContentState._(dir);

    final contentId = json['content_id'];
    if (contentId != null) {
      if (contentId is! String) {
        throw const FormatException('content_id must be a string');
      }
      state.contentId = contentId;
    }

    final params = json['params'];
    if (params != null) {
      if (params is! Map<String, dynamic>) {
        throw const FormatException('params must be a JSON object');
      }
      for (final entry in params.entries) {
        if (entry.value is! String) {
          throw FormatException('params.${entry.key} must be a string');
        }
        state.params[entry.key] = entry.value as String;
      }
    }

    final steps = json['steps'];
    if (steps == null) {
      for (final name in kPipelineStepNames) {
        state._steps[name] = StepState();
      }
    } else {
      if (steps is! Map<String, dynamic>) {
        throw const FormatException('steps must be a JSON object');
      }
      for (final entry in steps.entries) {
        if (entry.value is! Map<String, dynamic>) {
          throw FormatException('steps.${entry.key} must be an object');
        }
        state._steps[entry.key] = StepState.fromJson(entry.value);
      }
    }

    final segments = json['segments'];
    if (segments != null) {
      if (segments is! List) {
        throw const FormatException('segments must be a JSON array');
      }
      for (final item in segments) {
        if (item is! Map<String, dynamic>) {
          throw const FormatException('segment entries must be objects');
        }
        state.segments.add(SegmentState.fromJson(item));
      }
    }

    final cost = json['cost'];
    if (cost != null) {
      if (cost is! Map<String, dynamic>) {
        throw const FormatException('cost must be a JSON object');
      }
      state.cost = CostInfo.fromJson(cost);
    }

    return state;
  }
}

// ---------------------------------------------------------------------------
// JSON helpers — anything unexpected throws, so ContentState.load can wrap it
// into a fatal PipelineError.
// ---------------------------------------------------------------------------

T _enumByName<T extends Enum>(List<T> values, Object? name, String what) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  throw FormatException('invalid $what: $name');
}

List<String> _stringList(Object? value, String what) {
  if (value == null) return <String>[];
  if (value is! List) throw FormatException('$what must be an array');
  for (final item in value) {
    if (item is! String) throw FormatException('$what must hold strings');
  }
  return List<String>.from(value);
}

PipelineError? _error(Object? value) {
  if (value == null) return null;
  if (value is! Map<String, dynamic>) {
    throw const FormatException('error must be a JSON object');
  }
  return PipelineError.fromJson(value);
}
