import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../errors.dart';

/// Observed state of a 万相 async video task (spec §4「05 render」): the
/// provider's PENDING/RUNNING collapse to [running]; SUCCEEDED and
/// FAILED/CANCELED are the terminal states.
enum I2vStatus { running, succeeded, failed }

/// One observed state of an async i2v task, from submit or poll.
class I2vTask {
  const I2vTask({
    required this.taskId,
    required this.status,
    this.videoUrl,
    this.errorCode,
  });

  final String taskId;
  final I2vStatus status;

  /// `output.video_url` — present on success, valid for 24h (spec §3).
  final Uri? videoUrl;

  /// Provider `output.code` on failure, preserved verbatim so the render
  /// step can spot audit rejections (`IPInfringementSuspect` /
  /// `DataInspectionFailed` → `audit_reject`, spec §6).
  final String? errorCode;
}

/// DashScope async-task client for the 万相 i2v generation endpoint
/// (spec §4「05 render」).
///
/// Submit is a POST with `X-DashScope-Async: enable`; the reply carries
/// `output.task_id` + `output.task_status`. Progress is polled via
/// `GET /api/v1/tasks/{task_id}`; the video URL only appears on SUCCEEDED
/// and must be downloaded immediately (24h lifetime, spec §3).
///
/// Error mapping (spec §6 错误分类与重试, mirrors QwenClient/TtsClient):
/// - 408 / 429 / 5xx / network failure / malformed 200 → [ErrorClass.transient]
/// - 401 / 400 and any other non-2xx status → [ErrorClass.fatal]
class I2vClient {
  I2vClient({
    required this._apiKey,
    http.Client? client,
    this._model = 'wan2.6-i2v-flash',
    this._resolution = '720P',
    this._watermark = true,
    this._seed = 42,
  }) : _client = client ?? http.Client();

  /// Async video-generation endpoint (brief-pinned URL).
  static final Uri submitUri = Uri.parse(
    'https://dashscope.aliyuncs.com/api/v1/services/aigc/'
    'video-generation/video-synthesis',
  );

  /// Async task polling endpoint (brief-pinned URL shape).
  static Uri taskUri(String taskId) =>
      Uri.parse('https://dashscope.aliyuncs.com/api/v1/tasks/$taskId');

  final String _apiKey;
  final http.Client _client;
  final String _model;
  final String _resolution;
  final bool _watermark;
  final int _seed;

  Map<String, String> get _headers => <String, String>{
    'Authorization': 'Bearer $_apiKey',
    'content-type': 'application/json',
  };

  /// Creates one async i2v task. The body pins every parameter explicitly
  /// (resolution/duration/audio/prompt_extend/shot_type/watermark/seed) so a
  /// service-side default change can never silently alter spec or cost
  /// (Review Focus #3).
  Future<I2vTask> submit({
    required String imgUrl,
    required String prompt,
    required int durationS,
  }) async {
    final response = await _send(
      () => _client.post(
        submitUri,
        headers: <String, String>{..._headers, 'X-DashScope-Async': 'enable'},
        body: jsonEncode(<String, dynamic>{
          'model': _model,
          'input': <String, dynamic>{'img_url': imgUrl, 'prompt': prompt},
          'parameters': <String, dynamic>{
            'resolution': _resolution,
            'duration': durationS,
            'audio': false,
            'prompt_extend': true,
            'shot_type': 'multi',
            'watermark': _watermark,
            'seed': _seed,
          },
        }),
      ),
    );
    if (response.statusCode != 200) throw _statusError('i2v submit', response);
    return _parseTask(_bodyOf(response), null);
  }

  /// One poll of [taskId]; the caller owns the interval and the deadline.
  Future<I2vTask> poll(String taskId) async {
    final response = await _send(() => _client.get(taskUri(taskId), headers: _headers));
    if (response.statusCode != 200) throw _statusError('i2v poll', response);
    return _parseTask(_bodyOf(response), taskId);
  }

  /// Downloads a succeeded task's video bytes (24h URL lifetime, spec §3 —
  /// the render step stores them locally before anything else continues).
  Future<List<int>> downloadClip(Uri url) async {
    final response = await _send(() => _client.get(url));
    if (response.statusCode != 200) throw _statusError('i2v download', response);
    return response.bodyBytes;
  }

  /// One request with the shared network-failure mapping; HTTP status is
  /// classified by the callers.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } on http.ClientException catch (e) {
      throw PipelineError(ErrorClass.transient, 'i2v network error: $e');
    } on IOException catch (e) {
      throw PipelineError(ErrorClass.transient, 'i2v network error: $e');
    } on TimeoutException catch (e) {
      throw PipelineError(ErrorClass.transient, 'i2v timeout: $e');
    }
  }

  /// Parses the async-task envelope. A malformed 200 is transient — a
  /// truncated gateway reply may self-heal on the next poll (mirrors
  /// QwenClient._extractContent).
  static I2vTask _parseTask(String body, String? fallbackTaskId) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('response root is not an object');
      }
      final output = decoded['output'];
      if (output is! Map<String, dynamic>) {
        throw const FormatException('response has no output object');
      }
      final rawStatus = output['task_status'];
      if (rawStatus is! String) {
        throw const FormatException('output.task_status is not a string');
      }
      final rawId = output['task_id'];
      final taskId = rawId is String ? rawId : fallbackTaskId;
      if (taskId == null) {
        throw const FormatException('response has no task_id');
      }
      final rawUrl = output['video_url'];
      final rawCode = output['code'];
      return I2vTask(
        taskId: taskId,
        status: _statusOf(rawStatus),
        videoUrl: rawUrl is String ? Uri.parse(rawUrl) : null,
        errorCode: rawCode is String ? rawCode : null,
      );
    } catch (e) {
      throw PipelineError(ErrorClass.transient, 'malformed i2v response: $e');
    }
  }

  static I2vStatus _statusOf(String raw) {
    if (raw == 'PENDING' || raw == 'RUNNING') return I2vStatus.running;
    if (raw == 'SUCCEEDED') return I2vStatus.succeeded;
    if (raw == 'FAILED' || raw == 'CANCELED') return I2vStatus.failed;
    throw FormatException('unknown task_status: $raw');
  }

  /// Status-first classification (spec §6): 408/429/5xx are transient,
  /// every other non-2xx (401 bad key, 400 bad params) fails fast as fatal.
  static PipelineError _statusError(String what, http.Response response) {
    final status = response.statusCode;
    final detail = _errorDetail(response.bodyBytes);
    if (status == 408 || status == 429 || status >= 500) {
      return PipelineError(ErrorClass.transient, '$what HTTP $status: $detail');
    }
    return PipelineError(ErrorClass.fatal, '$what HTTP $status: $detail');
  }

  static String _bodyOf(http.Response response) =>
      utf8.decode(response.bodyBytes, allowMalformed: true);

  /// The provider's error message when the body carries one, else the
  /// (truncated) raw body — this text lands in `state.json`.
  static String _errorDetail(List<int> bodyBytes) {
    final raw = utf8.decode(bodyBytes, allowMalformed: true).trim();
    if (raw.isEmpty) return '<empty body>';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic> && decoded['message'] is String) {
        return decoded['message'] as String;
      }
    } on FormatException {
      // Non-JSON error body (e.g. an HTML gateway page) — fall through.
    }
    return raw.length > 300 ? '${raw.substring(0, 300)}…' : raw;
  }
}
