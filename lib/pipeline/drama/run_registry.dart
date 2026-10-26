/// 内存 run 注册表：状态与日志只活在进程内；产物与成本写 `state.json`。
library;

import 'dart:async';

import 'state.dart';
import 'steps.dart';

enum DramaRunStatus { running, completed, failed, cancelled }

class DramaRunItem {
  const DramaRunItem({
    required this.id,
    required this.kind,
    required this.status,
    this.path,
    this.costYuan,
    this.error,
  });

  final String id;
  final String kind;
  final DramaStatus status;
  final String? path;
  final double? costYuan;
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind,
    'status': status.name,
    'path': path,
    'cost_yuan': costYuan,
    'error': error,
  };
}

class DramaRun {
  DramaRun({
    required this.id,
    required this.seriesId,
    required this.episodeId,
    required this.step,
  });

  final String id;
  final String seriesId;
  final String episodeId;
  final DramaStep step;
  final List<DramaRunItem> items = <DramaRunItem>[];
  final List<String> logs = <String>[];
  DramaRunStatus status = DramaRunStatus.running;
  double actualYuan = 0;
  String? error;
  bool cancelRequested = false;

  final Completer<void> _done = Completer<void>();

  Future<void> get done => _done.future;

  bool get isRunning => status == DramaRunStatus.running;

  void finish(DramaRunStatus next, {String? error}) {
    status = next;
    this.error = error;
    if (!_done.isCompleted) _done.complete();
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'run_id': id,
    'status': status.name,
    'step': step.name,
    'items': <Object?>[for (final item in items) item.toJson()],
    'logs': List<String>.unmodifiable(logs),
    'actual_yuan': actualYuan,
    'error': error,
  };
}

class DramaRunRegistry {
  final Map<String, DramaRun> _runs = <String, DramaRun>{};
  final Map<String, String> _active = <String, String>{};

  DramaRun add(DramaRun run) {
    _prune();
    _runs[run.id] = run;
    _active[_key(run.seriesId, run.episodeId)] = run.id;
    return run;
  }

  DramaRun? get(String id) => _runs[id];

  DramaRun? activeFor(String seriesId, String episodeId) {
    final key = _key(seriesId, episodeId);
    final id = _active[key];
    if (id == null) return null;
    final run = _runs[id];
    if (run == null || !run.isRunning) {
      _active.remove(key);
      return null;
    }
    return run;
  }

  void finish(DramaRun run) {
    _active.remove(_key(run.seriesId, run.episodeId));
  }

  void cancel(String id) {
    final run = _runs[id];
    if (run != null) run.cancelRequested = true;
  }

  void _prune() {
    if (_runs.length <= 50) return;
    final removable = _runs.values
        .where((run) => !run.isRunning)
        .map((run) => run.id)
        .take(_runs.length - 50)
        .toList();
    for (final id in removable) {
      _runs.remove(id);
    }
  }

  static String _key(String seriesId, String episodeId) =>
      '$seriesId/$episodeId';
}
