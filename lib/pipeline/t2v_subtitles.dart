import 'srt.dart';

/// Builds SRT entries for a text-to-video clip from caller-supplied text.
///
/// The 万相 3.0 text-to-video model returns no transcript and no timeline, so
/// timing cannot be derived from the response: each non-empty line becomes one
/// cue and the cues are split evenly across [duration] (the caller resolves
/// the real clip length, probing the file when the request used smart `-1`).
List<SrtEntry> buildSubtitleEntries({
  required String text,
  required Duration duration,
}) {
  final lines = <String>[
    for (final raw in text.split('\n'))
      if (raw.trim().isNotEmpty) raw.trim(),
  ];
  if (lines.isEmpty || duration <= Duration.zero) return const <SrtEntry>[];
  final totalMicros = duration.inMicroseconds;
  return <SrtEntry>[
    for (var i = 0; i < lines.length; i++)
      SrtEntry(
        index: i + 1,
        start: Duration(
          microseconds: totalMicros * i ~/ lines.length,
        ),
        end: Duration(
          microseconds: i == lines.length - 1
              ? totalMicros
              : totalMicros * (i + 1) ~/ lines.length,
        ),
        text: lines[i],
      ),
  ];
}
