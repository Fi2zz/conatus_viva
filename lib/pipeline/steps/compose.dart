import 'dart:io';

import '../artifacts.dart';
import '../bailian/tts.dart';
import '../errors.dart';
import '../ffmpeg.dart';
import '../srt.dart';
import '../state.dart';
import 'script.dart';

/// Shared per-run collaborators (parameter-count limit; mirrors render.dart).
class _ComposeContext {
  const _ComposeContext({required this.work, required this.state,
      required this.scripts, required this.audios});

  final Workdir work;
  final ContentState state;
  final List<SegmentScript> scripts;
  final List<TtsAudio> audios;
}

/// Runs the 06 compose step (spec §4「06 compose」): muxes each segment clip
/// (`05_clips/seg_<i>.mp4`) with its TTS audio into `06_concat/seg_<i>.mp4`,
/// concats the parts into `06_final.mp4`, and writes `06_final.srt`.
///
/// A video/audio stream-total drift over 0.2s throws [PipelineError] with
/// [ErrorClass.fatal] (`av_mismatch`) and nothing publishes (Review Focus
/// #5). Artifacts publish via tmp+rename; the concat list file is deleted
/// once the concat verifies. Idempotency: non-empty `06_final.mp4` +
/// `06_final.srt` short-circuit the step (spec §4 执行契约), as in render.
Future<File> runComposeStep({
  required Workdir work,
  required ContentState state,
  required List<SegmentScript> scripts,
  required List<TtsAudio> audios,
}) async {
  final done = stepDone(work, ArtifactPaths.finalVideo) &&
      stepDone(work, ArtifactPaths.finalSrt);
  if (done) return work.file(ArtifactPaths.finalVideo);
  final ctx =
      _ComposeContext(work: work, state: state, scripts: scripts, audios: audios);
  _checkInputs(ctx);
  final record = state.step('compose');
  record.status = StepStatus.running;
  record.attempts += 1;
  record.t.add('start');
  state.save();
  try {
    final parts = await _muxSegments(ctx);
    final tmpFinal = await _concatParts(work, parts);
    await _publish(ctx, tmpFinal);
    record.status = StepStatus.succeeded;
    record.t.add('end');
    state.save();
    return work.file(ArtifactPaths.finalVideo);
  } on PipelineError catch (e) {
    record.status = StepStatus.failed;
    record.error = e;
    state.save();
    rethrow;
  }
}

void _checkInputs(_ComposeContext ctx) {
  final count = ctx.scripts.length;
  if (count == ctx.audios.length && count == ctx.state.segments.length) return;
  throw PipelineError(
    ErrorClass.fatal,
    'compose got $count scripts, ${ctx.audios.length} audios, '
    '${ctx.state.segments.length} segments',
  );
}

SegmentState _segmentFor(ContentState state, int i) {
  for (final seg in state.segments) {
    if (seg.i == i) return seg;
  }
  throw PipelineError(ErrorClass.fatal, 'compose: no segment state for $i');
}

Future<List<File>> _muxSegments(_ComposeContext ctx) async {
  ctx.work.dirOf(ArtifactPaths.concatDir).createSync(recursive: true);
  final parts = <File>[];
  for (var i = 0; i < ctx.scripts.length; i++) {
    parts.add(await _muxSegment(ctx, i));
  }
  return parts;
}

/// One segment: TTS audio trimmed/padded to the clip length, video
/// stream-copied, published via rename (same idiom as render).
Future<File> _muxSegment(_ComposeContext ctx, int i) async {
  final seg = _segmentFor(ctx.state, i);
  final dest = ctx.work.file('${ArtifactPaths.concatDir}/seg_$i.mp4');
  final tmp = File('${dest.path}.tmp.mp4');
  try {
    await runFfmpeg(
      muxArgs(
        video: ctx.work.file('${ArtifactPaths.clipsDir}/seg_$i.mp4'),
        audio: ctx.audios[i].wav,
        audioS: ctx.audios[i].seconds,
        durationS: seg.durationS,
        out: tmp,
      ),
    );
    tmp.renameSync(dest.path);
  } on FfmpegException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'mux failed for seg_$i: $e');
  }
  return dest;
}

/// Concats the muxed parts into a tmp final; the list carries absolute
/// paths (the demuxer resolves relative ones against the list's directory).
Future<File> _concatParts(Workdir work, List<File> parts) async {
  final tmp = File('${work.file(ArtifactPaths.finalVideo).path}.tmp.mp4');
  final absolute = [for (final part in parts) part.absolute];
  try {
    await writeConcatList(parts: absolute, out: tmp);
    await runFfmpeg(concatArgs(parts: absolute, out: tmp));
  } on FfmpegException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'concat failed: $e');
  }
  return tmp;
}

/// Verifies A/V drift, deletes the concat list (compose owns its
/// lifecycle), then publishes SRT + video via tmp+rename.
Future<void> _publish(_ComposeContext ctx, File tmpFinal) async {
  await _verifyAvSync(tmpFinal);
  await _cleanupConcatList(tmpFinal);
  _writeSrt(ctx);
  _renameOver(tmpFinal, ctx.work.file(ArtifactPaths.finalVideo));
}

Future<void> _cleanupConcatList(File concatOut) async {
  final list = concatListFileFor(concatOut);
  if (list.existsSync()) await list.delete();
}

void _renameOver(File tmp, File dest) {
  try {
    tmp.renameSync(dest.path);
  } on FileSystemException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'cannot publish ${dest.path}: $e');
  }
}

/// Review Focus #5: |video total − audio total| ≤ 0.2s, else fatal
/// `av_mismatch` and nothing publishes.
Future<void> _verifyAvSync(File composed) async {
  double video;
  double audio;
  try {
    video = await streamDurationSeconds(composed, 'v:0');
    audio = await streamDurationSeconds(composed, 'a:0');
  } on FfmpegException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'ffprobe failed on $composed: $e');
  }
  final drift = (video - audio).abs();
  if (drift > 0.2) {
    throw PipelineError(
      ErrorClass.fatal,
      'av_mismatch: video ${video}s vs audio ${audio}s',
    );
  }
}

/// `06_final.srt` — timings accumulate the planned clip durations
/// (`SegmentState.durationS`), ends capped by the TTS audio length.
void _writeSrt(_ComposeContext ctx) {
  final inputs = <SegmentInput>[];
  var start = 0.0;
  for (var i = 0; i < ctx.scripts.length; i++) {
    final seg = _segmentFor(ctx.state, i);
    inputs.add(
      SegmentInput(
        line: ctx.scripts[i].line,
        startVideoS: start,
        videoDurationS: seg.durationS.toDouble(),
        audioS: ctx.audios[i].seconds,
      ),
    );
    start += seg.durationS;
  }
  _publishText(
    ctx.work.file(ArtifactPaths.finalSrt),
    renderSrt(buildSrt(segs: inputs)),
  );
}

void _publishText(File dest, String content) {
  final tmp = File('${dest.path}.tmp');
  try {
    tmp.writeAsStringSync(content, flush: true);
    tmp.renameSync(dest.path);
  } on FileSystemException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'cannot write ${dest.path}: $e');
  }
}
