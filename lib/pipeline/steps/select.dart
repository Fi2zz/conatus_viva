import 'dart:io';

import 'package:crypto/crypto.dart';

import 'classify.dart';
import 'ingest.dart';

/// Picks the photos that make the video (spec §4「02 select」).
///
/// - `userPicked == true` → [all] passes through untouched (手选透传): no
///   dedupe, no ranking, no trimming.
/// - otherwise: dedupe by content (equal sha1 of the file bytes = same
///   photo, first occurrence in [order] wins) → rank by `quality` descending
///   → take the first [count].
/// - when every remaining candidate carries a `capturedAt`, selection keeps
///   the time distribution instead: the timeline is split into [count]
///   consecutive buckets and the best photo of each bucket wins, so first /
///   middle / last of the range are represented (spec §4「02 select」时间
///   分布均匀). Without capture times (local inputs) selection degrades to
///   pure quality ranking (spec §3.1).
/// - fewer candidates than [count] → use what exists (spec §4-02 下限 1).
///
/// [all] holds every classified photo; [order] is the ingest order and the
/// authority for dedupe, tie-breaking and time. [count] is the desired
/// maximum, i.e. `PipelineConfig.targetCount`.
List<PhotoInfo> selectPhotos({
  required List<PhotoInfo> all,
  required List<IngestedPhoto> order,
  required int count,
  bool userPicked = false,
}) {
  if (userPicked) return List<PhotoInfo>.of(all);
  if (count <= 0 || all.isEmpty) return <PhotoInfo>[];

  final infoById = <String, PhotoInfo>{for (final p in all) p.id: p};
  final seen = <String>{};
  final candidates = <_Candidate>[];
  for (final photo in order) {
    final info = infoById[photo.id];
    if (info == null) continue; // not classified — cannot be selected
    if (!seen.add(_contentHash(photo))) continue; // same bytes → duplicate
    candidates.add(
      _Candidate(info: info, photo: photo, seq: candidates.length),
    );
  }
  if (candidates.isEmpty) return <PhotoInfo>[];

  final hasTimeline = candidates.every((c) => c.photo.capturedAt != null);
  if (!hasTimeline) {
    // List.sort is not stable, so ties fall back to the dedupe-order index.
    final ranked = <_Candidate>[...candidates]
      ..sort((a, b) {
        final byQuality = b.info.quality.compareTo(a.info.quality);
        return byQuality != 0 ? byQuality : a.seq.compareTo(b.seq);
      });
    return <PhotoInfo>[for (final c in ranked.take(count)) c.info];
  }

  final byTime = <_Candidate>[...candidates]
    ..sort((a, b) {
      final byCapture = a.photo.capturedAt!.compareTo(b.photo.capturedAt!);
      return byCapture != 0 ? byCapture : a.seq.compareTo(b.seq);
    });
  final picked = count >= byTime.length ? byTime : _spread(byTime, count);
  return <PhotoInfo>[for (final c in picked) c.info];
}

/// sha1 of the file bytes — identical content hashes equal and is treated as
/// one photo (the first occurrence in `order` wins). A file that cannot be
/// read cannot be hashed, so it falls back to a per-id key that never
/// collides: selection never drops a photo it could not inspect.
String _contentHash(IngestedPhoto photo) {
  try {
    return sha1.convert(photo.file.readAsBytesSync()).toString();
  } on FileSystemException {
    return 'id:${photo.id}';
  }
}

/// Splits the capture-time-sorted [byTime] into [count] consecutive buckets
/// and takes the highest-quality photo of each (earliest wins ties), so the
/// picks span first / middle / last of the timeline instead of clustering
/// where the quality scores happen to peak. Input must be longer than
/// [count] — the caller checks that first.
List<_Candidate> _spread(List<_Candidate> byTime, int count) {
  final picked = <_Candidate>[];
  final total = byTime.length;
  for (var i = 0; i < count; i++) {
    final start = i * total ~/ count;
    final end = (i + 1) * total ~/ count;
    var best = byTime[start];
    for (var j = start + 1; j < end; j++) {
      if (byTime[j].info.quality > best.info.quality) best = byTime[j];
    }
    picked.add(best);
  }
  return picked;
}

class _Candidate {
  const _Candidate({
    required this.info,
    required this.photo,
    required this.seq,
  });

  final PhotoInfo info;
  final IngestedPhoto photo;

  /// Index in dedupe order — stable tie-breaker, because [List.sort] is
  /// not guaranteed to be stable.
  final int seq;
}
