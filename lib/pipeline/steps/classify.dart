import 'dart:io';

import '../bailian/llm.dart';
import '../errors.dart';
import 'ingest.dart';

/// One photo's verdict from the 01 classify step (spec §4「01 classify」),
/// serialized as an element of `01_classify.json`.
class PhotoInfo {
  const PhotoInfo({
    required this.id,
    required this.hasPerson,
    required this.quality,
    required this.motionHint,
    required this.caption,
    required this.personUnknown,
  });

  /// The [IngestedPhoto.id] this verdict belongs to.
  final String id;

  /// Whether the photo shows a recognisable person. The unknown case is
  /// folded to `true` (person route → Ken Burns) — see [personUnknown].
  final bool hasPerson;

  /// Overall score in 1..5 (1 worst, 5 best): sharpness, framing, light.
  final int quality;

  /// One-line motion suggestion (camera/subject movement) feeding the i2v
  /// prompt in step 05. Empty when the model had nothing to suggest.
  final String motionHint;

  /// One-line description of the frame, feeding the 03 script step.
  final String caption;

  /// `true` only when the model could not answer (or its answer violated the
  /// fixed JSON shape after one retry) and [hasPerson] was conservatively
  /// folded to `true` (spec §4-01 保守降级).
  final bool personUnknown;
}

/// Fixed system prompt: the reply must be the bare JSON object
/// `{"has_person":…,"quality":1-5,"motion_hint":…,"caption":…}`
/// (spec §4「01 classify」). [QwenClient.chatJson] appends its own
/// no-fences / no-explanation instruction on top of this.
const String _systemPrompt = '''
审阅用户给出的这一张照片，只输出一个 JSON 对象，字段固定：
{"has_person": bool, "quality": int, "motion_hint": string, "caption": string}
- has_person: 照片中是否出现可辨识的人物，只输出 true 或 false
- quality: 综合清晰度、构图与光线的评分，1 到 5 的整数，5 最好
- motion_hint: 一句话动效建议（镜头或主体如何缓慢运动），没有明确想法就输出空字符串
- caption: 一句话描述画面内容，供后续撰稿使用
不要输出 Markdown 代码围栏，不要输出任何解释。
''';

const String _userPrompt = '请给出这张照片的判定 JSON。';

/// Classifies every photo in [photos], in order, with one multimodal call
/// per photo (spec §4「01 classify」).
///
/// Failure handling per photo (spec §4-01 保守降级):
/// - the [QwenClient.chatJson] call runs with `maxRetries: 1`, so transport
///   errors and non-JSON replies get exactly one retry with backoff (§6);
/// - an answer that decodes as JSON but violates the fixed field shape gets
///   one more full call from here;
/// - when both rounds fail the photo degrades to
///   `hasPerson=true, personUnknown=true` — unknown folds into the person
///   route (Ken Burns), which avoids both the face risk and wasted spend;
/// - [ErrorClass.fatal] (bad key, unreadable image file) never degrades: it
///   is rethrown so the run fails fast without consuming retries (spec §6).
Future<List<PhotoInfo>> runClassify({
  required List<IngestedPhoto> photos,
  required QwenClient llm,
}) async {
  final classified = <PhotoInfo>[];
  for (final photo in photos) {
    classified.add(await _classifyOne(photo, llm));
  }
  return classified;
}

Future<PhotoInfo> _classifyOne(IngestedPhoto photo, QwenClient llm) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final raw = await llm.chatJson(
        system: _systemPrompt,
        user: _userPrompt,
        images: <File>[photo.file],
        maxRetries: 1,
      );
      return _parse(photo.id, raw);
    } on FormatException {
      // Shape violation is retried once here; a second bad answer degrades.
      if (attempt >= 1) return _degraded(photo.id);
    } on PipelineError catch (e) {
      // chatJson already retried once; fatal must fail fast (spec §6).
      if (e.cls == ErrorClass.fatal) rethrow;
      return _degraded(photo.id);
    }
  }
  return _degraded(photo.id);
}

/// Converts one model reply into a [PhotoInfo], throwing [FormatException]
/// when the fixed shape is violated (→ one retry, then conservative
/// degrade). `motion_hint`/`caption` are optional text and default to `''`;
/// `has_person`/`quality` are mandatory for routing and ranking.
PhotoInfo _parse(String id, Map<String, dynamic> raw) {
  final hasPerson = raw['has_person'];
  final quality = raw['quality'];
  if (hasPerson is! bool) {
    throw FormatException('has_person must be a boolean, got $hasPerson');
  }
  if (quality is! num) {
    throw FormatException('quality must be a number, got $quality');
  }
  // Model answers can drift outside 1..5; clamp instead of failing the photo.
  final score = quality.toInt();
  return PhotoInfo(
    id: id,
    hasPerson: hasPerson,
    quality: score < 1 ? 1 : (score > 5 ? 5 : score),
    motionHint: raw['motion_hint'] is String
        ? raw['motion_hint'] as String
        : '',
    caption: raw['caption'] is String ? raw['caption'] as String : '',
    personUnknown: false,
  );
}

/// spec §4-01 保守降级: unknown folds into the person route (Ken Burns, zero
/// cost), neutral quality keeps the photo eligible without outranking shots
/// the model actually scored.
PhotoInfo _degraded(String id) => PhotoInfo(
  id: id,
  hasPerson: true,
  quality: 3,
  motionHint: '',
  caption: '',
  personUnknown: true,
);
