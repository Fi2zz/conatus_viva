/// 短剧「集」级模型：源文本、故事/节拍与本集设置。
///
/// `storyboard.json` / `plan.json` 是独立文件；本模型只保存创作侧输入，
/// 不掺运行状态。
library;

import '../errors.dart';
import '../frame.dart';
import 'ids.dart';
import 'json.dart';
import 'series.dart';

/// 源故事输入。
class DramaSource {
  const DramaSource({required this.kind, required this.text});

  final String kind;
  final String text;

  static DramaSource fromJson(Map<String, Object?> json) => DramaSource(
    kind: optionalJsonString(json['kind'], 'source.kind') ?? 'story',
    text: optionalJsonString(json['text'], 'source.text') ?? '',
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'text': text,
  };
}

/// 故事/节拍，以及拆片结果的溯源信息。
class DramaStory {
  const DramaStory({
    this.logline = '',
    this.synopsis = '',
    this.beats = const <DramaBeat>[],
    this.sourceHash,
    this.promptVersion = 1,
    this.model,
  });

  final String logline;
  final String synopsis;
  final List<DramaBeat> beats;
  final String? sourceHash;
  final int promptVersion;
  final String? model;

  static DramaStory fromJson(Map<String, Object?> json) {
    final rawBeats = json['beats'];
    final beats = <DramaBeat>[];
    if (rawBeats != null) {
      for (final raw in asJsonList(rawBeats, 'story.beats')) {
        beats.add(DramaBeat.fromJson(asJsonMap(raw, 'story.beats[]')));
      }
    }
    final promptVersion =
        optionalJsonInt(json['prompt_version'], 'story.prompt_version') ?? 1;
    if (promptVersion < 1) {
      throw PipelineError(ErrorClass.fatal, 'story.prompt_version 必须 >= 1');
    }
    return DramaStory(
      logline: optionalJsonString(json['logline'], 'story.logline') ?? '',
      synopsis: optionalJsonString(json['synopsis'], 'story.synopsis') ?? '',
      beats: List<DramaBeat>.unmodifiable(beats),
      sourceHash: optionalJsonString(json['source_hash'], 'story.source_hash'),
      promptVersion: promptVersion,
      model: optionalJsonString(json['model'], 'story.model'),
    );
  }

  DramaStory copyWith({
    String? logline,
    String? synopsis,
    List<DramaBeat>? beats,
    String? sourceHash,
    int? promptVersion,
    String? model,
    bool clearSourceHash = false,
    bool clearModel = false,
  }) => DramaStory(
    logline: logline ?? this.logline,
    synopsis: synopsis ?? this.synopsis,
    beats: List<DramaBeat>.unmodifiable(beats ?? this.beats),
    sourceHash: clearSourceHash ? null : (sourceHash ?? this.sourceHash),
    promptVersion: promptVersion ?? this.promptVersion,
    model: clearModel ? null : (model ?? this.model),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'logline': logline,
    'synopsis': synopsis,
    'beats': <Object?>[for (final beat in beats) beat.toJson()],
    'source_hash': sourceHash,
    'prompt_version': promptVersion,
    'model': model,
  };
}

/// 本集设置。
class DramaSettings {
  const DramaSettings({
    required this.dialect,
    required this.frame,
    required this.totalBudgetYuan,
    required this.i2vBudgetYuan,
    this.maxI2vSeconds = 0,
    this.targetDurationS = 90,
  });

  final String dialect;
  final FrameSize frame;
  final double totalBudgetYuan;
  final double i2vBudgetYuan;
  final int maxI2vSeconds;
  final double targetDurationS;

  static DramaSettings fromJson(
    Map<String, Object?> json, {
    required String fallbackDialect,
    required FrameSize fallbackFrame,
  }) {
    final total =
        optionalJsonNumber(json['total_budget_yuan'], 'settings.total_budget_yuan') ??
        120;
    final i2v =
        optionalJsonNumber(json['i2v_budget_yuan'], 'settings.i2v_budget_yuan') ??
        20;
    final target =
        optionalJsonNumber(json['target_duration_s'], 'settings.target_duration_s') ??
        90;
    final maxI2v =
        optionalJsonInt(json['max_i2v_seconds'], 'settings.max_i2v_seconds') ?? 0;
    if (!total.isFinite || total <= 0) {
      throw PipelineError(ErrorClass.fatal, 'settings.total_budget_yuan 必须 > 0');
    }
    if (!i2v.isFinite || i2v <= 0) {
      throw PipelineError(ErrorClass.fatal, 'settings.i2v_budget_yuan 必须 > 0');
    }
    if (!target.isFinite || target <= 0) {
      throw PipelineError(ErrorClass.fatal, 'settings.target_duration_s 必须 > 0');
    }
    if (maxI2v < 0) {
      throw PipelineError(ErrorClass.fatal, 'settings.max_i2v_seconds 必须 >= 0');
    }
    final rawFrame = json['frame'];
    return DramaSettings(
      dialect: optionalJsonString(json['dialect'], 'settings.dialect') ?? fallbackDialect,
      frame: rawFrame == null ? fallbackFrame : FrameSize.fromJson(rawFrame),
      totalBudgetYuan: total,
      i2vBudgetYuan: i2v,
      maxI2vSeconds: maxI2v,
      targetDurationS: target,
    );
  }

  DramaSettings copyWith({
    String? dialect,
    FrameSize? frame,
    double? totalBudgetYuan,
    double? i2vBudgetYuan,
    int? maxI2vSeconds,
    double? targetDurationS,
  }) => DramaSettings(
    dialect: dialect ?? this.dialect,
    frame: frame ?? this.frame,
    totalBudgetYuan: totalBudgetYuan ?? this.totalBudgetYuan,
    i2vBudgetYuan: i2vBudgetYuan ?? this.i2vBudgetYuan,
    maxI2vSeconds: maxI2vSeconds ?? this.maxI2vSeconds,
    targetDurationS: targetDurationS ?? this.targetDurationS,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'dialect': dialect,
    'frame': frame.label,
    'total_budget_yuan': totalBudgetYuan,
    'i2v_budget_yuan': i2vBudgetYuan,
    'max_i2v_seconds': maxI2vSeconds,
    'target_duration_s': targetDurationS,
  };
}

/// 一集短剧。
class DramaEpisode {
  const DramaEpisode({
    required this.seriesId,
    required this.episodeId,
    required this.number,
    required this.title,
    required this.source,
    required this.story,
    required this.settings,
  });

  final String seriesId;
  final String episodeId;
  final int number;
  final String title;
  final DramaSource source;
  final DramaStory story;
  final DramaSettings settings;

  factory DramaEpisode.create({
    required DramaSeries series,
    required String episodeId,
    required String title,
    int number = 1,
  }) => DramaEpisode(
    seriesId: series.seriesId,
    episodeId: episodeId,
    number: number,
    title: title,
    source: const DramaSource(kind: 'story', text: ''),
    story: DramaStory(beats: List<DramaBeat>.unmodifiable(series.beatTemplate)),
    settings: DramaSettings(
      dialect: series.dialect,
      frame: series.frame,
      totalBudgetYuan: series.defaults.totalBudgetYuan,
      i2vBudgetYuan: series.defaults.i2vBudgetYuan,
      maxI2vSeconds: series.defaults.maxI2vSeconds,
    ),
  ).._validate();

  static DramaEpisode fromJson(Map<String, Object?> json) {
    final seriesId = requireJsonString(json['series_id'], 'series_id');
    final episodeId = requireJsonString(json['episode_id'], 'episode_id');
    final title = optionalJsonString(json['title'], 'title') ?? episodeId;
    final number = optionalJsonInt(json['number'], 'number') ?? 1;
    final rawSource = json['source'];
    final rawStory = json['story'];
    final rawSettings = json['settings'];
    final episode = DramaEpisode(
      seriesId: seriesId,
      episodeId: episodeId,
      number: number,
      title: title,
      source: rawSource == null
          ? const DramaSource(kind: 'story', text: '')
          : DramaSource.fromJson(asJsonMap(rawSource, 'source')),
      story: rawStory == null
          ? const DramaStory()
          : DramaStory.fromJson(asJsonMap(rawStory, 'story')),
      settings: rawSettings == null
          ? const DramaSettings(
              dialect: 'mandarin',
              frame: FrameSize.vertical,
              totalBudgetYuan: 120,
              i2vBudgetYuan: 20,
            )
          : DramaSettings.fromJson(
              asJsonMap(rawSettings, 'settings'),
              fallbackDialect: 'mandarin',
              fallbackFrame: FrameSize.vertical,
            ),
    );
    episode._validate();
    return episode;
  }

  DramaEpisode copyWith({
    String? title,
    int? number,
    DramaSource? source,
    DramaStory? story,
    DramaSettings? settings,
  }) => DramaEpisode(
    seriesId: seriesId,
    episodeId: episodeId,
    number: number ?? this.number,
    title: title ?? this.title,
    source: source ?? this.source,
    story: story ?? this.story,
    settings: settings ?? this.settings,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'series_id': seriesId,
    'episode_id': episodeId,
    'number': number,
    'title': title,
    'source': source.toJson(),
    'story': story.toJson(),
    'settings': settings.toJson(),
  };

  void _validate() {
    try {
      requireDramaId(seriesId, 'series_id');
      requireDramaId(episodeId, 'episode_id');
    } on ArgumentError {
      throw PipelineError(
        ErrorClass.fatal,
        'series_id / episode_id 非法：$seriesId / $episodeId',
      );
    }
    if (number <= 0) {
      throw PipelineError(ErrorClass.fatal, 'number 必须 > 0');
    }
    if (title.trim().isEmpty) {
      throw PipelineError(ErrorClass.fatal, 'title 不能为空');
    }
  }
}
