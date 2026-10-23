/// 短剧「剧」级模型：元信息、默认值、节拍模板与角色表。
///
/// 角色定妆是剧级资产，全季复用；`storyboardCast()` 把它转换成既有
/// `Storyboard` 需要的 `CastMember`，不复制业务规则。
library;

import '../errors.dart';
import '../frame.dart';
import '../storyboard.dart' show CastMember;
import 'ids.dart';
import 'json.dart';

/// 剧级默认生成参数。
class DramaDefaults {
  const DramaDefaults({
    this.totalBudgetYuan = 120,
    this.i2vBudgetYuan = 20,
    this.maxI2vSeconds = 0,
    this.castImageModel = 'wan2.7-image',
    this.frameImageModel = 'wan2.7-image',
    this.clipVideoModel = 'wan2.6-i2v-flash',
    this.t2vModel = 'wan3.0-video',
    this.resolution = '720P',
  });

  final double totalBudgetYuan;
  final double i2vBudgetYuan;
  final int maxI2vSeconds;
  final String castImageModel;
  final String frameImageModel;
  final String clipVideoModel;
  final String t2vModel;
  final String resolution;

  static DramaDefaults fromJson(Map<String, Object?> json) {
    final total = optionalJsonNumber(json['total_budget_yuan'], 'defaults.total_budget_yuan') ??
        120;
    final i2v = optionalJsonNumber(json['i2v_budget_yuan'], 'defaults.i2v_budget_yuan') ??
        20;
    if (total <= 0) {
      throw PipelineError(ErrorClass.fatal, 'defaults.total_budget_yuan 必须 > 0');
    }
    if (i2v <= 0) {
      throw PipelineError(ErrorClass.fatal, 'defaults.i2v_budget_yuan 必须 > 0');
    }
    final maxI2v = optionalJsonInt(json['max_i2v_seconds'], 'defaults.max_i2v_seconds') ?? 0;
    if (maxI2v < 0) {
      throw PipelineError(ErrorClass.fatal, 'defaults.max_i2v_seconds 必须 >= 0');
    }
    return DramaDefaults(
      totalBudgetYuan: total,
      i2vBudgetYuan: i2v,
      maxI2vSeconds: maxI2v,
      castImageModel:
          optionalJsonString(json['cast_image_model'], 'defaults.cast_image_model') ??
          'wan2.7-image',
      frameImageModel:
          optionalJsonString(json['frame_image_model'], 'defaults.frame_image_model') ??
          'wan2.7-image',
      clipVideoModel:
          optionalJsonString(json['clip_video_model'], 'defaults.clip_video_model') ??
          'wan2.6-i2v-flash',
      t2vModel: optionalJsonString(json['t2v_model'], 'defaults.t2v_model') ??
          'wan3.0-video',
      resolution: optionalJsonString(json['resolution'], 'defaults.resolution') ??
          '720P',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'total_budget_yuan': totalBudgetYuan,
    'i2v_budget_yuan': i2vBudgetYuan,
    'max_i2v_seconds': maxI2vSeconds,
    'cast_image_model': castImageModel,
    'frame_image_model': frameImageModel,
    'clip_video_model': clipVideoModel,
    't2v_model': t2vModel,
    'resolution': resolution,
  };
}

/// 剧级节拍；`target_s` / `weight` 只用于创作提示与预览。
class DramaBeat {
  const DramaBeat({
    required this.id,
    required this.label,
    required this.summary,
    this.targetS,
    this.weight,
  });

  final String id;
  final String label;
  final String summary;
  final double? targetS;
  final int? weight;

  static DramaBeat fromJson(Map<String, Object?> json) {
    final target = optionalJsonNumber(json['target_s'], 'beat.target_s');
    if (target != null && target <= 0) {
      throw PipelineError(ErrorClass.fatal, 'beat.target_s 必须 > 0');
    }
    final weight = optionalJsonInt(json['weight'], 'beat.weight');
    if (weight != null && weight < 0) {
      throw PipelineError(ErrorClass.fatal, 'beat.weight 必须 >= 0');
    }
    return DramaBeat(
      id: requireJsonString(json['id'], 'beat.id'),
      label: requireJsonString(json['label'], 'beat.label'),
      summary: optionalJsonString(json['summary'], 'beat.summary') ?? '',
      targetS: target,
      weight: weight,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'label': label,
    'summary': summary,
    'target_s': targetS,
    'weight': weight,
  };
}

/// 角色定妆资产；`path` 相对于剧目录。
class DramaCastAvatar {
  const DramaCastAvatar({
    required this.path,
    required this.sourceHash,
    required this.model,
    required this.costYuan,
    required this.approved,
  });

  final String path;
  final String sourceHash;
  final String model;
  final double costYuan;
  final bool approved;

  static DramaCastAvatar fromJson(Map<String, Object?> json) {
    final cost = optionalJsonNumber(json['cost_yuan'], 'avatar.cost_yuan') ?? 0;
    if (cost < 0) {
      throw PipelineError(ErrorClass.fatal, 'avatar.cost_yuan 必须 >= 0');
    }
    return DramaCastAvatar(
      path: requireJsonString(json['path'], 'avatar.path'),
      sourceHash: requireJsonString(json['source_hash'], 'avatar.source_hash'),
      model: requireJsonString(json['model'], 'avatar.model'),
      costYuan: cost,
      approved: optionalJsonBool(
        json['approved'],
        'avatar.approved',
        fallback: false,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'source_hash': sourceHash,
    'model': model,
    'cost_yuan': costYuan,
    'approved': approved,
  };
}

/// 剧级角色。
class DramaCastMember {
  const DramaCastMember({
    required this.castId,
    required this.name,
    this.description = '',
    this.voiceId,
    this.dialect,
    this.avatar,
  });

  final String castId;
  final String name;
  final String description;
  final String? voiceId;
  final String? dialect;
  final DramaCastAvatar? avatar;

  static DramaCastMember fromJson(String castId, Map<String, Object?> json) {
    try {
      requireDramaId(castId, 'cast_id');
    } on ArgumentError {
      throw PipelineError(ErrorClass.fatal, 'cast_id 非法：$castId');
    }
    final rawAvatar = json['avatar'];
    return DramaCastMember(
      castId: castId,
      name: requireJsonString(json['name'], 'cast.$castId.name'),
      description: optionalJsonString(json['description'], 'cast.$castId.description') ?? '',
      voiceId: optionalJsonString(json['voice_id'], 'cast.$castId.voice_id'),
      dialect: optionalJsonString(json['dialect'], 'cast.$castId.dialect'),
      avatar: rawAvatar == null
          ? null
          : DramaCastAvatar.fromJson(asJsonMap(rawAvatar, 'cast.$castId.avatar')),
    );
  }

  DramaCastMember copyWith({
    String? name,
    String? description,
    String? voiceId,
    String? dialect,
    DramaCastAvatar? avatar,
    bool clearAvatar = false,
  }) => DramaCastMember(
    castId: castId,
    name: name ?? this.name,
    description: description ?? this.description,
    voiceId: voiceId ?? this.voiceId,
    dialect: dialect ?? this.dialect,
    avatar: clearAvatar ? null : (avatar ?? this.avatar),
  );

  CastMember toStoryboardCast() => CastMember(
    id: castId,
    name: name,
    voiceId: voiceId,
    dialect: dialect,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'description': description,
    'voice_id': voiceId,
    'dialect': dialect,
    'avatar': avatar?.toJson(),
  };
}

/// 一部短剧。
class DramaSeries {
  const DramaSeries({
    required this.seriesId,
    required this.title,
    required this.logline,
    required this.dialect,
    required this.frame,
    required this.contentType,
    required this.plannedEpisodes,
    required this.defaults,
    required this.beatTemplate,
    required this.cast,
  });

  final String seriesId;
  final String title;
  final String logline;
  final String dialect;
  final FrameSize frame;
  final String contentType;
  final int plannedEpisodes;
  final DramaDefaults defaults;
  final List<DramaBeat> beatTemplate;
  final Map<String, DramaCastMember> cast;

  factory DramaSeries.create({
    required String seriesId,
    required String title,
    String logline = '',
    String dialect = 'mandarin',
    FrameSize frame = FrameSize.vertical,
    String contentType = 'manju',
    int plannedEpisodes = 1,
    double totalBudgetYuan = 120,
    double i2vBudgetYuan = 20,
    int maxI2vSeconds = 0,
    List<DramaBeat> beatTemplate = const <DramaBeat>[],
    Map<String, DramaCastMember> cast = const <String, DramaCastMember>{},
  }) {
    _validate(seriesId, title, plannedEpisodes);
    if (maxI2vSeconds < 0) {
      throw PipelineError(ErrorClass.fatal, 'max_i2v_seconds 必须 >= 0');
    }
    return DramaSeries(
      seriesId: seriesId,
      title: title,
      logline: logline,
      dialect: dialect,
      frame: frame,
      contentType: contentType,
      plannedEpisodes: plannedEpisodes,
      defaults: DramaDefaults(
        totalBudgetYuan: _positive(totalBudgetYuan, 'total_budget_yuan'),
        i2vBudgetYuan: _positive(i2vBudgetYuan, 'i2v_budget_yuan'),
        maxI2vSeconds: maxI2vSeconds,
      ),
      beatTemplate: List<DramaBeat>.unmodifiable(beatTemplate),
      cast: Map<String, DramaCastMember>.unmodifiable(cast),
    );
  }

  static DramaSeries fromJson(Map<String, Object?> json) {
    final seriesId = requireJsonString(json['series_id'], 'series_id');
    final title = requireJsonString(json['title'], 'title');
    final plannedEpisodes =
        optionalJsonInt(json['planned_episodes'], 'planned_episodes') ?? 1;
    _validate(seriesId, title, plannedEpisodes);

    final rawDefaults = json['defaults'];
    final defaults = rawDefaults == null
        ? const DramaDefaults()
        : DramaDefaults.fromJson(asJsonMap(rawDefaults, 'defaults'));

    final rawBeats = json['beat_template'];
    final beats = <DramaBeat>[];
    final beatIds = <String>{};
    if (rawBeats != null) {
      for (final raw in asJsonList(rawBeats, 'beat_template')) {
        final beat = DramaBeat.fromJson(asJsonMap(raw, 'beat_template[]'));
        if (!beatIds.add(beat.id)) {
          throw PipelineError(ErrorClass.fatal, 'beat_template id 重复：${beat.id}');
        }
        beats.add(beat);
      }
    }

    final rawCast = json['cast'];
    final cast = <String, DramaCastMember>{};
    if (rawCast != null) {
      for (final entry in asJsonMap(rawCast, 'cast').entries) {
        cast[entry.key] = DramaCastMember.fromJson(
          entry.key,
          asJsonMap(entry.value, 'cast.${entry.key}'),
        );
      }
    }

    return DramaSeries(
      seriesId: seriesId,
      title: title,
      logline: optionalJsonString(json['logline'], 'logline') ?? '',
      dialect: optionalJsonString(json['dialect'], 'dialect') ?? 'mandarin',
      frame: json['frame'] == null
          ? FrameSize.vertical
          : FrameSize.fromJson(json['frame']),
      contentType: optionalJsonString(json['content_type'], 'content_type') ?? 'manju',
      plannedEpisodes: plannedEpisodes,
      defaults: defaults,
      beatTemplate: List<DramaBeat>.unmodifiable(beats),
      cast: Map<String, DramaCastMember>.unmodifiable(cast),
    );
  }

  DramaSeries copyWith({
    String? title,
    String? logline,
    String? dialect,
    FrameSize? frame,
    String? contentType,
    int? plannedEpisodes,
    DramaDefaults? defaults,
    List<DramaBeat>? beatTemplate,
    Map<String, DramaCastMember>? cast,
  }) => DramaSeries(
    seriesId: seriesId,
    title: title ?? this.title,
    logline: logline ?? this.logline,
    dialect: dialect ?? this.dialect,
    frame: frame ?? this.frame,
    contentType: contentType ?? this.contentType,
    plannedEpisodes: plannedEpisodes ?? this.plannedEpisodes,
    defaults: defaults ?? this.defaults,
    beatTemplate: List<DramaBeat>.unmodifiable(beatTemplate ?? this.beatTemplate),
    cast: Map<String, DramaCastMember>.unmodifiable(cast ?? this.cast),
  );

  /// 给 `Storyboard` 用的演员表视图。
  Map<String, CastMember> storyboardCast() => <String, CastMember>{
    for (final entry in cast.entries) entry.key: entry.value.toStoryboardCast(),
  };

  Map<String, Object?> toJson() => <String, Object?>{
    'series_id': seriesId,
    'title': title,
    'logline': logline,
    'dialect': dialect,
    'frame': frame.label,
    'content_type': contentType,
    'planned_episodes': plannedEpisodes,
    'defaults': defaults.toJson(),
    'beat_template': <Object?>[for (final beat in beatTemplate) beat.toJson()],
    'cast': <String, Object?>{
      for (final entry in cast.entries) entry.key: entry.value.toJson(),
    },
  };

  static void _validate(String seriesId, String title, int plannedEpisodes) {
    try {
      requireDramaId(seriesId, 'series_id');
    } on ArgumentError {
      throw PipelineError(ErrorClass.fatal, 'series_id 非法：$seriesId');
    }
    if (title.trim().isEmpty) {
      throw PipelineError(ErrorClass.fatal, 'title 不能为空');
    }
    if (plannedEpisodes <= 0) {
      throw PipelineError(ErrorClass.fatal, 'planned_episodes 必须 > 0');
    }
  }

  static double _positive(double value, String field) {
    if (!value.isFinite || value <= 0) {
      throw PipelineError(ErrorClass.fatal, '$field 必须是有限正数：$value');
    }
    return value;
  }
}
