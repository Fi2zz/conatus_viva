import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../errors.dart';

/// Observed state of a 万相 async video task (spec §4「05 render」): the
/// provider's PENDING/RUNNING collapse to [running]; SUCCEEDED and
/// FAILED/CANCELED are the terminal states.
enum I2vStatus { running, succeeded, failed }

/// One observed state of an async video task, from submit or poll.
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

/// Common contract for the DashScope async video-generation clients — one
/// implementation per model family (wan2.6 i2v, wan3.0 all-in-one, ...) — so
/// the render step stays agnostic about which model is wired in.
abstract interface class VideoGenClient {
  /// Creates one async task. [imgUrl] is the segment's photo.
  Future<I2vTask> submit({
    required String imgUrl,
    required String prompt,
    required int durationS,
  });

  /// One poll of [taskId]; the caller owns the interval and the deadline.
  Future<I2vTask> poll(String taskId);

  /// Downloads a succeeded task's video bytes (24h URL lifetime, spec §3).
  Future<List<int>> downloadClip(Uri url);
}

/// Shared DashScope async video mechanics: the submit/poll/download endpoints,
/// task-envelope parsing and error classification. Subclasses supply their
/// connection details and describe only their model family's request body via
/// [buildSubmitBody].
///
/// Submit is a POST with `X-DashScope-Async: enable`; the reply carries
/// `output.task_id` + `output.task_status`. Progress is polled via
/// `GET /api/v1/tasks/{task_id}`; the video URL only appears on SUCCEEDED and
/// must be downloaded immediately (24h lifetime, spec §3).
///
/// Error mapping (spec §6 错误分类与重试, mirrors QwenClient/TtsClient):
/// - 408 / 429 / 5xx / network failure / malformed 200 → [ErrorClass.transient]
/// - 401 / 400 and any other non-2xx status → [ErrorClass.fatal]
abstract class DashScopeVideoClient implements VideoGenClient {
  /// Default workspace-less DashScope host.
  static const String defaultHost = 'https://dashscope.aliyuncs.com';

  /// Bearer key for every request.
  String get apiKey;

  /// API host, e.g. `https://dashscope.aliyuncs.com`.
  String get host;

  /// Shared HTTP client (injected in tests).
  http.Client get httpClient;

  /// Error-message prefix (`i2v`, `wan3.0`), so a failure names the client
  /// family that produced it.
  String get label;

  /// Async video-generation endpoint (submit).
  Uri get submitUri =>
      Uri.parse('$host/api/v1/services/aigc/video-generation/video-synthesis');

  /// Async task polling endpoint.
  Uri taskUri(String taskId) => Uri.parse('$host/api/v1/tasks/$taskId');

  Map<String, String> get _headers => <String, String>{
    'Authorization': 'Bearer $apiKey',
    'content-type': 'application/json',
  };

  /// The model family's `{model, input, parameters}` body. Every parameter is
  /// pinned explicitly so a service-side default change can never silently
  /// alter spec or cost (Review Focus #3).
  Map<String, dynamic> buildSubmitBody({
    required String imgUrl,
    required String prompt,
    required int durationS,
  });

  @override
  Future<I2vTask> submit({
    required String imgUrl,
    required String prompt,
    required int durationS,
  }) {
    return postTask(
      buildSubmitBody(imgUrl: imgUrl, prompt: prompt, durationS: durationS),
      what: 'submit',
    );
  }

  /// POSTs [body] to the submit endpoint and parses the async-task envelope.
  /// Shared by [submit] and model-specific entry points (e.g. the wan3.0
  /// text-to-video path, whose body carries `prompt` and no `media`).
  Future<I2vTask> postTask(
    Map<String, dynamic> body, {
    required String what,
  }) async {
    final response = await _send(
      () => httpClient.post(
        submitUri,
        headers: <String, String>{..._headers, 'X-DashScope-Async': 'enable'},
        body: jsonEncode(body),
      ),
    );
    if (response.statusCode != 200) {
      throw _statusError('$label $what', response);
    }
    return parseVideoTask(_bodyOf(response), null);
  }

  @override
  Future<I2vTask> poll(String taskId) async {
    final response = await _send(
      () => httpClient.get(taskUri(taskId), headers: _headers),
    );
    if (response.statusCode != 200) throw _statusError('$label poll', response);
    return parseVideoTask(_bodyOf(response), taskId);
  }

  @override
  Future<List<int>> downloadClip(Uri url) async {
    final response = await _send(() => httpClient.get(url));
    if (response.statusCode != 200) {
      throw _statusError('$label download', response);
    }
    return response.bodyBytes;
  }

  /// One request with the shared network-failure mapping; HTTP status is
  /// classified by the callers.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } on http.ClientException catch (e) {
      throw PipelineError(ErrorClass.transient, '$label network error: $e');
    } on IOException catch (e) {
      throw PipelineError(ErrorClass.transient, '$label network error: $e');
    } on TimeoutException catch (e) {
      throw PipelineError(ErrorClass.transient, '$label timeout: $e');
    }
  }
}

/// Parses the async-task envelope. A malformed 200 is transient — a truncated
/// gateway reply may self-heal on the next poll (mirrors
/// QwenClient._extractContent).
I2vTask parseVideoTask(String body, String? fallbackTaskId) {
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
    throw PipelineError(ErrorClass.transient, 'malformed video response: $e');
  }
}

I2vStatus _statusOf(String raw) {
  if (raw == 'PENDING' || raw == 'RUNNING') return I2vStatus.running;
  if (raw == 'SUCCEEDED') return I2vStatus.succeeded;
  if (raw == 'FAILED' || raw == 'CANCELED') return I2vStatus.failed;
  throw FormatException('unknown task_status: $raw');
}

/// Status-first classification (spec §6): 408/429/5xx are transient, every
/// other non-2xx (401 bad key, 400 bad params) fails fast as fatal.
PipelineError _statusError(String what, http.Response response) {
  final status = response.statusCode;
  final detail = videoErrorDetail(response.bodyBytes);
  if (status == 408 || status == 429 || status >= 500) {
    return PipelineError(ErrorClass.transient, '$what HTTP $status: $detail');
  }
  return PipelineError(ErrorClass.fatal, '$what HTTP $status: $detail');
}

String _bodyOf(http.Response response) =>
    utf8.decode(response.bodyBytes, allowMalformed: true);

/// The provider's error message when the body carries one, else the
/// (truncated) raw body — this text lands in `state.json`.
String videoErrorDetail(List<int> bodyBytes) {
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
