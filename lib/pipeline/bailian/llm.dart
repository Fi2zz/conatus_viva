import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../errors.dart';

/// OpenAI-compatible chat client for the Bailian compatible-mode endpoint
/// (`$baseUrl/chat/completions`), used by the classify (Task 8) and script
/// (Task 9) steps.
///
/// Error mapping (spec §6 错误分类与重试):
/// - 429 / 408 / 5xx / network failure → [ErrorClass.transient], retried up
///   to `maxRetries` times with 1s then 2s backoff
/// - 401 / 400 (bad key, invalid params) and any other non-2xx status →
///   [ErrorClass.fatal], fail fast without consuming retries
class QwenClient {
  QwenClient({
    required this._apiKey,
    required String baseUrl,
    http.Client? client,
    this._model = 'qwen3.8-flash',
  }) : _baseUrl = baseUrl.endsWith('/')
           ? baseUrl.substring(0, baseUrl.length - 1)
           : baseUrl,
       _client = client ?? http.Client();

  /// Backoff between retries (spec §6: 重试 ×2，指数退避 1s/2s).
  static const List<Duration> _retryDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
  ];

  /// Declares bare-JSON output in the system prompt of [chatJson].
  static const String _jsonOnlyInstruction =
      '\n只输出一个 JSON 对象本身：不要 Markdown 代码围栏，不要任何解释或前后缀文本。';

  final String _apiKey;
  final String _baseUrl;
  final http.Client _client;
  final String _model;

  /// Waits between retries. Tests replace this with a no-op so the suite
  /// never waits out the real 1s/2s backoff.
  Future<void> Function(Duration delay) sleep = _realSleep;

  static Future<void> _realSleep(Duration delay) => Future<void>.delayed(delay);

  /// One chat completion. [images] are read as raw bytes and inlined in the
  /// user content array as `data:image/jpeg;base64` URLs.
  ///
  /// Throws [PipelineError] per the class mapping documented on [QwenClient];
  /// an unreadable [images] file is fatal (it will not self-heal).
  Future<String> chat({
    required String system,
    required String user,
    List<File>? images,
    int maxRetries = 2,
  }) async {
    final retries = maxRetries < 0 ? 0 : maxRetries;
    final messages = _messages(system, user, images);
    for (var attempt = 0; ; attempt++) {
      try {
        return await _requestOnce(messages);
      } on PipelineError catch (e) {
        if (e.cls != ErrorClass.transient || attempt >= retries) rethrow;
        await sleep(_delayFor(attempt));
      }
    }
  }

  /// [chat] variant that demands bare JSON output (declared in the system
  /// prompt) and decodes it. Fences are stripped before decoding; a parse
  /// failure is retried as [ErrorClass.transient] alongside HTTP retries.
  Future<Map<String, dynamic>> chatJson({
    required String system,
    required String user,
    List<File>? images,
    int maxRetries = 2,
  }) async {
    final retries = maxRetries < 0 ? 0 : maxRetries;
    final messages = _messages('$system$_jsonOnlyInstruction', user, images);
    Object? lastFailure;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (attempt > 0) await sleep(_delayFor(attempt - 1));
      try {
        final decoded = jsonDecode(_stripFences(await _requestOnce(messages)));
        if (decoded is! Map<String, dynamic>) {
          throw FormatException(
            'JSON root must be an object, got ${decoded.runtimeType}',
          );
        }
        return decoded;
      } on PipelineError catch (e) {
        if (e.cls != ErrorClass.transient) rethrow;
        lastFailure = e;
      } on FormatException catch (e) {
        lastFailure = e;
      }
    }
    throw PipelineError(ErrorClass.transient, 'chatJson failed: $lastFailure');
  }

  /// A surrounding ` ```json … ``` ` fence (or plain ` ``` `) is removed so
  /// models that ignore the bare-JSON instruction still decode.
  static String _stripFences(String raw) {
    final text = raw.trim();
    final match = RegExp(
      r'^```(?:json)?[ \t]*\r?\n?(.*?)\r?\n?```$',
      dotAll: true,
    ).firstMatch(text);
    return match == null ? text : match.group(1)!.trim();
  }

  static Duration _delayFor(int retryIndex) => retryIndex < _retryDelays.length
      ? _retryDelays[retryIndex]
      : _retryDelays.last;

  List<Map<String, dynamic>> _messages(
    String system,
    String user,
    List<File>? images,
  ) => <Map<String, dynamic>>[
    <String, dynamic>{'role': 'system', 'content': system},
    <String, dynamic>{'role': 'user', 'content': _userContent(user, images)},
  ];

  /// String content when there are no images; otherwise a content part array
  /// of one text part followed by one data-URL image part per image.
  Object _userContent(String user, List<File>? images) {
    if (images == null || images.isEmpty) return user;
    final parts = <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': user},
    ];
    for (final image in images) {
      final List<int> bytes;
      try {
        bytes = image.readAsBytesSync();
      } on FileSystemException catch (e) {
        // A missing/unreadable photo will not self-heal on retry.
        throw PipelineError(ErrorClass.fatal, 'cannot read image: $e');
      }
      final encoded = base64Encode(bytes);
      parts.add(<String, dynamic>{
        'type': 'image_url',
        'image_url': <String, dynamic>{
          'url': 'data:image/jpeg;base64,$encoded',
        },
      });
    }
    return parts;
  }

  /// Executes exactly one request/reply cycle with no retry; [chat] and
  /// [chatJson] own the retry loops.
  Future<String> _requestOnce(List<Map<String, dynamic>> messages) async {
    final http.Response response;
    try {
      response = await _client.post(
        Uri.parse('$_baseUrl/chat/completions'),
        headers: <String, String>{
          'Authorization': 'Bearer $_apiKey',
          'content-type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'model': _model,
          'messages': messages,
        }),
      );
    } on http.ClientException catch (e) {
      throw PipelineError(ErrorClass.transient, 'LLM network error: $e');
    } on IOException catch (e) {
      throw PipelineError(ErrorClass.transient, 'LLM network error: $e');
    } on TimeoutException catch (e) {
      throw PipelineError(ErrorClass.transient, 'LLM timeout: $e');
    }

    final status = response.statusCode;
    final body = _bodyOf(response);
    if (status == 200) return _extractContent(body);
    final detail = _errorDetail(body);
    if (status == 408 || status == 429 || status >= 500) {
      throw PipelineError(ErrorClass.transient, 'LLM HTTP $status: $detail');
    }
    throw PipelineError(ErrorClass.fatal, 'LLM HTTP $status: $detail');
  }

  /// Decodes [response.body]. Malformed UTF-8 from the server throws inside
  /// the decoder, so it is classified here as transient — the bytes are
  /// server-side and may self-heal on the next attempt.
  String _bodyOf(http.Response response) {
    try {
      return response.body;
    } catch (e) {
      throw PipelineError(
        ErrorClass.transient,
        'LLM response body decode failed: $e',
      );
    }
  }

  /// `choices[0].message.content` of a 200 reply. A malformed envelope is
  /// transient (a truncated gateway reply is worth one more attempt).
  String _extractContent(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('response root is not an object');
      }
      final choices = decoded['choices'];
      if (choices is! List || choices.isEmpty) {
        throw const FormatException('response has no choices');
      }
      final message = choices.first is Map
          ? (choices.first as Map)['message']
          : null;
      final content = message is Map ? message['content'] : null;
      if (content is! String) {
        throw const FormatException('response message.content is not a string');
      }
      return content;
    } catch (e) {
      throw PipelineError(ErrorClass.transient, 'malformed LLM response: $e');
    }
  }

  /// The provider's `error.message` when the body carries one, else the
  /// (truncated) raw body — this text lands in `state.json`.
  static String _errorDetail(String body) {
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
}
