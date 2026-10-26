/// 从 `plan.json` 的展示字段读取路由、i2v 秒数与时长（纯函数）。
library;

import '../render_plan.dart';

class DramaPlanView {
  DramaPlanView(Map<String, Object?> json) {
    final rawShots = json['shots'];
    if (rawShots is! List) return;
    for (final raw in rawShots) {
      if (raw is! Map) continue;
      final id = raw['shot_id'];
      if (id is! String || id.isEmpty) continue;
      _shots[id] = <String, Object?>{
        for (final entry in raw.entries)
          if (entry.key is String) entry.key as String: entry.value,
      };
    }
  }

  final Map<String, Map<String, Object?>> _shots =
      <String, Map<String, Object?>>{};

  Map<String, Object?>? _shot(String shotId) => _shots[shotId];

  ShotRoute routeFor(String shotId) {
    final raw = _shot(shotId)?['route'];
    if (raw is! String) return ShotRoute.micro;
    for (final route in ShotRoute.values) {
      if (route.name == raw) return route;
    }
    return ShotRoute.micro;
  }

  int i2vSecondsFor(String shotId) {
    final raw = _shot(shotId)?['i2v_seconds'];
    if (raw is int) return raw < 0 ? 0 : raw;
    if (raw is num) return raw <= 0 ? 0 : raw.toInt();
    return 0;
  }

  double durationFor(String shotId) {
    final raw = _shot(shotId)?['duration_s'];
    if (raw is num && raw.isFinite && raw > 0) return raw.toDouble();
    return 2.0;
  }
}
