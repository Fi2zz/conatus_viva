/// 短剧故事拆片 / 分镜草稿的 LLM 服务（纯 Dart，无 Flutter 依赖）。
///
/// LLM 输出只作为草稿：必须经过 schema 校验，重试一次仍失败则抛
/// `PipelineError(ErrorClass.fatal, 'draft_schema: ...')`，由 controller
/// 映射 422。本模块不写文件、不改剧集。
library;

import '../bailian/llm.dart';
import '../config.dart';
import '../errors.dart';
import '../storyboard.dart';
import 'episode.dart';
import 'hash.dart';
import 'json.dart';
import 'series.dart';

/// 提示词版本；写入 `episode.story.prompt_version`。
const int kDramaPromptVersion = 1;

/// 可注入的 LLM 接口；生产走 [QwenDramaLlm]，测试注入 fake。
abstract interface class DramaLlm {
  Future<Map<String, dynamic>> chatJson({
    required String system,
    required String user,
  });
}

/// 百炼 OpenAI 兼容接口实现。
class QwenDramaLlm implements DramaLlm {
  QwenDramaLlm({required this.cfg});

  final PipelineConfig cfg;

  @override
  Future<Map<String, dynamic>> chatJson({
    required String system,
    required String user,
  }) {
    final client = QwenClient(
      apiKey: cfg.requireApiKey(),
      baseUrl: cfg.baseUrl,
      model: cfg.llmModel,
    );
    return client.chatJson(system: system, user: user);
  }
}

/// 拆片结果（不落盘）。
class DramaExtractResult {
  const DramaExtractResult({
    required this.logline,
    required this.synopsis,
    required this.sourceHash,
    required this.beats,
    required this.castNew,
    required this.castUpdates,
    required this.warnings,
  });

  final String logline;
  final String synopsis;
  final String sourceHash;
  final List<DramaBeat> beats;
  final Map<String, DramaCastMember> castNew;
  final Map<String, DramaCastMember> castUpdates;
  final List<String> warnings;

  Map<String, Object?> toJson() => <String, Object?>{
    'logline': logline,
    'synopsis': synopsis,
    'source_hash': sourceHash,
    'beats': <Object?>[for (final beat in beats) beat.toJson()],
    'cast_new': <String, Object?>{
      for (final entry in castNew.entries) entry.key: entry.value.toJson(),
    },
    'cast_updates': <String, Object?>{
      for (final entry in castUpdates.entries) entry.key: entry.value.toJson(),
    },
    'warnings': warnings,
  };
}

/// 分镜草稿（不落盘）。
class DramaStoryboardDraft {
  const DramaStoryboardDraft({required this.storyboard, required this.warnings});

  final Storyboard storyboard;
  final List<String> warnings;

  Map<String, Object?> toJson() => <String, Object?>{
    'storyboard': storyboard.toJson(),
    'warnings': warnings,
  };
}

/// 拆片 / 分镜草稿服务。
class DramaDraftService {
  DramaDraftService({required this.llm, int maxAttempts = 2})
    : _maxAttempts = maxAttempts < 1 ? 1 : maxAttempts;

  final DramaLlm llm;
  final int _maxAttempts;

  Future<DramaExtractResult> extract({
    required DramaSeries series,
    required DramaEpisode episode,
  }) async {
    final system = _extractSystemPrompt;
    final baseUser = _extractUserPrompt(series: series, episode: episode);
    var user = baseUser;
    Object? lastError;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final json = await llm.chatJson(system: system, user: user);
      try {
        return _parseExtract(json, episode);
      } on Object catch (e) {
        lastError = e;
        user = '$baseUser\n上次输出不符合 schema：$e\n请修正后只输出合法 JSON。';
      }
    }
    throw PipelineError(ErrorClass.fatal, 'draft_schema: $lastError');
  }

  Future<DramaStoryboardDraft> draftStoryboard({
    required DramaSeries series,
    required DramaEpisode episode,
  }) async {
    final system = _storyboardSystemPrompt;
    final baseUser = _storyboardUserPrompt(series: series, episode: episode);
    var user = baseUser;
    Object? lastError;
    for (var attempt = 0; attempt < _maxAttempts; attempt++) {
      final json = await llm.chatJson(system: system, user: user);
      try {
        return _parseStoryboard(json, series: series, episode: episode);
      } on Object catch (e) {
        lastError = e;
        user = '$baseUser\n上次输出不符合 schema：$e\n请修正后只输出合法 JSON。';
      }
    }
    throw PipelineError(ErrorClass.fatal, 'draft_schema: $lastError');
  }

  DramaExtractResult _parseExtract(
    Map<String, dynamic> json,
    DramaEpisode episode,
  ) {
    final rawBeats = json['beats'];
    final beats = <DramaBeat>[];
    if (rawBeats != null) {
      var index = 0;
      for (final raw in asJsonList(rawBeats, 'beats')) {
        index += 1;
        final map = asJsonMap(raw, 'beats[]');
        final id = optionalJsonString(map['id'], 'beats[].id') ?? 'b$index';
        beats.add(
          DramaBeat.fromJson(<String, Object?>{...map, 'id': id}),
        );
      }
    }

    Map<String, DramaCastMember> cast(Object? raw, String field) {
      final out = <String, DramaCastMember>{};
      if (raw == null) return out;
      for (final entry in asJsonMap(raw, field).entries) {
        out[entry.key] = DramaCastMember.fromJson(
          entry.key,
          asJsonMap(entry.value, '$field.${entry.key}'),
        );
      }
      return out;
    }

    final warnings = <String>[];
    final rawWarnings = json['warnings'];
    if (rawWarnings != null) {
      for (final line in asJsonList(rawWarnings, 'warnings')) {
        warnings.add(requireJsonString(line, 'warnings[]'));
      }
    }

    return DramaExtractResult(
      logline: optionalJsonString(json['logline'], 'logline') ?? '',
      synopsis: optionalJsonString(json['synopsis'], 'synopsis') ?? '',
      sourceHash: dramaHash(<String, Object?>{'text': episode.source.text}),
      beats: List<DramaBeat>.unmodifiable(beats),
      castNew: Map<String, DramaCastMember>.unmodifiable(
        cast(json['cast_new'], 'cast_new'),
      ),
      castUpdates: Map<String, DramaCastMember>.unmodifiable(
        cast(json['cast_updates'], 'cast_updates'),
      ),
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  DramaStoryboardDraft _parseStoryboard(
    Map<String, dynamic> json, {
    required DramaSeries series,
    required DramaEpisode episode,
  }) {
    final rawShots = asJsonList(json['shots'], 'shots');
    final warnings = <String>[];
    final shots = <Object?>[];
    var index = 0;
    for (final raw in rawShots) {
      index += 1;
      final map = asJsonMap(raw, 'shots[]');
      var id = optionalJsonString(map['id'], 'shots[].id') ?? '';
      if (id.trim().isEmpty) {
        id = 's${index.toString().padLeft(2, '0')}';
        warnings.add('shot_id_generated:$id');
      }
      shots.add(<String, Object?>{...map, 'id': id});
    }

    final board = Storyboard.fromJson(<String, Object?>{
      'content_id': episode.episodeId,
      'title': optionalJsonString(json['title'], 'title') ?? episode.title,
      'dialect': episode.settings.dialect,
      'frame': episode.settings.frame.label,
      'budget_yuan': episode.settings.i2vBudgetYuan,
      'cast': <String, Object?>{
        for (final entry in series.storyboardCast().entries)
          entry.key: entry.value.toJson(),
      },
      'shots': shots,
    });

    return DramaStoryboardDraft(
      storyboard: board,
      warnings: List<String>.unmodifiable(<String>[...warnings, ...board.warnings]),
    );
  }

  String _extractUserPrompt({
    required DramaSeries series,
    required DramaEpisode episode,
  }) => <String>[
    '剧名：${series.title}',
    '方言：${series.dialect}',
    '已有角色：${series.cast.keys.join('、')}',
    '目标时长：${episode.settings.targetDurationS} 秒',
    '源文本：',
    episode.source.text,
  ].join('\n');

  String _storyboardUserPrompt({
    required DramaSeries series,
    required DramaEpisode episode,
  }) => <String>[
    '剧名：${series.title}',
    '本集：${episode.title}',
    '方言：${episode.settings.dialect}',
    '画幅：${episode.settings.frame.label}',
    '目标时长：${episode.settings.targetDurationS} 秒',
    '角色：${series.cast.keys.join('、')}',
    '梗概：${episode.story.synopsis}',
    '节拍：${episode.story.beats.map((b) => '${b.label}(${b.summary})').join('；')}',
    '镜头数建议：12–30 镜；竖屏；每镜 1.2–10 秒。',
  ].join('\n');

  static const String _extractSystemPrompt =
      '你是短剧拆片编辑。只输出一个 JSON 对象，不要 Markdown，不要解释。'
      '字段：logline(string)、synopsis(string)、'
      'beats(array<{id,label,summary}>)、'
      'cast_new(object<id,{name,description,voice_id,dialect}>)、'
      'cast_updates(object<id,{name,description,voice_id,dialect}>)。';

  static const String _storyboardSystemPrompt =
      '你是短剧分镜编辑。只输出一个 JSON 对象，不要 Markdown，不要解释。'
      '字段：title(string)、shots(array<{id,kind,framing,speaker,line,'
      'duration_s,priority,prop,motion,visual}>)。'
      'kind 取 speak_off/insert/listen_face/action/establishing；'
      'priority 取 hook/turn/payoff/normal；speaker 必须是给定角色 id；'
      'visual 写竖屏画面提示词，motion 写镜头运动。';
}
