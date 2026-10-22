import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../errors.dart';
import '../generation_models.dart';

/// Observed state of a DashScope async image task: PENDING/RUNNING collapse to
/// [running]; SUCCEEDED and FAILED/CANCELED are terminal.
enum ImageTaskStatus { running, succeeded, failed }

/// One observed state of an async image task.
class ImageTask {
  const ImageTask({
    required this.taskId,
    required this.status,
    required this.imageUrls,
    this.errorCode,
  });

  final String taskId;
  final ImageTaskStatus status;

  /// Present only on success; provider URLs live for 24h.
  final List<Uri> imageUrls;

  /// Provider `code` on failure, preserved for logs.
  final String? errorCode;
}

/// One image-generation request, independent of model family.
class ImageRequest {
  const ImageRequest({
    required this.model,
    required this.family,
    required this.mode,
    required this.prompt,
    required this.n,
    this.negativePrompt,
    this.size,
    this.seed,
    this.refImages = const <String>[],
  });

  final String model;
  final ImageFamily family;
  final ImageMode mode;
  final String prompt;
  final String? negativePrompt;

  /// `1K`/`2K`/`4K` or `宽*高`; null lets the provider choose.
  final String? size;
  final int n;
  final int? seed;

  /// `data:image/...;base64,...` strings, in prompt order.
  final List<String> refImages;
}

/// Common contract for the DashScope image clients — one implementation per
/// model family, so the job runner never branches on a model name.
abstract interface class ImageGenClient {
  /// Creates one async task.
  Future<ImageTask> submit(ImageRequest request);

  /// One poll of [taskId]; the caller owns the interval and the deadline.
  Future<ImageTask> poll(String taskId);

  /// Downloads a succeeded task's image bytes (24h URL lifetime).
  Future<List<int>> download(Uri url);
}

/// Shared DashScope async-image mechanics: submit, poll, download, task-envelope
/// parsing and status-first error classification. Subclasses describe only
/// their family's endpoint, body and result shape.
abstract class DashScopeImageClient implements ImageGenClient {
  DashScopeImageClient({
    required this.apiKey,
    required this.model,
    http.Client? client,
    String? host,
  }) : httpClient = client ?? http.Client(),
       host = host ?? defaultHost;

  /// Default workspace-less DashScope host.
  static const String defaultHost = 'https://dashscope.aliyuncs.com';

  final String apiKey;
  final String model;
  final http.Client httpClient;
  final String host;

  /// Error-message prefix (`qwen-image`, `wan2.7-image`, `z-image`).
  String get label => model;

  /// Async submit endpoint for this family.
  Uri get submitUri;

  /// The family's `{model, input, parameters}` body.
  Map<String, dynamic> buildBody(ImageRequest request);

  /// Extracts image URLs from a succeeded task's `output` object.
  List<Uri> extractUrls(Map<String, dynamic> output);

  Uri taskUri(String taskId) => Uri.parse('$host/api/v1/tasks/$taskId');

  Map<String, String> get _headers => <String, String>{
    'Authorization': 'Bearer $apiKey',
    'content-type': 'application/json',
  };

  @override
  Future<ImageTask> submit(ImageRequest request) async {
    final response = await _send(
      () => httpClient.post(
        submitUri,
        headers: <String, String>{..._headers, 'X-DashScope-Async': 'enable'},
        body: jsonEncode(buildBody(request)),
      ),
    );
    if (response.statusCode != 200) {
      throw _statusError('$label submit', response);
    }
    return parseImageTask(_bodyOf(response), null, extractUrls);
  }

  @override
  Future<ImageTask> poll(String taskId) async {
    final response = await _send(
      () => httpClient.get(taskUri(taskId), headers: _headers),
    );
    if (response.statusCode != 200) {
      throw _statusError('$label poll', response);
    }
    return parseImageTask(_bodyOf(response), taskId, extractUrls);
  }

  @override
  Future<List<int>> download(Uri url) async {
    final response = await _send(() => httpClient.get(url));
    if (response.statusCode != 200) {
      throw _statusError('$label download', response);
    }
    return response.bodyBytes;
  }

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

/// 千问图像 3.0 系列：`image-generation/generation`，结果在
/// `output.choices[].message.content[].image`。
class QwenImageClient extends DashScopeImageClient {
  QwenImageClient({
    required super.apiKey,
    required super.model,
    super.client,
    super.host,
  });

  @override
  Uri get submitUri => Uri.parse(
    '$host/api/v1/services/aigc/image-generation/generation',
  );

  @override
  Map<String, dynamic> buildBody(ImageRequest request) {
    return <String, dynamic>{
      'model': model,
      'input': <String, dynamic>{
        'messages': <dynamic>[
          <String, dynamic>{
            'role': 'user',
            'content': <dynamic>[
              for (final image in request.refImages)
                <String, dynamic>{'image': image},
              <String, dynamic>{'text': request.prompt},
            ],
          },
        ],
      },
      'parameters': <String, dynamic>{
        'n': request.n,
        'prompt_extend': true,
        if (request.size != null) 'size': request.size,
        if (request.seed != null) 'seed': request.seed,
        if (request.negativePrompt != null)
          'negative_prompt': request.negativePrompt,
      },
    };
  }

  @override
  List<Uri> extractUrls(Map<String, dynamic> output) =>
      _choicesUrls(output);
}

/// 万相图像 2.7 系列：同一端点与响应结构，参数多组图/思考模式。
class WanImageClient extends DashScopeImageClient {
  WanImageClient({
    required super.apiKey,
    required super.model,
    super.client,
    super.host,
  });

  @override
  Uri get submitUri => Uri.parse(
    '$host/api/v1/services/aigc/image-generation/generation',
  );

  @override
  Map<String, dynamic> buildBody(ImageRequest request) {
    final series = request.mode == ImageMode.series;
    return <String, dynamic>{
      'model': model,
      'input': <String, dynamic>{
        'messages': <dynamic>[
          <String, dynamic>{
            'role': 'user',
            'content': <dynamic>[
              for (final image in request.refImages)
                <String, dynamic>{'image': image},
              <String, dynamic>{'text': request.prompt},
            ],
          },
        ],
      },
      'parameters': <String, dynamic>{
        'size': request.size ?? '2K',
        'n': request.n,
        'watermark': false,
        'enable_sequential': series,
        if (!series && request.mode == ImageMode.t2i) 'thinking_mode': true,
        if (request.seed != null) 'seed': request.seed,
      },
    };
  }

  @override
  List<Uri> extractUrls(Map<String, dynamic> output) =>
      _choicesUrls(output);
}

/// Z-Image：老式 `text2image/image-synthesis`，结果在 `output.results[].url`。
class ZImageClient extends DashScopeImageClient {
  ZImageClient({
    required super.apiKey,
    required super.model,
    super.client,
    super.host,
  });

  @override
  Uri get submitUri => Uri.parse(
    '$host/api/v1/services/aigc/text2image/image-synthesis',
  );

  @override
  Map<String, dynamic> buildBody(ImageRequest request) {
    return <String, dynamic>{
      'model': model,
      'input': <String, dynamic>{'prompt': request.prompt},
      'parameters': <String, dynamic>{
        'size': request.size ?? '2048*2048',
        'n': 1,
        if (request.seed != null) 'seed': request.seed,
      },
    };
  }

  @override
  List<Uri> extractUrls(Map<String, dynamic> output) {
    final results = output['results'];
    if (results is! List) return const <Uri>[];
    return <Uri>[
      for (final item in results)
        if (item is Map && item['url'] is String)
          Uri.parse(item['url'] as String),
    ];
  }
}

/// Builds the client for [request]'s family; the single seam between the
/// catalog's family field and the concrete adapter.
ImageGenClient buildImageClient({
  required ImageRequest request,
  required String apiKey,
  http.Client? client,
  String? host,
}) {
  switch (request.family) {
    case ImageFamily.qwen3:
      return QwenImageClient(
        apiKey: apiKey,
        model: request.model,
        client: client,
        host: host,
      );
    case ImageFamily.wan27:
      return WanImageClient(
        apiKey: apiKey,
        model: request.model,
        client: client,
        host: host,
      );
    case ImageFamily.zImage:
      return ZImageClient(
        apiKey: apiKey,
        model: request.model,
        client: client,
        host: host,
      );
  }
}

/// Parses the async-task envelope into an [ImageTask]. A malformed 200 is
/// transient (a truncated gateway reply may self-heal on the next poll).
ImageTask parseImageTask(
  String body,
  String? fallbackTaskId,
  List<Uri> Function(Map<String, dynamic> output) extractUrls,
) {
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
    final rawCode = output['code'] ?? decoded['code'];
    return ImageTask(
      taskId: taskId,
      status: _statusOf(rawStatus),
      imageUrls: _statusOf(rawStatus) == ImageTaskStatus.succeeded
          ? extractUrls(output)
          : const <Uri>[],
      errorCode: rawCode is String ? rawCode : null,
    );
  } catch (e) {
    throw PipelineError(ErrorClass.transient, 'malformed image response: $e');
  }
}

ImageTaskStatus _statusOf(String raw) {
  if (raw == 'PENDING' || raw == 'RUNNING') return ImageTaskStatus.running;
  if (raw == 'SUCCEEDED') return ImageTaskStatus.succeeded;
  if (raw == 'FAILED' || raw == 'CANCELED') return ImageTaskStatus.failed;
  throw FormatException('unknown task_status: $raw');
}

List<Uri> _choicesUrls(Map<String, dynamic> output) {
  final choices = output['choices'];
  if (choices is! List) return const <Uri>[];
  final urls = <Uri>[];
  for (final choice in choices) {
    if (choice is! Map) continue;
    final message = choice['message'];
    if (message is! Map) continue;
    final content = message['content'];
    if (content is! List) continue;
    for (final part in content) {
      if (part is Map && part['image'] is String) {
        urls.add(Uri.parse(part['image'] as String));
      }
    }
  }
  return urls;
}

/// Status-first classification: 408/429/5xx are transient, every other
/// non-2xx (401 bad key, 400 bad params) fails fast as fatal.
PipelineError _statusError(String what, http.Response response) {
  final status = response.statusCode;
  final detail = _errorDetail(response.bodyBytes);
  if (status == 408 || status == 429 || status >= 500) {
    return PipelineError(ErrorClass.transient, '$what HTTP $status: $detail');
  }
  return PipelineError(ErrorClass.fatal, '$what HTTP $status: $detail');
}

String _bodyOf(http.Response response) =>
    utf8.decode(response.bodyBytes, allowMalformed: true);

String _errorDetail(List<int> bodyBytes) {
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
