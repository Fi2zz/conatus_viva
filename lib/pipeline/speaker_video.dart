import 'dart:io';

import 'bailian/wan30_video.dart';
import 'ffmpeg.dart';
import 'host.dart';
import 'video_generation.dart';

/// 文生视频时长下限（万相 3.0 支持 2–30 秒）。
const int t2vMinDurationS = 2;

/// 文生视频时长上限（万相 3.0 支持 2–30 秒）。
const int t2vMaxDurationS = 30;

/// 一次主讲人视频生成的结果：原始 t2v 片段 + 叠加主讲人后的成片。
class SpeakerVideoResult {
  const SpeakerVideoResult({
    required this.rawVideoPath,
    required this.finalVideoPath,
    required this.durationS,
    required this.taskId,
  });

  /// 万相原始输出（未叠加主讲人）。
  final String rawVideoPath;

  /// 叠加主讲人后的成片路径（供下载）。
  final String finalVideoPath;

  /// 请求的成片秒数。
  final int durationS;

  /// 万相任务 id（24h 查询窗口）。
  final String taskId;
}

/// 叠加主讲人的执行体；默认跑真实 ffmpeg，测试可注入桩以避免真视频字节。
typedef AvatarOverlayFn = Future<void> Function({
  required File video,
  required File avatar,
  required File out,
});

/// 端到端生成一条主讲人文生视频：拼方言提示词 → 万相 3.0 文生视频 →
/// ffmpeg 把 [avatar] 叠加到左下角 → 返回成片路径。
///
/// [theme] 作为视频提示词，[dialect] 经 [t2vPrompt] 追加方言指令（未知地区
/// 回落普通话）。产物落在 `<baseDir>/<contentId>/{raw,video}.mp4`。
Future<SpeakerVideoResult> generateSpeakerVideo({
  required Wan30VideoClient client,
  required String theme,
  required String dialect,
  required int durationS,
  required String contentId,
  required File avatar,
  String baseDir = 'pipeline_out/speaker',
  int pollSeconds = 15,
  int maxWaitMinutes = 10,
  Future<void> Function(Duration delay)? sleep,
  void Function(String message)? onProgress,
  AvatarOverlayFn? overlay,
}) async {
  final dir = Directory('$baseDir/$contentId')..createSync(recursive: true);
  final rawPath = '${dir.path}/raw.mp4';
  final finalPath = '${dir.path}/video.mp4';
  final prompt = t2vPrompt(theme, dialect);

  final generated = await generateVideo(
    client: client,
    prompt: prompt,
    durationS: durationS,
    outFile: rawPath,
    pollSeconds: pollSeconds,
    maxWaitMinutes: maxWaitMinutes,
    sleep: sleep,
    onProgress: onProgress,
  );

  final doOverlay =
      overlay ??
      ({required File video, required File avatar, required File out}) =>
          runFfmpeg(overlayAvatarArgs(video: video, avatar: avatar, out: out));
  await doOverlay(video: File(rawPath), avatar: avatar, out: File(finalPath));

  return SpeakerVideoResult(
    rawVideoPath: rawPath,
    finalVideoPath: finalPath,
    durationS: durationS,
    taskId: generated.taskId,
  );
}
