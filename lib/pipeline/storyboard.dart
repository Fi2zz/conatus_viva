/// 短剧分镜表模型、解析与校验（纯 Dart，无 Flutter 依赖）。
///
/// 输入契约见实施计划 §1.1/§1.2：解析阶段只做**结构校验**（字段类型、范围、
/// 唯一性），不做时长夹取与预算分配（属于 `render_plan.dart`）。可恢复的
/// 语义问题（未知 kind / priority、speaker 不在 cast、非竖屏）降级并写入
/// [Storyboard.warnings]，不抛错；模式错误统一抛
/// `PipelineError(ErrorClass.fatal, ...)`。
///
/// 序列化是 canonical idempotent：
/// `fromJson(toJson(x)).toJson() == toJson(x)`。wire name 一律 snake_case，
/// 不使用枚举 `.name`。
library;

import 'dart:convert';

import 'errors.dart';
import 'frame.dart';

/// 镜头类型；wire name 见 [shotKindToWire]。
enum ShotKind { speakOff, insert, listenFace, action, establishing }

/// 镜头优先级；wire name 见 [shotPriorityToWire]。
///
/// 排序权重不在这里定义：`priorityRank` 属于 `render_plan.dart`。
enum ShotPriority { hook, turn, payoff, normal }

/// `ShotKind` → snake_case wire name。
String shotKindToWire(ShotKind kind) {
  switch (kind) {
    case ShotKind.speakOff:
      return 'speak_off';
    case ShotKind.insert:
      return 'insert';
    case ShotKind.listenFace:
      return 'listen_face';
    case ShotKind.action:
      return 'action';
    case ShotKind.establishing:
      return 'establishing';
  }
}

/// snake_case wire name → `ShotKind`；未知值返回 null（由调用方降级）。
ShotKind? shotKindFromWire(String raw) {
  switch (raw) {
    case 'speak_off':
      return ShotKind.speakOff;
    case 'insert':
      return ShotKind.insert;
    case 'listen_face':
      return ShotKind.listenFace;
    case 'action':
      return ShotKind.action;
    case 'establishing':
      return ShotKind.establishing;
    default:
      return null;
  }
}

/// `ShotPriority` → snake_case wire name。
String shotPriorityToWire(ShotPriority priority) {
  switch (priority) {
    case ShotPriority.hook:
      return 'hook';
    case ShotPriority.turn:
      return 'turn';
    case ShotPriority.payoff:
      return 'payoff';
    case ShotPriority.normal:
      return 'normal';
  }
}

/// snake_case wire name → `ShotPriority`；未知值返回 null（由调用方降级）。
ShotPriority? shotPriorityFromWire(String raw) {
  switch (raw) {
    case 'hook':
      return ShotPriority.hook;
    case 'turn':
      return ShotPriority.turn;
    case 'payoff':
      return ShotPriority.payoff;
    case 'normal':
      return ShotPriority.normal;
    default:
      return null;
  }
}

/// 演员表成员。`id` 是 `cast` 映射的 key，不重复写进 value。
class CastMember {
  const CastMember({
    required this.id,
    required this.name,
    this.voiceId,
    this.dialect,
  });

  final String id;
  final String name;
  final String? voiceId;
  final String? dialect;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'voice_id': voiceId,
    'dialect': dialect,
  };
}

/// 单个分镜。`durationS == null` 表示缺省，由渲染计划按台词估算。
class Shot {
  const Shot({
    required this.id,
    required this.kind,
    required this.framing,
    this.speaker,
    required this.line,
    this.durationS,
    required this.priority,
    this.prop,
    this.motion,
  });

  final String id;
  final ShotKind kind;
  final String framing;
  final String? speaker;
  final String line;
  final double? durationS;
  final ShotPriority priority;
  final String? prop;
  final String? motion;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': shotKindToWire(kind),
    'framing': framing,
    'speaker': speaker,
    'line': line,
    'duration_s': durationS,
    'priority': shotPriorityToWire(priority),
    'prop': prop,
    'motion': motion,
  };
}

/// 一集分镜表。解析产物不可变，warnings 按解析顺序累积。
class Storyboard {
  const Storyboard({
    required this.contentId,
    required this.title,
    this.dialect,
    required this.frame,
    required this.budgetYuan,
    required this.cast,
    required this.shots,
    required this.warnings,
  });

  final String contentId;
  final String title;
  final String? dialect;
  final FrameSize frame;
  final double budgetYuan;
  final Map<String, CastMember> cast;
  final List<Shot> shots;

  /// 解析期可恢复问题：未知 kind / priority、speaker 不在 cast、非竖屏。
  final List<String> warnings;

  static final RegExp _contentIdPattern = RegExp(r'^[A-Za-z0-9_-]+$');

  /// 从 JSON 文本解析；语法 / 类型错误统一包装成 `PipelineError.fatal`。
  static Storyboard fromJsonString(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw PipelineError(
        ErrorClass.fatal,
        'storyboard 不是合法 JSON：${e.message}',
      );
    }
    return fromJson(_asMap(decoded, 'storyboard'));
  }

  /// 从已解码的 JSON 对象解析；所有类型检查显式做，不泄漏 `TypeError`。
  static Storyboard fromJson(Map<String, Object?> json) {
    final warnings = <String>[];

    final contentId = _requireString(json['content_id'], 'content_id');
    if (!_contentIdPattern.hasMatch(contentId)) {
      throw PipelineError(
        ErrorClass.fatal,
        'content_id 非法：$contentId（仅允许 [A-Za-z0-9_-]）',
      );
    }

    final title = _optionalString(json['title'], 'title') ?? contentId;
    final dialect = _optionalString(json['dialect'], 'dialect');

    final rawFrame = json['frame'];
    final frame = rawFrame == null
        ? FrameSize.vertical
        : FrameSize.fromJson(rawFrame);
    if (!frame.isVertical) warnings.add('frame_not_vertical');

    var budgetYuan = 120.0;
    final rawBudget = json['budget_yuan'];
    if (rawBudget != null) {
      if (rawBudget is! num) {
        throw PipelineError(ErrorClass.fatal, 'budget_yuan 必须是数字：$rawBudget');
      }
      final value = rawBudget.toDouble();
      if (!value.isFinite || value <= 0) {
        throw PipelineError(ErrorClass.fatal, 'budget_yuan 必须是有限正数：$rawBudget');
      }
      budgetYuan = value;
    }

    // cast 必须先于 shots 解析：speaker 校验依赖演员表。
    final cast = _parseCast(json['cast']);

    final shots = _parseShots(json['shots'], cast, warnings);

    return Storyboard(
      contentId: contentId,
      title: title,
      dialect: dialect,
      frame: frame,
      budgetYuan: budgetYuan,
      cast: cast,
      shots: shots,
      warnings: warnings,
    );
  }

  /// 输出规范化 wire JSON；不输出 warnings。
  Map<String, Object?> toJson() => <String, Object?>{
    'content_id': contentId,
    'title': title,
    'dialect': dialect,
    'frame': frame.label,
    'budget_yuan': budgetYuan,
    'cast': <String, Object?>{
      for (final entry in cast.entries) entry.key: entry.value.toJson(),
    },
    'shots': <Object?>[for (final shot in shots) shot.toJson()],
  };

  static Map<String, CastMember> _parseCast(Object? raw) {
    if (raw == null) return <String, CastMember>{};
    final map = _asMap(raw, 'cast');
    final cast = <String, CastMember>{};
    for (final entry in map.entries) {
      final id = entry.key;
      if (id.isEmpty) {
        throw PipelineError(ErrorClass.fatal, 'cast 成员 id 不能为空');
      }
      final member = _asMap(entry.value, 'cast.$id');
      final name = _requireString(member['name'], 'cast.$id.name');
      cast[id] = CastMember(
        id: id,
        name: name,
        voiceId: _optionalString(member['voice_id'], 'cast.$id.voice_id'),
        dialect: _optionalString(member['dialect'], 'cast.$id.dialect'),
      );
    }
    return cast;
  }

  static List<Shot> _parseShots(
    Object? raw,
    Map<String, CastMember> cast,
    List<String> warnings,
  ) {
    final list = _asList(raw, 'shots');
    if (list.isEmpty) {
      throw PipelineError(ErrorClass.fatal, 'shots 不能为空');
    }

    final ids = <String>{};
    final shots = <Shot>[];
    for (final item in list) {
      final map = _asMap(item, 'shots[]');
      final id = _requireString(map['id'], 'shots[].id');
      if (id.isEmpty) {
        throw PipelineError(ErrorClass.fatal, 'shots[].id 不能为空');
      }
      if (!ids.add(id)) {
        throw PipelineError(ErrorClass.fatal, 'shots[].id 重复：$id');
      }

      final rawKind = _requireString(map['kind'], 'shots[$id].kind');
      var kind = ShotKind.speakOff;
      final parsedKind = shotKindFromWire(rawKind);
      if (parsedKind == null) {
        warnings.add('unknown_kind:$id:$rawKind');
      } else {
        kind = parsedKind;
      }

      final rawPriority = map['priority'];
      var priority = ShotPriority.normal;
      if (rawPriority != null) {
        if (rawPriority is! String) {
          throw PipelineError(
            ErrorClass.fatal,
            'shots[$id].priority 必须是字符串：$rawPriority',
          );
        }
        final parsedPriority = shotPriorityFromWire(rawPriority);
        if (parsedPriority == null) {
          warnings.add('unknown_priority:$id:$rawPriority');
        } else {
          priority = parsedPriority;
        }
      }

      final speaker = _optionalString(map['speaker'], 'shots[$id].speaker');
      if (speaker != null && !cast.containsKey(speaker)) {
        warnings.add('speaker_not_in_cast:$id:$speaker');
      }

      final durationS = _parseDuration(map['duration_s'], id);

      shots.add(
        Shot(
          id: id,
          kind: kind,
          framing:
              _optionalString(map['framing'], 'shots[$id].framing') ??
              'unknown',
          speaker: speaker,
          line: _optionalString(map['line'], 'shots[$id].line') ?? '',
          durationS: durationS,
          priority: priority,
          prop: _optionalString(map['prop'], 'shots[$id].prop'),
          motion: _optionalString(map['motion'], 'shots[$id].motion'),
        ),
      );
    }
    return shots;
  }

  /// 显式 duration_s：缺省保持 null；出现则必须有限且 >0。
  /// 0.8 / 30 秒的夹取留给 `resolveDuration`。
  static double? _parseDuration(Object? raw, String id) {
    if (raw == null) return null;
    if (raw is! num) {
      throw PipelineError(ErrorClass.fatal, 'shots[$id].duration_s 必须是数字：$raw');
    }
    final value = raw.toDouble();
    if (!value.isFinite || value <= 0) {
      throw PipelineError(
        ErrorClass.fatal,
        'shots[$id].duration_s 必须是有限正数：$raw',
      );
    }
    return value;
  }

  static String _requireString(Object? raw, String field) {
    if (raw is! String) {
      throw PipelineError(ErrorClass.fatal, '$field 必须是字符串：$raw');
    }
    return raw;
  }

  static String? _optionalString(Object? raw, String field) {
    if (raw == null) return null;
    if (raw is! String) {
      throw PipelineError(ErrorClass.fatal, '$field 必须是字符串：$raw');
    }
    return raw;
  }

  /// 把任意 Map 复制成 `Map<String, Object?>`；非字符串 key 视为模式错误。
  static Map<String, Object?> _asMap(Object? raw, String field) {
    if (raw is! Map) {
      throw PipelineError(ErrorClass.fatal, '$field 必须是对象：$raw');
    }
    final out = <String, Object?>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      if (key is! String) {
        throw PipelineError(ErrorClass.fatal, '$field 的 key 必须是字符串：$key');
      }
      out[key] = entry.value;
    }
    return out;
  }

  static List<Object?> _asList(Object? raw, String field) {
    if (raw is! List) {
      throw PipelineError(ErrorClass.fatal, '$field 必须是数组：$raw');
    }
    return List<Object?>.from(raw);
  }
}
