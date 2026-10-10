import '../bailian/llm.dart';
import '../errors.dart';
import 'classify.dart';

/// One segment of the 03 script step (spec §4「03 script」): the narration
/// line for one selected photo, plus the motion prompt for non-person
/// segments.
class SegmentScript {
  const SegmentScript({
    required this.photoId,
    required this.line,
    required this.motionPrompt,
  });

  /// The [PhotoInfo.id] this line belongs to.
  final String photoId;

  /// Standard written-Chinese narration, one sentence, ≤40 chars, free of
  /// control tags (`[very slowly]` etc. stay out of the script — they only
  /// enter TTS, never subtitles; spec §4-06).
  final String line;

  /// Composed motion prompt (classify `motion_hint` + fixed template, spec
  /// §4-03) for non-person segments; `null` for person segments.
  final String? motionPrompt;
}

/// The whole narration: one [SegmentScript] per selected photo.
class VideoScript {
  const VideoScript({required this.segments, required this.totalChars});

  /// One entry per selected photo, in selection order.
  final List<SegmentScript> segments;

  /// Total narration length in chars (sum of [SegmentScript.line]);
  /// the 60–80 char budget maps to a 15–20s video (spec §4-03).
  final int totalChars;
}

/// The hard-constraint sentence of the fixed motion template, verbatim from
/// spec §4-03 (the authority over the plan's misquote). Every composed
/// `motion_prompt` carries it verbatim.
const String _staticSubjectConstraint = '主体保持静止，仅背景与光影微动';

/// Fixed motion template composed with the classify `motion_hint` for
/// non-person (i2v) segments; MUST contain [_staticSubjectConstraint].
const String _motionTemplate = '$_staticSubjectConstraint，镜头平滑缓慢地推进。';

/// System prompt (spec §4-03): one sentence per segment, standard written
/// Chinese, 60–80 chars total, a JSON array of segments. [QwenClient.chatJson]
/// appends its own no-fences / no-explanation instruction on top of this.
const String _systemPrompt = '''
为月度相册视频撰写分段口播稿。只输出一个 JSON 对象，且对象仅含 segments 一个字段：
{"segments": [{"photo": "照片id", "line": "口播台词"}, ...]}
- segments 字段的值必须是 JSON 数组，元素与用户给出的照片一一对应：photo 原样引用照片 id，顺序一致
- line：每段一句，标准书面中文，约 15–20 字，最多 40 字
- 所有 line 合计 60–80 字，围绕画面内容平实叙述，前后连贯
- line 只写口播台词本身，不得包含方括号控制标签（如 [very slowly]）
不要输出 Markdown 代码围栏，不要输出任何解释。
''';

/// Builds the per-run user prompt: the ordered photo list with the classify
/// `caption`/`motion_hint` context (spec §4-03 输入).
String _userPrompt(List<PhotoInfo> selected) {
  final buffer = StringBuffer('入选照片（按顺序）：\n');
  for (var i = 0; i < selected.length; i++) {
    final photo = selected[i];
    final parts = <String>[];
    final caption = photo.caption.trim();
    if (caption.isNotEmpty) parts.add('画面：$caption');
    final hint = photo.motionHint.trim();
    if (hint.isNotEmpty) parts.add('动效提示：$hint');
    final context = parts.isEmpty ? '' : '；${parts.join('；')}';
    buffer.writeln('${i + 1}. photo=${photo.id}$context');
  }
  buffer.write('请按要求输出 segments。');
  return buffer.toString();
}

/// Composes the non-person `motion_prompt`: classify `motion_hint` + the
/// fixed template (spec §4-03). Deterministic in code, so the hard-constraint
/// sentence is guaranteed regardless of what the model writes.
String _composeMotionPrompt(String motionHint) {
  final hint = motionHint.trim();
  if (hint.isEmpty) return _motionTemplate;
  return hint.endsWith('。')
      ? '$hint$_motionTemplate'
      : '$hint。$_motionTemplate';
}

/// Removes `[...]` control tags (defense in depth — the prompt already
/// forbids them; spec §4-06 keeps such tags out of subtitles).
String _stripControlTags(String line) =>
    line.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();

/// Validates one decoded reply against the selected photos, throwing
/// [PipelineError] with [ErrorClass.transient] on any violation (segment
/// count == photo count, each line ≤40 chars, ids match). Segments are
/// emitted in selection order whatever order the model answered in.
VideoScript _parse(Map<String, dynamic> reply, List<PhotoInfo> selected) {
  final raw = reply['segments'];
  if (raw is! List) {
    throw PipelineError(
      ErrorClass.transient,
      'script reply has no segments array',
    );
  }
  if (raw.length != selected.length) {
    throw PipelineError(
      ErrorClass.transient,
      'script returned ${raw.length} segments for ${selected.length} photos',
    );
  }
  final lineById = <String, String>{};
  for (final item in raw) {
    if (item is! Map<String, dynamic>) {
      throw PipelineError(
        ErrorClass.transient,
        'script segment must be an object',
      );
    }
    final photo = item['photo'];
    final line = item['line'];
    if (photo is! String || line is! String) {
      throw PipelineError(
        ErrorClass.transient,
        'script segment needs string photo/line, got $photo/$line',
      );
    }
    final cleaned = _stripControlTags(line);
    if (cleaned.isEmpty) {
      throw PipelineError(
        ErrorClass.transient,
        'script line is empty for $photo',
      );
    }
    if (cleaned.length > 40) {
      throw PipelineError(
        ErrorClass.transient,
        'script line over 40 chars for $photo: ${cleaned.length}',
      );
    }
    lineById[photo] = cleaned;
  }
  final segments = <SegmentScript>[];
  for (final photo in selected) {
    final line = lineById[photo.id];
    if (line == null) {
      throw PipelineError(
        ErrorClass.transient,
        'script reply has no line for photo ${photo.id}',
      );
    }
    segments.add(
      SegmentScript(
        photoId: photo.id,
        line: line,
        // hasPerson folds the unknown case to true, so person-unknown
        // photos take the person route here too (spec §4-01).
        motionPrompt: photo.hasPerson
            ? null
            : _composeMotionPrompt(photo.motionHint),
      ),
    );
  }
  final totalChars = segments.fold<int>(0, (sum, s) => sum + s.line.length);
  return VideoScript(segments: segments, totalChars: totalChars);
}

/// Runs the 03 script step (spec §4-03): one narration line per selected
/// photo, 60–80 chars in total, plus code-composed motion prompts for
/// non-person segments.
///
/// Failure handling: transport and JSON-parse failures are retried inside
/// [QwenClient.chatJson]; a reply that decodes but violates the post-parse
/// validation (segment count, line length) is retried here once as
/// [ErrorClass.transient], then rethrown — the step must never degrade to an
/// empty script (spec §6 重试 ×2, no quiet fallback).
Future<VideoScript> runScript({
  required List<PhotoInfo> selected,
  required QwenClient llm,
}) async {
  final user = _userPrompt(selected);
  for (var attempt = 0; ; attempt++) {
    final reply = await llm.chatJson(system: _systemPrompt, user: user);
    try {
      return _parse(reply, selected);
    } on PipelineError catch (e) {
      if (e.cls != ErrorClass.transient || attempt >= 1) rethrow;
    }
  }
}
