import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../artifacts.dart';
import '../errors.dart';

/// One photo normalized by the 00 ingest step (spec §3.1/§4「00 ingest」):
/// every later step reads [file] from the local disk and never depends on a
/// remote URL staying alive.
class IngestedPhoto {
  const IngestedPhoto({
    required this.id,
    required this.file,
    required this.capturedAt,
    required this.source,
  });

  /// `local` — input was a filesystem path (pass-through, never copied).
  static const String sourceLocal = 'local';

  /// `url` — input was an `http(s)://` URL, downloaded into `00_inputs/`.
  static const String sourceUrl = 'url';

  /// Stable short name for downstream references (segment numbering):
  /// `<三位序号>_<文件名去扩展名>`, e.g. `001_p1`. The sequence number is the
  /// 1-based position in the input list, so ids stay stable across reruns.
  final String id;

  /// The local file backing this photo — the original path for
  /// [sourceLocal], the `00_inputs/` copy for [sourceUrl].
  final File file;

  /// Capture time from the URL object's `Last-Modified` header (RFC 7231 /
  /// `HttpDate`). `null` when the header is absent or unparsable, and for
  /// local inputs; downstream selection then falls back to quality-score
  /// ordering (spec §3.1).
  final DateTime? capturedAt;

  /// Either [sourceLocal] or [sourceUrl].
  final String source;
}

/// Normalizes all [photos] (local paths or `http(s)://` URLs) into local
/// copies under `00_inputs/` (spec §4 执行契约 — URL 仅需在下载那一刻有效).
///
/// - URL input → downloaded to `00_inputs/<序号>_<文件名>`; an existing target
///   file is reused as-is and **no HTTP request is issued** (idempotent rerun).
/// - Local input → the `File` reference passes through unchanged; nothing is
///   copied and `00_inputs/` may stay absent.
/// - Empty [photos] → [PipelineError] with [ErrorClass.fatal]; a failed
///   download (network error, timeout, non-2xx) → [ErrorClass.transient];
///   an unwritable `00_inputs/` → [ErrorClass.fatal] (a disk fault will not
///   self-heal, mirroring the QwenClient local-file mapping).
///
/// [client] is injected in tests (`package:http/testing.dart`); when omitted
/// an internal client is created for the duration of the call and closed
/// before returning.
Future<List<IngestedPhoto>> runIngest({
  required List<String> photos,
  required Workdir work,
  http.Client? client,
}) async {
  if (photos.isEmpty) {
    throw PipelineError(
      ErrorClass.fatal,
      'ingest received an empty photo list',
    );
  }
  final http.Client httpClient = client ?? http.Client();
  try {
    final ingested = <IngestedPhoto>[];
    for (var i = 0; i < photos.length; i++) {
      ingested.add(await _ingestOne(photos[i], i, work, httpClient));
    }
    return ingested;
  } finally {
    if (client == null) httpClient.close();
  }
}

/// Whether [input] is an `http(s)://` URL (spec §3.1: 其余一律按本地路径).
bool _isUrl(String input) =>
    input.startsWith('http://') || input.startsWith('https://');

Future<IngestedPhoto> _ingestOne(
  String input,
  int index,
  Workdir work,
  http.Client client,
) async {
  final seq = '${index + 1}'.padLeft(3, '0');

  if (!_isUrl(input)) {
    final file = File(input);
    return IngestedPhoto(
      id: '${seq}_${_stem(_baseName(input))}',
      file: file,
      capturedAt: null,
      source: IngestedPhoto.sourceLocal,
    );
  }

  final uri = Uri.parse(input);
  final fileName = _urlFileName(uri);
  final id = '${seq}_${_stem(fileName)}';
  final rel = '${ArtifactPaths.inputsDir}/${seq}_$fileName';
  final target = work.file(rel);

  // Rerun contract: an already-downloaded copy is complete (the write below
  // publishes atomically), so skip the request entirely.
  if (work.exists(rel)) {
    return IngestedPhoto(
      id: id,
      file: target,
      capturedAt: null,
      source: IngestedPhoto.sourceUrl,
    );
  }

  final http.Response response = await _fetch(client, uri);

  work.dirOf(ArtifactPaths.inputsDir).createSync(recursive: true);
  try {
    // Write to a temp name then rename, so an interrupted write never
    // leaves a partial file that a rerun would treat as a valid copy.
    final tmp = File('${target.path}.tmp');
    tmp.writeAsBytesSync(response.bodyBytes, flush: true);
    tmp.renameSync(target.path);
  } on FileSystemException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'ingest cannot write $rel: $e');
  }

  return IngestedPhoto(
    id: id,
    file: target,
    capturedAt: _lastModified(response),
    source: IngestedPhoto.sourceUrl,
  );
}

/// One GET cycle with no retry (the orchestrator retries per
/// [ErrorClass.transient], spec §6). Network faults and any non-2xx status
/// are transient — the URL may well answer on the next attempt.
Future<http.Response> _fetch(http.Client client, Uri uri) async {
  try {
    final response = await client.get(uri);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PipelineError(
        ErrorClass.transient,
        'ingest download failed: HTTP ${response.statusCode} for $uri',
      );
    }
    return response;
  } on PipelineError {
    rethrow;
  } on http.ClientException catch (e) {
    throw PipelineError(ErrorClass.transient, 'ingest download failed: $e');
  } on IOException catch (e) {
    throw PipelineError(ErrorClass.transient, 'ingest download failed: $e');
  } on TimeoutException catch (e) {
    throw PipelineError(ErrorClass.transient, 'ingest download timed out: $e');
  }
}

/// The object's capture time from the `Last-Modified` header. Headers are
/// matched case-insensitively (mocked responses may preserve original case);
/// an absent or unparsable value degrades to `null` rather than failing the
/// download (spec §3.1: 取不到则退化).
DateTime? _lastModified(http.Response response) {
  String? raw;
  for (final entry in response.headers.entries) {
    if (entry.key.toLowerCase() == 'last-modified') {
      raw = entry.value;
      break;
    }
  }
  if (raw == null) return null;
  try {
    return HttpDate.parse(raw);
  } on FormatException {
    return null;
  }
}

/// Last non-empty path segment of [uri]'s path (query/fragment excluded);
/// falls back to `photo` when the URL carries no file name.
String _urlFileName(Uri uri) {
  final segments = uri.path.split('/');
  for (var i = segments.length - 1; i >= 0; i--) {
    if (segments[i].isNotEmpty) return segments[i];
  }
  return 'photo';
}

/// Everything after the last path separator.
String _baseName(String path) {
  final cut = path.lastIndexOf('/');
  return cut < 0 ? path : path.substring(cut + 1);
}

/// [name] without its final extension (`p1.jpg` → `p1`, `a.b.png` → `a.b`).
String _stem(String name) {
  final cut = name.lastIndexOf('.');
  return cut <= 0 ? name : name.substring(0, cut);
}
