import 'dart:io';

import 'bailian/dashscope_video.dart';
import 'bailian/wan30_video.dart';
import 'errors.dart';

/// Outcome of one 文生视频 run.
class TextToVideoResult {
  const TextToVideoResult({
    required this.filePath,
    required this.taskId,
    required this.durationS,
  });

  /// Where the downloaded mp4 landed.
  final String filePath;

  /// The provider task id (24h query window).
  final String taskId;

  /// Requested output seconds.
  final int durationS;
}

const List<Duration> _retryDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
];

/// Drives one 万相 3.0 text-to-video task end to end: submit a prompt-only
/// body, poll to a terminal state, download the mp4 to [outFile].
///
/// This is a one-shot CLI capability (no `state.json`, no resume): a transient
/// provider error retries ×2 with the pipeline backoff, an audit rejection
/// fails immediately, and the clip is only downloaded on success (spec §6).
Future<TextToVideoResult> generateTextToVideo({
  required Wan30VideoClient client,
  required String prompt,
  required int durationS,
  required String outFile,
  int pollSeconds = 15,
  int maxWaitMinutes = 10,
  Future<void> Function(Duration delay)? sleep,
  DateTime Function()? now,
  void Function(String message)? onProgress,
}) async {
  final wait = sleep ?? (Duration d) => Future<void>.delayed(d);
  final clock = now ?? DateTime.now;
  final emit = onProgress ?? (String _) {};

  emit('提交文生视频任务（${durationS}s）…');
  final task = await _withRetry(
    () => client.submitTextToVideo(prompt: prompt, durationS: durationS),
    wait,
  );
  emit('任务 ${task.taskId} 已提交，等待渲染');

  final terminal = await _pollToTerminal(
    client: client,
    taskId: task.taskId,
    clock: clock,
    wait: wait,
    emit: emit,
    pollSeconds: pollSeconds,
    maxWaitMinutes: maxWaitMinutes,
  );
  if (terminal.status == I2vStatus.failed) {
    throw _terminalError(terminal.errorCode);
  }
  final url = terminal.videoUrl;
  if (url == null) {
    throw const PipelineError(
      ErrorClass.transient,
      'wan3.0 t2v succeeded without video_url',
    );
  }

  emit('下载视频片段…');
  final bytes = await _withRetry(() => client.downloadClip(url), wait);
  _writeFile(outFile, bytes);
  emit('已保存：$outFile');

  return TextToVideoResult(
    filePath: outFile,
    taskId: task.taskId,
    durationS: durationS,
  );
}

Future<I2vTask> _pollToTerminal({
  required Wan30VideoClient client,
  required String taskId,
  required DateTime Function() clock,
  required Future<void> Function(Duration) wait,
  required void Function(String) emit,
  required int pollSeconds,
  required int maxWaitMinutes,
}) async {
  final startedAt = clock();
  final deadline = startedAt.add(Duration(minutes: maxWaitMinutes));
  for (;;) {
    final task = await _withRetry(() => client.poll(taskId), wait);
    final waited = clock().difference(startedAt).inSeconds;
    emit('渲染中（${task.status.name}，已等 ${waited}s）…');
    if (task.status != I2vStatus.running) return task;
    if (clock().isAfter(deadline)) {
      throw PipelineError(ErrorClass.fatal, 'wan3.0 t2v task $taskId timed out');
    }
    await wait(Duration(seconds: pollSeconds));
  }
}

/// Audit rejections are never retried and are surfaced distinctly; any other
/// provider failure is transient (the failed task was not billed).
PipelineError _terminalError(String? code) {
  final resolved = code ?? 'unknown';
  final audit =
      resolved.contains('IPInfringementSuspect') ||
      resolved.contains('DataInspectionFailed');
  return PipelineError(
    audit ? ErrorClass.auditReject : ErrorClass.transient,
    'wan3.0 t2v task failed: $resolved',
    remoteCode: resolved,
  );
}

/// Retries only transient [PipelineError]s ([_retryDelays] backoff); anything
/// else (audit reject, fatal) propagates immediately.
Future<T> _withRetry<T>(
  Future<T> Function() action,
  Future<void> Function(Duration) wait,
) async {
  for (var failures = 0; ; ) {
    try {
      return await action();
    } on PipelineError catch (e) {
      if (e.cls != ErrorClass.transient || failures >= _retryDelays.length) {
        rethrow;
      }
      await wait(_retryDelays[failures]);
      failures++;
    }
  }
}

void _writeFile(String path, List<int> bytes) {
  final dest = File(path);
  try {
    dest.parent.createSync(recursive: true);
    final tmp = File('$path.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(path);
  } on FileSystemException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'cannot write $path: $e');
  }
}
