// SRT subtitle construction for the 06 compose step (spec §4-06): pure
// functions, independently testable, no IO.
//
// Timing contract: an entry starts at the segment's accumulated video
// offset and ends at `min(start + audioS, start + videoDurationS)`; lines
// over 40 chars split into two entries with time divided proportionally to
// character counts. [renderSrt] emits `HH:MM:SS,mmm` with LF separators,
// a single trailing newline, and no BOM.

/// One segment's subtitle inputs: the narration [line] (control tags are
/// stripped here), its accumulated video offset [startVideoS], the segment
/// clip length [videoDurationS], and the TTS audio length [audioS].
class SegmentInput {
  const SegmentInput({
    required this.line,
    required this.startVideoS,
    required this.videoDurationS,
    required this.audioS,
  });

  final String line;
  final double startVideoS;
  final double videoDurationS;
  final double audioS;
}

/// One rendered SRT block: 1-based [index], [start]/[end] cue times, and
/// the subtitle [text] (narration only, never control tags).
class SrtEntry {
  const SrtEntry({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
  });

  final int index;
  final Duration start;
  final Duration end;
  final String text;
}

/// Max chars per SRT entry; longer lines split in two (spec §4-06).
const int _maxEntryChars = 40;

/// Removes `[...]` control tags (e.g. `[very slowly]`) so subtitles carry
/// narration only (Review Focus #4).
String stripControlTags(String line) =>
    line.replaceAll(RegExp(r'\[[^\]]*\]'), '').trim();

/// Builds the entry list for [segs], validating that every entry's end is
/// no later than the next entry's start (throws [ArgumentError] on overlap).
List<SrtEntry> buildSrt({required List<SegmentInput> segs}) {
  final entries = <SrtEntry>[];
  for (final seg in segs) {
    entries.addAll(_entriesFor(seg, entries.length + 1));
  }
  _validateMonotonic(entries);
  return entries;
}

List<SrtEntry> _entriesFor(SegmentInput seg, int nextIndex) {
  final start = _toDuration(seg.startVideoS);
  final capped =
      seg.audioS < seg.videoDurationS ? seg.audioS : seg.videoDurationS;
  final end = _toDuration(seg.startVideoS + capped);
  final text = stripControlTags(seg.line);
  if (text.length <= _maxEntryChars) {
    return [SrtEntry(index: nextIndex, start: start, end: end, text: text)];
  }
  return _splitEntry(nextIndex, start, end, text);
}

/// Splits a >40-char line at the half-char mark; the cue interval divides
/// proportionally to the two halves' character counts.
List<SrtEntry> _splitEntry(int index, Duration start, Duration end, String text) {
  final cut = (text.length + 1) ~/ 2;
  final spanMicros = end.inMicroseconds - start.inMicroseconds;
  final mid = Duration(
    microseconds: start.inMicroseconds + spanMicros * cut ~/ text.length,
  );
  return [
    SrtEntry(index: index, start: start, end: mid, text: text.substring(0, cut)),
    SrtEntry(index: index + 1, start: mid, end: end, text: text.substring(cut)),
  ];
}

Duration _toDuration(double seconds) =>
    Duration(microseconds: (seconds * 1000000).round());

void _validateMonotonic(List<SrtEntry> entries) {
  for (var i = 0; i + 1 < entries.length; i++) {
    if (entries[i].end > entries[i + 1].start) {
      throw ArgumentError('srt entry ${entries[i].index} overlaps the next');
    }
  }
}

/// Renders [entries] as SRT: `HH:MM:SS,mmm` cues, `\n` line separators,
/// blocks separated by one blank line, exactly one trailing newline, no BOM.
String renderSrt(List<SrtEntry> entries) {
  final blocks = <String>[
    for (final e in entries)
      '${e.index}\n${_formatCue(e.start)} --> ${_formatCue(e.end)}\n${e.text}',
  ];
  if (blocks.isEmpty) return '';
  return '${blocks.join('\n\n')}\n';
}

String _formatCue(Duration d) {
  final h = d.inHours.toString().padLeft(2, '0');
  final m = (d.inMinutes % 60).toString().padLeft(2, '0');
  final s = (d.inSeconds % 60).toString().padLeft(2, '0');
  final ms = (d.inMilliseconds % 1000).toString().padLeft(3, '0');
  return '$h:$m:$s,$ms';
}
