import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/image_client.dart';
import 'package:flutter_wanxiang/pipeline/bailian/wan30_video.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/dialect_map.dart';
import 'package:flutter_wanxiang/pipeline/edit_models.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:flutter_wanxiang/pipeline/image_generation.dart';
import 'package:flutter_wanxiang/pipeline/speaker_video.dart';
import 'package:flutter_wanxiang/server/api_router.dart';

/// One dialect dropdown option.
///
/// [code] is the Chinese region key the UI sends back and `t2vPrompt` /
/// `resolveDialect` consume (e.g. `河南`); [label] is the pinyin tag
/// (e.g. `henan`); [name] is the display name (e.g. `河南话`).
class DialectOption {
  const DialectOption({
    required this.code,
    required this.label,
    required this.name,
    required this.instruction,
  });

  final String code;
  final String label;
  final String name;
  final String instruction;
}

/// Unique dialect options from [kDialectTable], deduplicated by label.
///
/// The first region key for each spec is used as the code (e.g. `广东` for
/// cantonese), so the value the UI sends back resolves back to the same spec.
List<DialectOption> get _dialectOptions {
  final seen = <String>{};
  final result = <DialectOption>[];
  for (final entry in kDialectTable.entries) {
    final spec = entry.value;
    if (!seen.add(spec.label)) continue;
    result.add(
      DialectOption(
        code: entry.key,
        label: spec.label,
        name: _dialectName(spec.instruction),
        instruction: spec.instruction,
      ),
    );
  }
  return result;
}

/// `请用河南话表达。` → `河南话` (display name for the dropdown).
String _dialectName(String instruction) {
  var s = instruction;
  if (s.startsWith('请用')) s = s.substring(2);
  if (s.endsWith('表达。')) s = s.substring(0, s.length - 3);
  return s;
}

/// Default directory for generated clips.
///
/// Absolute on purpose: a GUI app launched via `open` runs with cwd `/`, so a
/// relative `pipeline_out/...` would be unwritable once the App Sandbox (which
/// otherwise redirects cwd into the container) is off.
String _defaultOutputDir() {
  final home = Platform.environment['HOME'];
  final base = (home != null && home.isNotEmpty)
      ? home
      : Directory.systemTemp.path;
  return '$base/conatus_viva/speaker';
}

/// Default image output root (`$HOME/conatus_viva/images`).
String _defaultImagesDir() {
  final home = Platform.environment['HOME'];
  final base = (home != null && home.isNotEmpty)
      ? home
      : Directory.systemTemp.path;
  return '$base/conatus_viva/images';
}

/// Runs one text-to-video generation for [contentId]; the default builds a 万相
/// 3.0 client from the config, but tests inject a fake to stay offline.
typedef SpeakerVideoRunner = Future<SpeakerVideoResult> Function({
  required String theme,
  required String dialect,
  required int durationS,
  required String contentId,
  required void Function(String message) onProgress,
});

/// In-memory record of one generation run (status + logs + result).
class RunRecord {
  RunRecord({required this.id})
    : status = 'running',
      logs = <String>[],
      createdAt = DateTime.now();

  final String id;
  String status; // running | completed | failed
  final List<String> logs;
  final DateTime createdAt;
  String? videoPath;
  String? error;
}

/// In-memory record shared by image and video jobs.
class JobRunRecord {
  JobRunRecord({required this.id})
    : status = 'running',
      logs = <String>[],
      imagePaths = <String>[],
      cost = 0,
      createdAt = DateTime.now();

  final String id;
  String status; // running | completed | failed
  final List<String> logs;
  final DateTime createdAt;
  final List<String> imagePaths;
  double cost;
  String? filePath;
  String? error;
}

/// Runs one image-generation task; tests inject a fake to stay offline.
typedef ImageRunner =
    Future<ImageJob> Function({
      required ImageRequest request,
      required String contentId,
      required void Function(String message) onProgress,
    });

/// HTTP server serving the React UI and the text-to-video API.
///
/// Static files are served from [staticDir] (the React build output). The API
/// lives under `/api/*`. Generation is real unless [speakerRunner] is injected
/// (tests); the avatar overlaid onto every clip comes from [avatarImage].
class PipelineServer {
  PipelineServer({
    required this.cfg,
    required this.staticDir,
    this.port = 18080,
    this.speakerRunner,
    this.imageRunner,
    this.avatarImage,
    this.outputDir,
    this.imagesOutputDir,
  }) : _runs = <String, RunRecord>{},
       _imageJobs = <String, JobRunRecord>{};

  final PipelineConfig cfg;
  final Directory staticDir;
  final int port;

  /// Test seam: when set, replaces the real 万相 generation.
  final SpeakerVideoRunner? speakerRunner;

  /// Test seam: when set, replaces the real image generation.
  final ImageRunner? imageRunner;

  /// The cartoon presenter composited into every clip (from the bundled asset).
  final File? avatarImage;

  /// Absolute dir clips are written to; null → a per-user default under `$HOME`.
  final String? outputDir;

  /// Absolute dir images are written to; null → `$HOME/conatus_viva/images`.
  final String? imagesOutputDir;

  final Map<String, RunRecord> _runs;
  final Map<String, JobRunRecord> _imageJobs;

  HttpServer? _server;

  /// The port the server is actually bound to, or `null` before [start].
  int? get boundPort => _server?.port;

  /// Starts the server; prints the bound URL to stdout.
  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    stdout.writeln(
      'Pipeline server running at http://localhost:${_server!.port}',
    );
    _server!.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest req) async {
    try {
      if (req.uri.path.startsWith('/api/')) {
        await _handleApi(req);
      } else {
        await _serveStatic(req);
      }
    } catch (e) {
      _sendJson(req, HttpStatus.internalServerError, <String, dynamic>{
        'error': '$e',
      });
    }
  }

  Future<void> _handleApi(HttpRequest req) async {
    switch (apiRouteFor(req.method, req.uri.path)) {
      case ApiRoute.dialects:
        await _getDialects(req);
      case ApiRoute.getEditModels:
        await _getEditModels(req);
      case ApiRoute.getModels:
        await _getModels(req);
      case ApiRoute.createT2v:
        await _createT2v(req);
      case ApiRoute.getT2v:
        await _getT2v(req);
      case ApiRoute.getT2vVideo:
        await _getT2vVideo(req);
      case ApiRoute.createImage:
        await _createImage(req);
      case ApiRoute.getImage:
        await _getImage(req);
      case ApiRoute.getImageFile:
        await _getImageFile(req);
      case ApiRoute.unknown:
        _sendJson(req, HttpStatus.notFound, <String, dynamic>{
          'error': 'not found',
        });
    }
  }

  /// Serves the model catalog with config-resolved prices (`GET /api/models`).
  Future<void> _getModels(HttpRequest req) async {
    _sendJson(req, HttpStatus.ok, <String, dynamic>{
      'image': <Map<String, Object?>>[
        for (final model in kImageModels)
          model.toJson(
            resolvePrices(
              defaults: model.defaultPrices,
              overrides: cfg.imagePrices,
              model: model.id,
            ),
          ),
      ],
      'video': <Map<String, Object?>>[
        for (final model in kTextToVideoModels)
          model.toJson(
            resolvePrices(
              defaults: model.defaultPrices,
              overrides: cfg.videoPrices,
              model: model.id,
            ),
          ),
      ],
      'image_default_model': cfg.imageDefaultModel,
    });
  }

  Future<void> _getDialects(HttpRequest req) async {
    final dialects = _dialectOptions
        .map(
          (d) => <String, String>{
            'code': d.code,
            'label': d.label,
            'name': d.name,
            'instruction': d.instruction,
          },
        )
        .toList();
    _sendJson(req, HttpStatus.ok, <String, dynamic>{
      'dialects': dialects,
      't2v': <String, dynamic>{
        'yuan_per_second': cfg.t2vYuanPerSecond,
        'duration_min': t2vMinDurationS,
        'duration_max': t2vMaxDurationS,
      },
    });
  }

  /// Serves the read-only edit-model price catalog (`GET /api/edit-models`).
  Future<void> _getEditModels(HttpRequest req) async {
    _sendJson(req, HttpStatus.ok, <String, dynamic>{
      'edit_models': [for (final m in kEditModels) m.toJson()],
    });
  }

  Future<void> _createImage(HttpRequest req) async {
    if (req.headers.contentType?.mimeType != 'application/json') {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'expected application/json',
      });
      return;
    }
    final body = await _readJsonBody(req);
    if (body == null) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'invalid JSON body',
      });
      return;
    }

    final modelId = (body['model'] as String?)?.trim() ?? '';
    final model = findImageModel(modelId);
    if (model == null) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': '未知图片模型：$modelId',
      });
      return;
    }
    final modeName = body['mode'] as String? ?? '';
    final mode = _imageMode(modeName);
    if (mode == null) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'mode 必须是 t2i/i2i/series',
      });
      return;
    }

    final rawRefs = body['refs'];
    final request = ImageRequest(
      model: model.id,
      family: model.family,
      mode: mode,
      prompt: (body['prompt'] as String?)?.trim() ?? '',
      negativePrompt: (body['negative_prompt'] as String?)?.trim(),
      size: (body['size'] as String?)?.trim(),
      n: body['n'] is int ? body['n'] as int : 1,
      seed: body['seed'] is int ? body['seed'] as int : null,
      refImages: rawRefs is List
          ? <String>[
              for (final ref in rawRefs)
                if (ref is String) ref,
            ]
          : const <String>[],
    );
    try {
      validateImageRequest(request);
    } on PipelineError catch (e) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': e.message,
      });
      return;
    }

    final id = _newRunId('img');
    _imageJobs[id] = JobRunRecord(id: id);
    unawaited(_runImage(id, request));
    _sendJson(req, HttpStatus.accepted, <String, dynamic>{'id': id});
  }

  Future<void> _runImage(String id, ImageRequest request) async {
    final record = _imageJobs[id]!;
    record.logs.add(
      '开始：模型 ${request.model}，模式 ${request.mode.name}，n=${request.n}',
    );
    try {
      final runner = imageRunner ?? _defaultImageRunner;
      final job = await runner(
        request: request,
        contentId: id,
        onProgress: record.logs.add,
      );
      record.status = 'completed';
      record.cost = job.cost;
      record.imagePaths.addAll(job.images.where((i) => i.ok).map((i) => i.path));
      record.logs.add('完成：${job.images.where((i) => i.ok).length} 张');
    } on PipelineError catch (e) {
      record.status = 'failed';
      record.error = e.message;
      record.logs.add('失败：${e.message}');
    } on ConfigException catch (e) {
      record.status = 'failed';
      record.error = '未配置 DASHSCOPE_API_KEY：请设置环境变量 DASHSCOPE_API_KEY 后重试'
          '（${e.message}）';
      record.logs.add('失败：${record.error}');
    } catch (e) {
      record.status = 'failed';
      record.error = '$e';
      record.logs.add('失败：$e');
    }
  }

  Future<ImageJob> _defaultImageRunner({
    required ImageRequest request,
    required String contentId,
    required void Function(String message) onProgress,
  }) {
    final client = buildImageClient(
      request: request,
      apiKey: cfg.requireApiKey(),
      host: cfg.apiHost,
    );
    final model = findImageModel(request.model)!;
    final prices = resolvePrices(
      defaults: model.defaultPrices,
      overrides: cfg.imagePrices,
      model: model.id,
    );
    return generateImages(
      client: client,
      request: request,
      baseDir: imagesOutputDir ?? _defaultImagesDir(),
      contentId: contentId,
      unitPrice: unitPrice(prices: prices, tier: priceTierFor(request.size)),
      pollSeconds: cfg.imagePollSeconds,
      maxWaitMinutes: cfg.imageMaxWaitMinutes,
      onProgress: onProgress,
    );
  }

  Future<void> _getImage(HttpRequest req) async {
    final id = req.uri.pathSegments[2];
    final record = _imageJobs[id];
    if (record == null) {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'job not found',
      });
      return;
    }
    _sendJson(req, HttpStatus.ok, <String, dynamic>{
      'id': record.id,
      'status': record.status,
      'logs': record.logs,
      'cost': record.cost,
      'results': <Map<String, Object?>>[
        for (var i = 0; i < record.imagePaths.length; i++)
          <String, Object?>{'index': i + 1, 'path': record.imagePaths[i]},
      ],
      if (record.error != null) 'error': record.error,
    });
  }

  Future<void> _getImageFile(HttpRequest req) async {
    final id = req.uri.pathSegments[2];
    final index = int.tryParse(req.uri.pathSegments[3]);
    final record = _imageJobs[id];
    if (record == null) {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'job not found',
      });
      return;
    }
    if (index == null ||
        index < 1 ||
        index > record.imagePaths.length) {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'image not found',
      });
      return;
    }
    final file = File(record.imagePaths[index - 1]);
    if (!await file.exists()) {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'file not found',
      });
      return;
    }
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.set(HttpHeaders.contentTypeHeader, 'image/png')
      ..headers.set(
        'content-disposition',
        'inline; filename="image-${index.toString().padLeft(2, '0')}.png"',
      )
      ..headers.set(HttpHeaders.contentLengthHeader, await file.length());
    await file.openRead().pipe(req.response);
  }

  Future<void> _createT2v(HttpRequest req) async {
    if (req.headers.contentType?.mimeType != 'application/json') {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'expected application/json',
      });
      return;
    }
    final body = await _readJsonBody(req);
    if (body == null) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'invalid JSON body',
      });
      return;
    }

    final theme = (body['theme'] as String?)?.trim() ?? '';
    if (theme.isEmpty) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'theme is required',
      });
      return;
    }
    final dialect = (body['dialect'] as String?)?.trim() ?? '';
    if (dialect.isEmpty) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'dialect is required',
      });
      return;
    }
    final duration = body['duration'];
    if (duration is! int ||
        duration < t2vMinDurationS ||
        duration > t2vMaxDurationS) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'duration must be $t2vMinDurationS..$t2vMaxDurationS seconds',
      });
      return;
    }

    final id = _newRunId('run');
    final record = RunRecord(id: id);
    _runs[id] = record;

    unawaited(_runT2v(id, theme, dialect, duration));

    _sendJson(req, HttpStatus.accepted, <String, dynamic>{'id': id});
  }

  Future<void> _runT2v(
    String id,
    String theme,
    String dialect,
    int durationS,
  ) async {
    final record = _runs[id]!;
    record.logs.add('开始：主题「$theme」，方言=$dialect，时长=${durationS}s');

    try {
      final runner = speakerRunner ?? _defaultRunner;
      final result = await runner(
        theme: theme,
        dialect: dialect,
        durationS: durationS,
        contentId: id,
        onProgress: record.logs.add,
      );
      record.status = 'completed';
      record.videoPath = result.finalVideoPath;
      record.logs.add('完成：${result.finalVideoPath}');
    } on PipelineError catch (e) {
      record.status = 'failed';
      record.error = e.message;
      record.logs.add('失败：${e.message}');
    } on ConfigException catch (e) {
      record.status = 'failed';
      record.error = '未配置 DASHSCOPE_API_KEY：请设置环境变量 DASHSCOPE_API_KEY 后重试'
          '（${e.message}）';
      record.logs.add('失败：${record.error}');
    } catch (e) {
      record.status = 'failed';
      record.error = '$e';
      record.logs.add('失败：$e');
    }
  }

  Future<SpeakerVideoResult> _defaultRunner({
    required String theme,
    required String dialect,
    required int durationS,
    required String contentId,
    required void Function(String message) onProgress,
  }) {
    final avatar = avatarImage;
    if (avatar == null) {
      throw const PipelineError(ErrorClass.fatal, '主讲人素材未配置（avatarImage 缺失）');
    }
    final client = Wan30VideoClient(
      apiKey: cfg.requireApiKey(),
      host: cfg.apiHost,
      model: cfg.t2vModel,
      resolution: cfg.t2vResolution,
      ratio: cfg.t2vRatio,
      watermark: cfg.t2vWatermark,
      seed: cfg.t2vSeed,
      audio: cfg.t2vAudio,
    );
    return generateSpeakerVideo(
      client: client,
      theme: theme,
      dialect: dialect,
      durationS: durationS,
      contentId: contentId,
      avatar: avatar,
      baseDir: outputDir ?? _defaultOutputDir(),
      pollSeconds: cfg.t2vPollSeconds,
      maxWaitMinutes: cfg.t2vMaxWaitMinutes,
      onProgress: onProgress,
    );
  }

  Future<void> _getT2v(HttpRequest req) async {
    final id = req.uri.pathSegments[2];
    final record = _runs[id];
    if (record == null) {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'run not found',
      });
      return;
    }
    _sendJson(req, HttpStatus.ok, <String, dynamic>{
      'id': record.id,
      'status': record.status,
      'logs': record.logs,
      if (record.videoPath != null) 'video_path': record.videoPath,
      if (record.error != null) 'error': record.error,
    });
  }

  Future<void> _getT2vVideo(HttpRequest req) async {
    final id = req.uri.pathSegments[2];
    final record = _runs[id];
    if (record == null) {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'run not found',
      });
      return;
    }
    final path = record.videoPath;
    if (path == null) {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'no video yet',
      });
      return;
    }
    final file = File(path);
    if (!await file.exists()) {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'file not found',
      });
      return;
    }
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.set(HttpHeaders.contentTypeHeader, 'video/mp4')
      ..headers.set(
        'content-disposition',
        'attachment; filename="video.mp4"',
      )
      ..headers.set(HttpHeaders.contentLengthHeader, await file.length());
    await file.openRead().pipe(req.response);
  }

  Future<Map<String, dynamic>?> _readJsonBody(HttpRequest req) async {
    try {
      final body = await utf8.decoder.bind(req).join();
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on Exception {
      return null;
    }
  }

  Future<void> _serveStatic(HttpRequest req) async {
    var relPath = req.uri.path == '/' ? 'index.html' : req.uri.path;
    relPath = relPath.replaceFirst('/', '');
    final file = File('${staticDir.path}/$relPath');

    if (!await file.exists()) {
      final fallback = File('${staticDir.path}/index.html');
      if (await fallback.exists()) {
        await _serveFile(req, fallback);
        return;
      }
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'not found',
      });
      return;
    }
    await _serveFile(req, file);
  }

  Future<void> _serveFile(HttpRequest req, File file) async {
    final ext = file.path.split('.').last.toLowerCase();
    final mime = _mimeType(ext);
    req.response
      ..statusCode = HttpStatus.ok
      ..headers.set(HttpHeaders.contentTypeHeader, mime)
      ..headers.set(HttpHeaders.contentLengthHeader, await file.length());
    await file.openRead().pipe(req.response);
  }

  String _mimeType(String ext) {
    switch (ext) {
      case 'html':
        return 'text/html; charset=utf-8';
      case 'js':
        return 'application/javascript; charset=utf-8';
      case 'css':
        return 'text/css; charset=utf-8';
      case 'json':
        return 'application/json; charset=utf-8';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'svg':
        return 'image/svg+xml';
      case 'woff2':
        return 'font/woff2';
      case 'ico':
        return 'image/x-icon';
      default:
        return 'application/octet-stream';
    }
  }

  String _newRunId(String prefix) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$prefix-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}-'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  /// `t2i` / `i2i` / `series` → enum, or null when the name is unknown.
  ImageMode? _imageMode(String name) {
    for (final mode in ImageMode.values) {
      if (mode.name == name) return mode;
    }
    return null;
  }

  void _sendJson(HttpRequest req, int status, Map<String, dynamic> body) {
    final data = utf8.encode(jsonEncode(body));
    req.response
      ..statusCode = status
      ..headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      )
      ..headers.set(HttpHeaders.contentLengthHeader, data.length)
      ..add(data);
    unawaited(req.response.close());
  }
}
