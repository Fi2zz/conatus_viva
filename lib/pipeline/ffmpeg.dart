import 'dart:io';

/// Local ffmpeg/ffprobe wrapper used by the render (Task 12) and compose
/// (Task 13) steps. Both binaries are resolved on `PATH`.

/// Thrown when an ffmpeg/ffprobe invocation exits non-zero (or when ffprobe
/// output cannot be parsed). [stderr] is preserved verbatim for diagnosis —
/// this wrapper never swallows it.
class FfmpegException implements Exception {
  const FfmpegException({required this.exitCode, required this.stderr});

  /// Process exit code of the failed invocation.
  final int exitCode;

  /// Combined diagnostic output of the failed invocation.
  final String stderr;

  @override
  String toString() => 'FfmpegException(exitCode: $exitCode): $stderr';
}

String _diagnostics(ProcessResult r) {
  final err = (r.stderr as String).trim();
  if (err.isNotEmpty) return err;
  final out = (r.stdout as String).trim();
  if (out.isNotEmpty) return out;
  return 'no output (exit ${r.exitCode})';
}

/// Duration of [media] in seconds via ffprobe (`format=duration`).
///
/// Throws [FfmpegException] when ffprobe fails or reports an unparseable
/// duration (e.g. missing file, non-media file).
Future<double> mediaDurationSeconds(File media) async {
  final r = await Process.run('ffprobe', [
    '-show_entries',
    'format=duration',
    '-v',
    'quiet',
    '-of',
    'csv=p=0',
    media.path,
  ]);
  if (r.exitCode != 0) {
    throw FfmpegException(exitCode: r.exitCode, stderr: _diagnostics(r));
  }
  final seconds = double.tryParse((r.stdout as String).trim());
  if (seconds == null) {
    throw FfmpegException(exitCode: r.exitCode, stderr: _diagnostics(r));
  }
  return seconds;
}

/// Silent wav of [seconds] at 24kHz mono — the `--mute` narration
/// placeholder, same format the TTS step requests.
List<String> silentWavArgs({required double seconds, required File out}) => [
  '-y',
  '-f',
  'lavfi',
  '-i',
  'anullsrc=r=24000:cl=mono',
  '-t',
  seconds.toStringAsFixed(3),
  '-c:a',
  'pcm_s16le',
  // Explicit format: the caller writes to a `.tmp` name first (atomic
  // publish), so ffmpeg cannot infer wav from the extension.
  '-f',
  'wav',
  out.path,
];

/// Run `ffmpeg` with [args]; throws [FfmpegException] (non-zero exit)
/// carrying ffmpeg's stderr.
Future<void> runFfmpeg(List<String> args) async {  final r = await Process.run('ffmpeg', args);
  if (r.exitCode != 0) {
    throw FfmpegException(exitCode: r.exitCode, stderr: _diagnostics(r));
  }
}

/// Per-stream duration of [media] in seconds (`stream=duration` for
/// [selector], e.g. `v:0` / `a:0`). Throws [FfmpegException] when ffprobe
/// fails or the stream carries no parseable duration.
Future<double> streamDurationSeconds(File media, String selector) async {
  final r = await Process.run('ffprobe', [
    '-v', 'quiet', '-select_streams', selector,
    '-show_entries', 'stream=duration', '-of', 'csv=p=0', media.path,
  ]);
  final seconds = double.tryParse((r.stdout as String).trim());
  if (r.exitCode != 0 || seconds == null) {
    throw FfmpegException(exitCode: r.exitCode, stderr: _diagnostics(r));
  }
  return seconds;
}

/// Ken Burns: still image [img] → exactly [durationS] seconds of
/// 1280x720 / 24 fps h264 (`zoompan`, gentle zoom-in, center crop).
List<String> kenBurnsArgs({
  required File img,
  required int durationS,
  required File out,
}) => kenBurnsArgsFor(img: img, durationS: durationS, out: out);

/// 参数化 Ken Burns；短剧竖屏显式传 1080×1920。
List<String> kenBurnsArgsFor({
  required File img,
  required int durationS,
  required File out,
  int width = 1280,
  int height = 720,
  int fps = 24,
  double zoomStep = 0.0015,
  double maxZoom = 1.5,
}) {
  final frames = durationS * fps;
  return <String>[
    '-y',
    '-i',
    img.path,
    '-vf',
    'scale=$width:$height:force_original_aspect_ratio=increase,'
        'crop=$width:$height,'
        "zoompan=z='min(zoom+$zoomStep,$maxZoom)':d=$frames:"
        "x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s=${width}x$height:fps=$fps",
    '-t',
    '$durationS',
    '-c:v',
    'libx264',
    '-pix_fmt',
    'yuv420p',
    out.path,
  ];
}

/// 微动：更小的缩放幅度，仍走本地 ffmpeg、零费用。
List<String> microArgsFor({
  required File img,
  required int durationS,
  required File out,
  int width = 1280,
  int height = 720,
  int fps = 24,
}) => kenBurnsArgsFor(
  img: img,
  durationS: durationS,
  out: out,
  width: width,
  height: height,
  fps: fps,
  zoomStep: 0.0006,
  maxZoom: 1.08,
);

/// Normalize [input] to the uniform segment format: scale+pad to 1280x720
/// (aspect preserved, letterboxed), 24 fps h264, plus a silent stereo aac
/// track (`anullsrc`) so every normalized clip carries the same stream
/// layout and stays silent regardless of the source. `-shortest` bounds
/// the output to the video length.
// `in` (brief) is a Dart reserved word — `input` is the same contract.
List<String> normalizeArgs({required File input, required File out}) =>
    normalizeArgsFor(input: input, out: out);

/// 参数化归一化；短剧竖屏显式传 1080×1920。
List<String> normalizeArgsFor({
  required File input,
  required File out,
  int width = 1280,
  int height = 720,
  int fps = 24,
}) {
  return <String>[
    '-y',
    '-i',
    input.path,
    '-f',
    'lavfi',
    '-i',
    'anullsrc=channel_layout=stereo:sample_rate=44100',
    '-map',
    '0:v:0',
    '-map',
    '1:a:0',
    '-vf',
    'scale=$width:$height:force_original_aspect_ratio=decrease,'
        'pad=$width:$height:(ow-iw)/2:(oh-ih)/2,fps=$fps',
    '-c:v',
    'libx264',
    '-pix_fmt',
    'yuv420p',
    '-shortest',
    '-c:a',
    'aac',
    '-b:a',
    '128k',
    out.path,
  ];
}

/// Mux segment video with its TTS audio into exactly [durationS] seconds.
///
/// [audioS] is the measured TTS audio length (state `audio_s`): the audio
/// is capped at the clip length (`atrim`, no longer than [durationS]) and
/// padded with silence at the tail (`apad`) to exactly [durationS], so
/// every muxed segment lines up for concat. Video is stream-copied;
/// explicit `-map` picks the TTS track over any audio carried by the video.
List<String> muxArgs({
  required File video,
  required File audio,
  required double audioS,
  required int durationS,
  required File out,
}) {
  final audioEnd = audioS < durationS ? audioS : durationS;
  return [
    '-y',
    '-i',
    video.path,
    '-i',
    audio.path,
    '-map',
    '0:v:0',
    '-map',
    '1:a:0',
    '-filter:a',
    'atrim=end=$audioEnd,apad=whole_dur=$durationS',
    '-t',
    '$durationS',
    '-c:v',
    'copy',
    '-c:a',
    'aac',
    '-b:a',
    '128k',
    out.path,
  ];
}

/// Concat-demuxer list file referenced by [concatArgs]: `<out>.concat.txt`.
File concatListFileFor(File out) => File('${out.path}.concat.txt');

/// Write the concat-demuxer list that [concatArgs] will read — call
/// immediately before `runFfmpeg(concatArgs(...))`. Paths are written
/// single-quoted (pipeline paths contain no quotes).
Future<void> writeConcatList({
  required List<File> parts,
  required File out,
}) async {
  final sb = StringBuffer();
  for (final part in parts) {
    sb.writeln("file '${part.path}'");
  }
  await concatListFileFor(out).writeAsString(sb.toString());
}

/// Concatenate [parts] into [out] via the concat demuxer with stream copy.
///
/// The inputs are read from the list file [writeConcatList] produces
/// (path derived from [out]); [parts] documents the inputs and is checked
/// for emptiness here so callers fail before spawning a process.
List<String> concatArgs({required List<File> parts, required File out}) {
  if (parts.isEmpty) {
    throw ArgumentError('concatArgs: parts must not be empty');
  }
  return [
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    concatListFileFor(out).path,
    '-c',
    'copy',
    out.path,
  ];
}

/// Overlay the [avatar] image (a rounded card) into the bottom-left of
/// [video] → [out].
///
/// The avatar is rounded via a `geq` alpha mask (corner radius = 10% of the
/// source width, so it scales with the image) and sized to 26% of the video
/// height (`scale2ref`), positioned with a 4% margin. The audio track is
/// stream-copied, so the clip keeps its native narration; `0:a?` tolerates
/// inputs without audio.
List<String> overlayAvatarArgs({
  required File video,
  required File avatar,
  required File out,
}) {
  const filter =
      "[1:v]format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':"
      "a='if(lt(hypot(max(0,abs(X-W/2)-(W/2-W*0.1)),"
      "max(0,abs(Y-H/2)-(H/2-W*0.1))),W*0.1),255,0)'[av];"
      "[av][0:v]scale2ref=w='main_h*0.26':h='main_h*0.26'[av2][base];"
      "[base][av2]overlay=x='main_w*0.04':y='main_h-overlay_h-main_h*0.04'[v]";
  return [
    '-y',
    '-i',
    video.path,
    '-i',
    avatar.path,
    '-filter_complex',
    filter,
    '-map',
    '[v]',
    '-map',
    '0:a?',
    '-c:v',
    'libx264',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'copy',
    '-shortest',
    out.path,
  ];
}
