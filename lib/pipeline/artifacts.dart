import 'dart:io';

/// Artifact-relative paths for one content run (spec §4 工件目录).
///
/// Every step resolves its input/output through these constants so the
/// on-disk layout under `pipeline_out/<content_id>/` has a single source of
/// truth: [state]/[meta] are the run bookkeeping files, `00_`–`06_` are the
/// step artifacts in execution order.
abstract final class ArtifactPaths {
  /// `state.json` — the resumable state machine (spec §6).
  static const String state = 'state.json';

  /// `meta.json` — immutable params snapshot written at run start.
  static const String meta = 'meta.json';

  /// `00_inputs/` — local copies of OSS-URL inputs (ingest output).
  static const String inputsDir = '00_inputs';

  /// `01_classify.json` — per-photo classification (classify output).
  static const String classify = '01_classify.json';

  /// `02_select.json` — photo selection (select output).
  static const String select = '02_select.json';

  /// `03_script.json` — segment script (script output).
  static const String script = '03_script.json';

  /// `04_audio/` — synthesized segment audio (tts output).
  static const String audioDir = '04_audio';

  /// `04_audio/durations.json` — ffprobe-measured segment durations.
  static const String durations = '04_audio/durations.json';

  /// `05_clips/` — rendered segment clips (render output).
  static const String clipsDir = '05_clips';

  /// `05_clips/status.json` — per-segment render/download status.
  static const String renderStatus = '05_clips/status.json';

  /// `06_final.mp4` — composed video (compose output).
  static const String finalVideo = '06_final.mp4';

  /// `06_final.srt` — subtitles, UTF-8/LF, same name and directory as the
  /// mp4 (spec §4).
  static const String finalSrt = '06_final.srt';
}

/// Artifact root for one content run: `pipeline_out/<content_id>/`.
///
/// The constructor creates the directory recursively, so callers may resolve
/// paths immediately after construction. All members are pure path logic —
/// the only IO in this file is the constructor's `createSync` and the
/// existence checks in [exists] / [stepDone].
class Workdir {
  /// Creates `baseDir/contentId` (recursively) as the artifact root.
  Workdir(String baseDir, String contentId) : dir = '$baseDir/$contentId' {
    Directory(dir).createSync(recursive: true);
  }

  /// Absolute path of the artifact root directory.
  final String dir;

  /// Resolves [rel] (a path relative to [dir]) as a file handle.
  File file(String rel) => File('$dir/$rel');

  /// Resolves [rel] (a path relative to [dir]) as a directory handle —
  /// the directory-typed counterpart of [file], e.g.
  /// `work.dirOf(ArtifactPaths.audioDir).createSync(recursive: true)`.
  Directory dirOf(String rel) => Directory('$dir/$rel');

  /// Whether [rel] exists under [dir] — true for a file or a directory,
  /// false when nothing (or a broken symlink) sits at that path.
  bool exists(String rel) =>
      FileSystemEntity.typeSync('$dir/$rel') != FileSystemEntityType.notFound;
}

/// The "artifact present ⇒ step done" contract (spec §4 执行契约): a step
/// may skip only when its artifact [artifactRel] exists **and is non-empty**.
///
/// A missing file (never ran) and an empty file (interrupted write) both
/// return false so the rerun re-executes the step; a directory at that path
/// never counts as done.
bool stepDone(Workdir w, String artifactRel) {
  final f = w.file(artifactRel);
  if (!f.existsSync()) return false;
  return f.lengthSync() > 0;
}
