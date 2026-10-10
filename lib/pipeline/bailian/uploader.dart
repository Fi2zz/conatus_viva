import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../errors.dart';

/// A published, publicly reachable image URL plus the moment until which the
/// pipeline assumes it stays usable (spec §5 生命周期约束: the URL must
/// cover one i2v task + its retry window).
class ImageUrl {
  const ImageUrl({required this.url, required this.expiresAt});

  final String url;
  final DateTime expiresAt;
}

/// Conservative lifetime reported for every published URL.
///
/// Neither the DashScope upload URL nor the experiment bucket object URL
/// documents an exact expiry offline, so both providers report this window,
/// which comfortably covers one i2v task (1–5 min + retries within
/// `i2v_max_wait_minutes`). Task 16's smoke run verifies the real lifetime.
const Duration kPublishedUrlLifetime = Duration(hours: 1);

/// Publishes a local photo as a public URL for the i2v `input.img_url`
/// (spec §5 可插拔).
abstract class ImageUrlProvider {
  Future<ImageUrl> publish(File photo);

  /// Stable provider id: `'dashscope'` | `'oss'`.
  String get name;
}

/// Preferred provider: upload through the DashScope file API (zero OSS
/// dependency). Falls back to [OssSignedUrlProvider] via [pickProvider] when
/// the returned URL is rejected by 万相 or needs a longer lifetime
/// (Review Focus #1).
class DashScopeUploadProvider implements ImageUrlProvider {
  DashScopeUploadProvider({required this._apiKey, http.Client? client})
    : _client = client ?? http.Client();

  /// Documented file upload endpoint (`POST`, multipart field `file`).
  static final Uri uploadUri = Uri.parse(
    'https://dashscope.aliyuncs.com/api/v1/uploads',
  );

  final String _apiKey;
  final http.Client _client;

  @override
  String get name => 'dashscope';

  /// Uploads [photo] and returns the accessible URL from the response
  /// envelope. Error mapping (spec §6 错误分类与重试):
  /// - 408 / 429 / 5xx / network failure → [ErrorClass.transient]
  /// - 401 / 400 / other non-2xx (bad key, bad request) → [ErrorClass.fatal]
  /// - malformed 200 envelope → [ErrorClass.transient] (worth one retry)
  /// - unreadable [photo] → [ErrorClass.fatal] (will not self-heal)
  ///
  /// The provider does not retry; the render step owns the spec's retry ×2
  /// loop and re-calls [publish] on transient errors.
  @override
  Future<ImageUrl> publish(File photo) async {
    final bytes = _readPhoto(photo);

    final request = http.MultipartRequest('POST', uploadUri)
      ..headers['Authorization'] = 'Bearer $_apiKey'
      ..files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: _baseName(photo.path),
        ),
      );

    final response = await _send(request);
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      throw _httpError('DashScope upload', status, _detailOf(_bodyOf(response)));
    }
    return ImageUrl(
      url: _extractUrl(_bodyOf(response)),
      expiresAt: DateTime.now().add(kPublishedUrlLifetime),
    );
  }

  /// Parses the accessible URL out of a 200 reply. The documented envelope
  /// is `{"request_id":…, "data":{"url":…, "hash":…}}`, so `data.url` is the
  /// primary location; a bare root-level `url` is accepted as a fallback for
  /// older doc examples. Anything else (HTML gateway page, missing url) is
  /// transient — a truncated reply is worth one more attempt.
  static String _extractUrl(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('response root is not an object');
      }
      final data = decoded['data'];
      final Object? url = data is Map<String, dynamic> && data['url'] is String
          ? data['url']
          : decoded['url'];
      if (url is! String || url.isEmpty) {
        throw const FormatException('response has no url');
      }
      return url;
    } catch (e) {
      throw PipelineError(
        ErrorClass.transient,
        'malformed DashScope upload response: $e',
      );
    }
  }

  Future<http.Response> _send(http.BaseRequest request) async {
    try {
      return await http.Response.fromStream(await _client.send(request));
    } on http.ClientException catch (e) {
      throw PipelineError(ErrorClass.transient, 'upload network error: $e');
    } on IOException catch (e) {
      throw PipelineError(ErrorClass.transient, 'upload network error: $e');
    } on TimeoutException catch (e) {
      throw PipelineError(ErrorClass.transient, 'upload timeout: $e');
    }
  }
}

/// Fallback publisher (spec §5 实现 2): signs a PUT into the experiment
/// bucket with the OSS V1 header signature via `package:http` + HMAC-SHA1 —
/// no OSS SDK. Credentials come only from `OSS_ACCESS_KEY_ID` /
/// `OSS_ACCESS_KEY_SECRET` through [PipelineConfig] getters (picked up in
/// [pickProvider]); never hardcode them.
///
/// Offline tests pin the request shape and a golden signature computed with
/// openssl; validating the signature against the real service is Task 16's
/// job.
class OssSignedUrlProvider implements ImageUrlProvider {
  OssSignedUrlProvider({
    required this.accessKeyId,
    required this.accessKeySecret,
    required this.bucket,
    required this.endpoint,
    required String prefix,
    http.Client? client,
    DateTime Function()? now,
  }) : _prefix = _normalizePrefix(prefix),
       _client = client ?? http.Client(),
       _now = now ?? DateTime.now;

  final String accessKeyId;
  final String accessKeySecret;
  final String bucket;
  final String endpoint;
  final String _prefix;
  final http.Client _client;
  final DateTime Function() _now;

  /// Photos land as `image/jpeg` in the artifact dir (ingest normalizes
  /// them), and the value is part of the string-to-sign.
  static const String contentType = 'image/jpeg';

  @override
  String get name => 'oss';

  /// `pipeline-exp` → `pipeline-exp/`, `''` → `''`; already-slashed or
  /// empty prefixes pass through.
  static String _normalizePrefix(String prefix) {
    if (prefix.isEmpty || prefix.endsWith('/')) return prefix;
    return '$prefix/';
  }

  /// Uploads [photo] with a signed PUT and returns the object URL
  /// (spec §6 错误分类与重试: 408/429/5xx/network → transient, everything
  /// else — 401/400/403 — → fatal; unreadable [photo] → fatal).
  @override
  Future<ImageUrl> publish(File photo) async {
    final bytes = _readPhoto(photo);

    final key = '$_prefix${_baseName(photo.path)}';
    final uri = Uri.parse('https://$bucket.$endpoint/$key');
    final date = _httpDate(_now().toUtc());

    // OSS V1 string-to-sign: VERB\nContent-MD5\nContent-Type\nDate\n
    // CanonicalizedResource (no x-oss-* headers are sent).
    final stringToSign = 'PUT\n\n$contentType\n$date\n/$bucket/$key';
    final mac = Hmac(
      sha1,
      utf8.encode(accessKeySecret),
    ).convert(utf8.encode(stringToSign));
    final authorization = 'OSS $accessKeyId:${base64Encode(mac.bytes)}';

    final http.Response response;
    try {
      response = await _client.put(
        uri,
        headers: <String, String>{
          'Authorization': authorization,
          'content-type': contentType,
          'Date': date,
        },
        body: bytes,
      );
    } on http.ClientException catch (e) {
      throw PipelineError(ErrorClass.transient, 'OSS PUT network error: $e');
    } on IOException catch (e) {
      throw PipelineError(ErrorClass.transient, 'OSS PUT network error: $e');
    } on TimeoutException catch (e) {
      throw PipelineError(ErrorClass.transient, 'OSS PUT timeout: $e');
    }

    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      throw _httpError('OSS PUT', status, _detailOf(_bodyOf(response)));
    }
    return ImageUrl(
      url: uri.toString(),
      expiresAt: _now().add(kPublishedUrlLifetime),
    );
  }
}

/// The Review Focus #1 switch: `'dashscope'` (default path) uploads through
/// the DashScope file API, `'oss'` falls back to a signed PUT into the
/// experiment bucket (matching the CLI's `--prefer-provider dashscope|oss`).
/// An unknown value throws [ArgumentError] so a typo cannot silently pick
/// the wrong path; missing credentials throw [ConfigException] (fail fast,
/// same taxonomy as [PipelineConfig.requireApiKey]).
ImageUrlProvider pickProvider({
  required String prefer,
  required PipelineConfig cfg,
  required http.Client client,
}) {
  switch (prefer) {
    case 'oss':
      final accessKeyId = cfg.ossAccessKeyId;
      final accessKeySecret = cfg.ossAccessKeySecret;
      if (accessKeyId == null ||
          accessKeyId.isEmpty ||
          accessKeySecret == null ||
          accessKeySecret.isEmpty) {
        throw ConfigException(
          'OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET not set',
        );
      }
      if (cfg.ossBucket.isEmpty || cfg.ossEndpoint.isEmpty) {
        throw ConfigException('oss bucket / endpoint not configured');
      }
      return OssSignedUrlProvider(
        accessKeyId: accessKeyId,
        accessKeySecret: accessKeySecret,
        bucket: cfg.ossBucket,
        endpoint: cfg.ossEndpoint,
        prefix: cfg.ossPrefix,
        client: client,
      );
    case 'dashscope':
      return DashScopeUploadProvider(
        apiKey: cfg.requireApiKey(),
        client: client,
      );
    default:
      throw ArgumentError.value(
        prefer,
        'prefer',
        "must be 'dashscope' or 'oss'",
      );
  }
}

/// Maps an HTTP failure per spec §6: 408 / 429 / 5xx are [ErrorClass.transient]
/// (retry ×2 with backoff), everything else — 401/400/403 included — is
/// [ErrorClass.fatal] and fails fast (mirrors the QwenClient mapping).
PipelineError _httpError(String what, int status, String detail) {
  if (status == 408 || status == 429 || status >= 500) {
    return PipelineError(ErrorClass.transient, '$what HTTP $status: $detail');
  }
  return PipelineError(ErrorClass.fatal, '$what HTTP $status: $detail');
}

/// [response.body] with a decode failure classified as transient — the bytes
/// are server-side and may self-heal (mirrors `QwenClient._bodyOf`).
String _bodyOf(http.Response response) {
  try {
    return response.body;
  } catch (e) {
    throw PipelineError(
      ErrorClass.transient,
      'upload response body decode failed: $e',
    );
  }
}

/// The provider's error message when the body carries one, else the
/// (truncated) raw body — this text can land in `state.json`.
String _detailOf(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final error = decoded['error'];
      if (error is Map<String, dynamic> && error['message'] is String) {
        return error['message'] as String;
      }
      if (decoded['message'] is String) return decoded['message'] as String;
    }
  } on FormatException {
    // Non-JSON error body (e.g. an HTML gateway page) — fall through.
  }
  return body.length > 300 ? '${body.substring(0, 300)}…' : body;
}

/// Reads [photo] bytes; a missing/unreadable file is fatal because it will
/// not self-heal on retry (spec §6).
List<int> _readPhoto(File photo) {
  try {
    return photo.readAsBytesSync();
  } on FileSystemException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'cannot read photo: $e');
  }
}

/// Final path segment; artifact photos are named by ingest
/// (`<seq>_<name>.jpg`), which keeps them URL-safe.
String _baseName(String path) => path.split(Platform.pathSeparator).last;

/// RFC 1123 date (`Tue, 07 Jun 2022 05:15:16 GMT`) — the `Date` line of the
/// OSS V1 string-to-sign.
String _httpDate(DateTime utc) {
  const days = <String>['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  String p(int v) => v.toString().padLeft(2, '0');
  return '${days[utc.weekday - 1]}, ${p(utc.day)} ${months[utc.month - 1]} '
      '${utc.year} ${p(utc.hour)}:${p(utc.minute)}:${p(utc.second)} GMT';
}
