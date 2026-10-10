import 'dart:convert';
import 'dart:io';

import '../artifacts.dart';
import '../bailian/i2v.dart';
import '../bailian/tts.dart';
import '../bailian/uploader.dart';
import '../config.dart';
import '../errors.dart';
import '../ffmpeg.dart';
import '../state.dart';
import 'classify.dart';
import 'script.dart';

/// Thrown when a 万相 task reaches FAILED without an audit code: official
/// failures are not billed, so the segment resubmits (spec §6 重试 ×2).
class _I2vTaskFailed implements Exception {
  const _I2vTaskFailed(this.code);
  final String code;
}

/// Thrown when a 万相 task FAILED with an audit code — never retried; the
/// segment degrades to Ken Burns (spec §6 `audit_reject`).
class _AuditReject implements Exception {
  const _AuditReject(this.code);
  final String code;
}

/// Shared per-run collaborators, so the segment helpers stay under the
/// parameter-count limit.
class _RenderContext {
  const _RenderContext({
    required this.scripts,
    required this.audios,
    required this.photos,
    required this.work,
    required this.state,
    required this.i2v,
    required this.urls,
    required this.cfg,
    required this.sleep,
    required this.now,
    this.onProgress,
  });

  final List<SegmentScript> scripts;
  final List<TtsAudio> audios;
  final List<PhotoInfo> photos;
  final Workdir work;
  final ContentState state;
  final I2vClient i2v;
  final ImageUrlProvider urls;
  final PipelineConfig cfg;

  /// Human-readable progress sink (the CLI prints these); null in tests.
  final void Function(String message)? onProgress;

  /// Waits between polls/retries. Tests pass a no-op so the suite never
  /// waits out the real 15s poll interval.
  final Future<void> Function(Duration delay) sleep;

  /// Clock for resume-staleness and the poll deadline; injectable in tests.
  final DateTime Function() now;

  static Future<void> realSleep(Duration delay) => Future<void>.delayed(delay);
}

const List<Duration> _retryDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
];

/// Runs the 05 render step (spec §4「05 render」): one clip per segment at
/// `05_clips/seg_<i>.mp4`, normalized to 1280x720/24fps, plus
/// `05_clips/status.json`.
///
/// Routing: `hasPerson || personUnknown` → Ken Burns (zero cost, the i2v
/// client is never touched); otherwise 万相 i2v. Resume: a persisted
/// `task_id` younger than 24h on a `submitted`/`downloading` segment is
/// polled without resubmitting (`stale_task`, spec §6); `degraded` /
/// `succeeded` / `failed` segments never resume polling. `audit_reject`
/// degrades the segment to Ken Burns at zero cost; other task failures and
/// transient errors retry ×2 with 1s/2s backoff; poll timeout
/// (`i2vMaxWaitMinutes`) marks the segment failed for manual intervention.
/// Every status transition is persisted via [ContentState.save] — the
/// process may be killed at any time.
///
/// Idempotency: a non-empty `status.json` short-circuits the whole step
/// (artifact-exists skip, spec §4 执行契约); per segment, a `succeeded` or
/// `degraded` segment with its clip on disk is skipped.
Future<void> runRenderStep({
  required List<SegmentScript> scripts,
  required List<TtsAudio> audios,
  required List<PhotoInfo> photos,
  required Workdir work,
  required ContentState state,
  required I2vClient i2v,
  required ImageUrlProvider urls,
  required PipelineConfig cfg,
  Future<void> Function(Duration delay)? sleep,
  DateTime Function()? now,
  void Function(String message)? onProgress,
}) async {
  if (stepDone(work, ArtifactPaths.renderStatus)) return;
  final ctx = _RenderContext(
    scripts: scripts, audios: audios, photos: photos, work: work,
    state: state, i2v: i2v, urls: urls, cfg: cfg,
    sleep: sleep ?? _RenderContext.realSleep, now: now ?? DateTime.now,
    onProgress: onProgress,
  );
  if (audios.length != scripts.length) {
    throw PipelineError(
      ErrorClass.fatal,
      'render got ${scripts.length} scripts but ${audios.length} audios',
    );
  }
  final record = state.step('render');
  record.status = StepStatus.running;
  record.attempts += 1;
  record.t.add('start');
  state.save();
  try {
    _createClipsDir(work);
    for (var i = 0; i < scripts.length; i++) {
      await _renderSegment(ctx, i);
    }
    await _normalizeAll(ctx);
    _writeStatus(ctx);
    record.status = StepStatus.succeeded;
    record.t.add('end');
    state.save();
  } on PipelineError catch (e) {
    record.status = StepStatus.failed;
    record.error = e;
    state.save();
    rethrow;
  }
}

void _createClipsDir(Workdir work) {
  try {
    work.dirOf(ArtifactPaths.clipsDir).createSync(recursive: true);
  } on FileSystemException catch (e) {
    throw PipelineError(
      ErrorClass.fatal,
      'cannot create ${ArtifactPaths.clipsDir}: $e',
    );
  }
}

/// One segment: skip when finished, else Ken Burns or i2v by route.
Future<void> _renderSegment(_RenderContext ctx, int i) async {
  final photo = _photoFor(ctx, ctx.scripts[i].photoId);
  final seg = _segmentState(ctx, i, photo);
  final clip = _clipFile(ctx.work, i);
  final finished =
      seg.status == SegmentStatus.succeeded || seg.status == SegmentStatus.degraded;
  if (finished && clip.existsSync() && clip.lengthSync() > 0) {
    _emitProgress(ctx, '段 $i/${ctx.scripts.length}：已完成，跳过');
    return;
  }
  final kenBurnsRoute =
      photo.hasPerson || photo.personUnknown || seg.route == SegmentState.routeKenburns;
  if (kenBurnsRoute) {
    await _renderKenBurns(ctx, seg, photo);
    return;
  }
  await _renderI2v(ctx, seg, photo);
}

/// Finds the persisted segment for [i] or appends a fresh one (persisted
/// immediately, so a crash between segments never loses the route decision).
SegmentState _segmentState(_RenderContext ctx, int i, PhotoInfo photo) {
  for (final seg in ctx.state.segments) {
    if (seg.i == i) return seg;
  }
  final kenBurns = photo.hasPerson || photo.personUnknown;
  final seg = SegmentState(
    i: i,
    route: kenBurns ? SegmentState.routeKenburns : SegmentState.routeI2v,
    audioS: ctx.audios[i].seconds,
    durationS: _clampDuration(ctx.cfg, ctx.audios[i].seconds),
  );
  ctx.state.segments.add(seg);
  ctx.state.save();
  return seg;
}

/// `ceil(audio seconds)` clamped into `[minClipS, maxClipS]` (spec §4-05).
int _clampDuration(PipelineConfig cfg, double seconds) {
  final ceil = seconds.ceil();
  if (ceil < cfg.minClipS) return cfg.minClipS;
  if (ceil > cfg.maxClipS) return cfg.maxClipS;
  return ceil;
}

PhotoInfo _photoFor(_RenderContext ctx, String photoId) {
  for (final photo in ctx.photos) {
    if (photo.id == photoId) return photo;
  }
  throw PipelineError(ErrorClass.fatal, 'no photo info for $photoId');
}

File _clipFile(Workdir work, int i) =>
    work.file('${ArtifactPaths.clipsDir}/seg_$i.mp4');

/// The segment's photo on local disk: ingest stores every input under
/// `00_inputs/<id>.<ext>` (spec §3.1 — downstream always uses local copies).
File _photoFile(Workdir work, String photoId) {
  final dir = work.dirOf(ArtifactPaths.inputsDir);
  if (dir.existsSync()) {
    for (final entity in dir.listSync()) {
      if (entity is File && _stem(entity.path) == photoId) return entity;
    }
  }
  throw PipelineError(
    ErrorClass.fatal,
    'photo $photoId not found in ${ArtifactPaths.inputsDir}',
  );
}

String _stem(String path) {
  final name = path.split(Platform.pathSeparator).last;
  final cut = name.lastIndexOf('.');
  return cut <= 0 ? name : name.substring(0, cut);
}

/// Reports a human-readable progress line to the host; a no-op in tests.
void _emitProgress(_RenderContext ctx, String message) =>
    ctx.onProgress?.call(message);

/// Ken Burns route: zoompan render straight to the segment clip (zero cost).
/// A degraded segment keeps its `degraded` status — the clip exists but the
/// audit rejection stays on record.
Future<void> _renderKenBurns(
  _RenderContext ctx,
  SegmentState seg,
  PhotoInfo photo,
) async {
  final clip = _clipFile(ctx.work, seg.i);
  final tmp = File('${clip.path}.tmp.mp4');
  _emitProgress(ctx, '段 ${seg.i}：Ken Burns 渲染（${seg.durationS}s）…');
  try {
    await runFfmpeg(
      kenBurnsArgs(img: _photoFile(ctx.work, photo.id), durationS: seg.durationS, out: tmp),
    );
    tmp.renameSync(clip.path);
  } on FfmpegException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'ken burns failed for seg ${seg.i}: $e');
  }
  if (seg.status != SegmentStatus.degraded) seg.markSucceeded();
  ctx.state.save();
  _emitProgress(ctx, '段 ${seg.i}：Ken Burns 片段就绪');
}

/// i2v route with resume gate and retry ×2 (spec §6).
Future<void> _renderI2v(
  _RenderContext ctx,
  SegmentState seg,
  PhotoInfo photo,
) async {
  String? taskId = _resumeTaskId(seg, ctx.now);
  if (taskId != null) _emitProgress(ctx, '段 ${seg.i}：恢复已提交任务 $taskId，继续轮询');
  for (var failures = 0; ; ) {
    try {
      taskId ??= await _submit(ctx, seg, photo);
      await _finishTask(ctx, seg, taskId);
      return;
    } on _AuditReject catch (e) {
      await _degrade(ctx, seg, photo, e.code);
      return;
    } on _I2vTaskFailed catch (e) {
      taskId = null; // official failure is not billed — safe to resubmit
      failures = await _retriedOrThrow(ctx, seg, failures, 'i2v task failed: ${e.code}');
    } on PipelineError catch (e) {
      if (e.cls != ErrorClass.transient) _failSegment(ctx, seg, e);
      failures = await _retriedOrThrow(ctx, seg, failures, e.message);
    }
  }
}

/// The carried Task 3 ruling: only `submitted`/`downloading` segments may
/// resume polling — `degraded`/`succeeded`/`failed` never do (a degraded
/// segment still holds its old task_id, which must not be polled).
String? _resumeTaskId(SegmentState seg, DateTime Function() now) {
  final polling =
      seg.status == SegmentStatus.submitted || seg.status == SegmentStatus.downloading;
  return polling ? seg.resumableTask(now: now()) : null;
}

/// Publishes the photo, submits the task, and persists the task id
/// immediately (the 24h resume window starts here).
Future<String> _submit(_RenderContext ctx, SegmentState seg, PhotoInfo photo) async {
  _emitProgress(ctx, '段 ${seg.i}：上传照片并提交万相（${seg.durationS}s）…');
  final published = await ctx.urls.publish(_photoFile(ctx.work, photo.id));
  final task = await ctx.i2v.submit(
    imgUrl: published.url,
    prompt: ctx.scripts[seg.i].motionPrompt ?? '',
    durationS: seg.durationS,
  );
  seg.markSubmitted(task.taskId, now: ctx.now());
  ctx.state.save();
  _emitProgress(ctx, '段 ${seg.i}：任务 ${task.taskId} 已提交，等待渲染');
  return task.taskId;
}

/// Polls [taskId] to a terminal state, then downloads the clip. The run
/// level cost is recorded only after the bytes are on disk (a killed
/// process then never bills an un-downloaded task).
Future<void> _finishTask(_RenderContext ctx, SegmentState seg, String taskId) async {
  final task = await _pollUntilTerminal(ctx, seg, taskId);
  if (task.status == I2vStatus.failed) {
    final code = task.errorCode ?? 'unknown';
    if (_auditRejected(code)) throw _AuditReject(code);
    throw _I2vTaskFailed(code);
  }
  await _downloadClip(ctx, seg, task);
}

Future<I2vTask> _pollUntilTerminal(
  _RenderContext ctx,
  SegmentState seg,
  String taskId,
) async {
  final startedAt = ctx.now();
  final deadline = startedAt.add(Duration(minutes: ctx.cfg.i2vMaxWaitMinutes));
  I2vStatus? lastSeen;
  for (;;) {
    final task = await ctx.i2v.poll(taskId);
    if (task.status != lastSeen) {
      lastSeen = task.status;
      ctx.state.save(); // every poll state change lands on disk
    }
    final waited = ctx.now().difference(startedAt).inSeconds;
    _emitProgress(ctx, '段 ${seg.i}：渲染中（${task.status.name}，已等 ${waited}s）…');
    if (task.status != I2vStatus.running) return task;
    if (ctx.now().isAfter(deadline)) {
      throw PipelineError(ErrorClass.fatal, 'i2v task $taskId timed out');
    }
    await ctx.sleep(Duration(seconds: ctx.cfg.i2vPollSeconds));
  }
}

bool _auditRejected(String code) =>
    code.contains('IPInfringementSuspect') || code.contains('DataInspectionFailed');

Future<void> _downloadClip(_RenderContext ctx, SegmentState seg, I2vTask task) async {
  final url = task.videoUrl;
  if (url == null) {
    throw PipelineError(ErrorClass.transient, 'i2v success without video_url');
  }
  seg.markDownloading();
  ctx.state.save();
  _emitProgress(ctx, '段 ${seg.i}：渲染完成，下载片段…');
  final bytes = await ctx.i2v.downloadClip(url);
  _storeClip(_clipFile(ctx.work, seg.i), bytes);
  seg.markSucceeded();
  ctx.state.cost.recordI2vSeconds(seg.durationS);
  ctx.state.save();
  _emitProgress(ctx, '段 ${seg.i}：i2v 片段就绪（计费 ${seg.durationS}s）');
}

void _storeClip(File dest, List<int> bytes) {
  final tmp = File('${dest.path}.tmp');
  try {
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(dest.path);
  } on FileSystemException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'cannot store ${dest.path}: $e');
  }
}

/// Audit rejection: zero cost, Ken Burns fallback clip (spec §6 降级表).
Future<void> _degrade(
  _RenderContext ctx,
  SegmentState seg,
  PhotoInfo photo,
  String code,
) async {
  seg.markDegraded('i2v audit reject: $code');
  ctx.state.cost.recordDegraded();
  ctx.state.save();
  await _renderKenBurns(ctx, seg, photo);
}

/// Sleeps with backoff and reports the next failure count; after two
/// retries the segment is marked failed and the error is rethrown.
Future<int> _retriedOrThrow(
  _RenderContext ctx,
  SegmentState seg,
  int failures,
  String message,
) async {
  if (failures >= _retryDelays.length) {
    final error = PipelineError(ErrorClass.transient, message);
    seg.markFailed(error.cls, error.message);
    ctx.state.save();
    throw error;
  }
  await ctx.sleep(_retryDelays[failures]);
  return failures + 1;
}

Never _failSegment(_RenderContext ctx, SegmentState seg, PipelineError e) {
  seg.markFailed(e.cls, e.message);
  ctx.state.save();
  throw e;
}

/// Normalizes every segment clip to the uniform 1280x720/24fps layout with
/// a silent audio track (spec §4-05 统一归一化), publishing via rename.
Future<void> _normalizeAll(_RenderContext ctx) async {
  for (var i = 0; i < ctx.scripts.length; i++) {
    final clip = _clipFile(ctx.work, i);
    final tmp = File('${clip.path}.norm.mp4');
    try {
      await runFfmpeg(normalizeArgs(input: clip, out: tmp));
      tmp.renameSync(clip.path);
    } on FfmpegException catch (e) {
      throw PipelineError(ErrorClass.fatal, 'normalize failed for seg_$i: $e');
    }
  }
}

/// `05_clips/status.json` — the step's completion marker (atomically
/// published, mirroring `durations.json` in the tts step).
void _writeStatus(_RenderContext ctx) {
  final dest = ctx.work.file(ArtifactPaths.renderStatus);
  final tmp = File('${dest.path}.tmp');
  final payload = jsonEncode(<String, dynamic>{
    'segments': <dynamic>[for (final seg in ctx.state.segments) seg.toJson()],
  });
  try {
    tmp.writeAsStringSync(payload, flush: true);
    tmp.renameSync(dest.path);
  } on FileSystemException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'cannot write ${dest.path}: $e');
  }
}
