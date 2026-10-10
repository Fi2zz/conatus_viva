import 'dart:convert';
import 'dart:io';

import '../artifacts.dart';
import '../bailian/tts.dart';
import '../config.dart';
import '../dialect_map.dart';
import '../errors.dart';
import '../state.dart';
import 'script.dart';

/// Runs the 04 tts step (spec §4「04 tts」): one dialect narration track per
/// script segment, stored as `04_audio/seg_<i>.wav`, plus the ffprobe
/// measured durations in `04_audio/durations.json`.
///
/// Idempotency: a valid `durations.json` covering every segment (and the
/// wavs behind it) short-circuits the step — the existing durations are
/// returned without any synthesis (artifact-exists skip, spec §4 执行契约 /
/// [stepDone]). The skip happens before any state transition, so a skipped
/// run leaves `state.json` untouched.
///
/// Failure handling (spec §4-04 降级链): a segment whose dialect synthesis
/// fails with [ErrorClass.transient] — [TtsClient.synth] already retried it
/// once — is re-synthesized with the mandarin instruction
/// (`mandarinSpec.instruction`, i.e. `请用普通话表达。`). If that fails too
/// (or the first failure is already fatal, e.g. a bad key) the step throws
/// [PipelineError] with [ErrorClass.fatal]: a run without audio cannot
/// continue. Each synthesized segment is written to its final `seg_<i>.wav`
/// (temp file + rename) before the next segment starts.
///
/// State record `tts` follows `running → succeeded | failed` and is saved
/// on every transition, so a killed process leaves a truthful
/// `state.json` behind.
Future<List<TtsAudio>> runTtsStep({
  required VideoScript script,
  required DialectSpec dialect,
  required PipelineConfig cfg,
  required TtsClient tts,
  required Workdir work,
  required ContentState state,
}) async {
  final count = script.segments.length;
  if (stepDone(work, ArtifactPaths.durations)) {
    final existing = _readDurations(work, count);
    if (existing != null) return existing;
  }

  final record = state.step('tts');
  record.status = StepStatus.running;
  record.attempts += 1;
  record.t.add('start');
  state.save();

  try {
    _createAudioDir(work);
    // spec §3: no voice_id → the fallback model's system voice; a configured
    // voice_id keeps the primary model (日后复刻完成只填 voice_id).
    final model = cfg.ttsVoiceId == null
        ? cfg.ttsFallbackModel
        : cfg.ttsModel;
    final audios = <TtsAudio>[];
    for (var i = 0; i < count; i++) {
      audios.add(
        await _segment(
          index: i,
          line: script.segments[i].line,
          dialect: dialect,
          model: model,
          cfg: cfg,
          tts: tts,
          work: work,
        ),
      );
    }
    _writeDurations(work, [for (final audio in audios) audio.seconds]);
    record.status = StepStatus.succeeded;
    record.t.add('end');
    state.save();
    return audios;
  } on PipelineError catch (e) {
    record.status = StepStatus.failed;
    record.error = e;
    state.save();
    rethrow;
  }
}

/// Synthesizes one segment: dialect instruction first; on an exhausted
/// transient failure, one mandarin re-synthesis (spec §4-04); if that fails
/// as well, the segment error is promoted to fatal for the whole run.
Future<TtsAudio> _segment({
  required int index,
  required String line,
  required DialectSpec dialect,
  required String model,
  required PipelineConfig cfg,
  required TtsClient tts,
  required Workdir work,
}) async {
  try {
    return await _synthesize(
      index: index,
      line: line,
      instruction: dialect.instruction,
      model: model,
      cfg: cfg,
      tts: tts,
      work: work,
    );
  } on PipelineError catch (e) {
    if (e.cls != ErrorClass.transient) rethrow;
    // Already the mandarin instruction — the mandated fallback would repeat
    // the identical request, so the run fails right here.
    if (dialect.instruction == mandarinSpec.instruction) {
      throw PipelineError(
        ErrorClass.fatal,
        'tts segment $index failed in mandarin: ${e.message}',
      );
    }
    try {
      return await _synthesize(
        index: index,
        line: line,
        instruction: mandarinSpec.instruction,
        model: model,
        cfg: cfg,
        tts: tts,
        work: work,
      );
    } on PipelineError catch (e2) {
      if (e2.cls != ErrorClass.transient) rethrow;
      throw PipelineError(
        ErrorClass.fatal,
        'tts segment $index failed in ${dialect.label} and mandarin: '
        '${e2.message}',
      );
    }
  }
}

/// Synthesizes [line] with [instruction] and stores the bytes at
/// `04_audio/seg_<index>.wav` — temp write + rename, so the final path only
/// ever holds complete audio — before returning (spec §3 先转存再继续).
Future<TtsAudio> _synthesize({
  required int index,
  required String line,
  required String instruction,
  required String model,
  required PipelineConfig cfg,
  required TtsClient tts,
  required Workdir work,
}) async {
  final audio = await tts.synth(
    text: line,
    model: model,
    voiceId: cfg.ttsVoiceId,
    fallbackVoice: cfg.ttsFallbackVoice,
    instruction: instruction,
  );
  final dest = work.file('${ArtifactPaths.audioDir}/seg_$index.wav');
  final tmp = File('${dest.path}.tmp');
  try {
    tmp.writeAsBytesSync(audio.wav.readAsBytesSync(), flush: true);
    tmp.renameSync(dest.path);
  } on FileSystemException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'cannot store ${dest.path}: $e');
  } finally {
    _discardTemp(audio.wav);
  }
  return TtsAudio(wav: dest, seconds: audio.seconds);
}

void _createAudioDir(Workdir work) {
  try {
    work.dirOf(ArtifactPaths.audioDir).createSync(recursive: true);
  } on FileSystemException catch (e) {
    throw PipelineError(
      ErrorClass.fatal,
      'cannot create ${ArtifactPaths.audioDir}: $e',
    );
  }
}

/// Publishes `durations.json` atomically (write `.tmp`, then rename) — the
/// file is the step's completion marker, so a crash mid-write leaves the
/// previous state (or no file) rather than a truncated one.
void _writeDurations(Workdir work, List<double> seconds) {
  final dest = work.file(ArtifactPaths.durations);
  final tmp = File('${dest.path}.tmp');
  try {
    tmp.writeAsStringSync(jsonEncode(seconds), flush: true);
    tmp.renameSync(dest.path);
  } on FileSystemException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'cannot write ${dest.path}: $e');
  }
}

/// The artifact-exists skip payload: `durations.json` parsed as one number
/// per segment with every `seg_<i>.wav` present and non-empty, else null
/// (invalid ⇒ re-synthesize).
List<TtsAudio>? _readDurations(Workdir work, int count) {
  Object? decoded;
  try {
    decoded = jsonDecode(work.file(ArtifactPaths.durations).readAsStringSync());
  } on Exception {
    return null;
  }
  if (decoded is! List || decoded.length != count) return null;
  final seconds = <double>[];
  for (final item in decoded) {
    if (item is! num) return null;
    seconds.add(item.toDouble());
  }
  final audios = <TtsAudio>[];
  for (var i = 0; i < count; i++) {
    final wav = work.file('${ArtifactPaths.audioDir}/seg_$i.wav');
    if (!wav.existsSync() || wav.lengthSync() == 0) return null;
    audios.add(TtsAudio(wav: wav, seconds: seconds[i]));
  }
  return audios;
}

/// Deletes the TtsClient temp directory behind a synthesized wav
/// (best-effort — a leak in the system temp dir must not fail the step).
void _discardTemp(File wav) {
  final parent = wav.parent;
  if (!parent.path.contains('conatus_tts_')) return;
  try {
    parent.deleteSync(recursive: true);
  } catch (_) {
    // Best-effort temp cleanup.
  }
}
