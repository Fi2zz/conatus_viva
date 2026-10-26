/// 短剧产物的内容 hash：只把影响画面的输入纳入，保证缓存与失效判定稳定。
library;

import '../storyboard.dart';
import 'hash.dart';
import 'series.dart';

String dramaCastHash({
  required DramaCastMember member,
  required String model,
  required String size,
}) => dramaHash(<String, Object?>{
  'kind': 'cast',
  'name': member.name,
  'description': member.description,
  'model': model,
  'size': size,
});

String dramaFrameHash({
  required Shot shot,
  required String? castAvatarHash,
  required String model,
  required String size,
}) => dramaHash(<String, Object?>{
  'kind': 'frame',
  'shot': shot.id,
  'visual': (shot.visual ?? '').trim().isEmpty ? shot.line : shot.visual,
  'framing': shot.framing,
  'shot_kind': shotKindToWire(shot.kind),
  'speaker': shot.speaker,
  'cast_avatar_hash': castAvatarHash,
  'model': model,
  'size': size,
});

String dramaClipHash({
  required Shot shot,
  required String frameHash,
  required String route,
  required String model,
  required String resolution,
  required int i2vSeconds,
}) => dramaHash(<String, Object?>{
  'kind': 'clip',
  'shot': shot.id,
  'frame_hash': frameHash,
  'motion': shot.motion ?? '',
  'duration_s': shot.durationS,
  'route': route,
  'model': model,
  'resolution': resolution,
  'i2v_seconds': i2vSeconds,
});
