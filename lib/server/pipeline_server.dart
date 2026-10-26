import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/image_client.dart';
import 'package:flutter_wanxiang/pipeline/bailian/wan30_video.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/dialect_map.dart';
import 'package:flutter_wanxiang/pipeline/drama/controller.dart';
import 'package:flutter_wanxiang/pipeline/drama/llm.dart';
import 'package:flutter_wanxiang/pipeline/drama/media_gateway.dart';
import 'package:flutter_wanxiang/pipeline/drama/pricing.dart';
import 'package:flutter_wanxiang/pipeline/drama/runner.dart';
import 'package:flutter_wanxiang/pipeline/drama/store.dart';
import 'package:flutter_wanxiang/pipeline/edit_models.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:flutter_wanxiang/pipeline/image_generation.dart';
import 'package:flutter_wanxiang/pipeline/speaker_video.dart';
import 'package:flutter_wanxiang/pipeline/video_generation.dart';
import 'package:flutter_wanxiang/server/api_router.dart';
import 'package:flutter_wanxiang/server/settings.dart';
import 'package:flutter_wanxiang/server/settings_controller.dart';

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

/// Default generic-video output root (`$HOME/conatus_viva/videos`).
String _defaultVideosDir() {
  final home = Platform.environment['HOME'];
  final base = (home != null && home.isNotEmpty)
      ? home
      : Directory.systemTemp.path;
  return '$base/conatus_viva/videos';
}

/// 通用文生视频页提供的宽高比；`adaptive` 由模型按提示词决定。
const List<String> _kxVideoRatios = <String>['adaptive', '16:9', '9:16', '1:1'];

/// 图片请求体上限：wan 2.7 可带 9 张 10MB 参考图，base64 编码后约 120MB，
/// 这里按 spec 的 40MB 先挡住明显异常的大包。
const int _maxImageBodyBytes = 40 * 1024 * 1024;

/// 首帧图片上限：与图片合成的参考图一致（10MB 原图）。
const int _maxFirstFrameBytes = 10 * 1024 * 1024;

/// 视频请求体上限：10MB 首帧 base64 后约 13.4MB，留出 JSON 余量。
const int _maxVideoBodyBytes = 20 * 1024 * 1024;

/// Decoded byte size of a base64 data URL's payload (4 chars → 3 bytes).
int _dataUrlBytes(String dataUrl) {
  final comma = dataUrl.indexOf(',');
  if (comma < 0) return 0;
  return (dataUrl.length - comma - 1) * 3 ~/ 4;
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
      images = <ImageJobImage>[],
      cost = 0,
      createdAt = DateTime.now();

  final String id;
  String status; // running | completed | failed
  final List<String> logs;
  final DateTime createdAt;
  final List<ImageJobImage> images;
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

/// Runs one image-edit batch; tests inject a fake to stay offline.
typedef ImageEditRunner =
    Future<ImageJob> Function({
      required ImageEditBatch batch,
      required String contentId,
      required void Function(String message) onProgress,
    });

/// Runs one generic text-to-video task (no speaker overlay); tests inject a fake.
typedef VideoRunner =
    Future<VideoGenResult> Function({
      required String prompt,
      required String? firstFrameDataUrl,
      required String model,
      required String resolution,
      required String ratio,
      required int durationS,
      required bool audio,
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
    this.imageEditRunner,
    this.videoRunner,
    this.avatarImage,
    this.outputDir,
    this.imagesOutputDir,
    this.videosOutputDir,
    this.plansDir,
    this.dramaController,
    this.dramaRoot,
    this.dramaLlm,
    this.secretStore,
  }) : _runs = <String, RunRecord>{},
       _imageJobs = <String, JobRunRecord>{},
       _videoJobs = <String, JobRunRecord>{},
       _settings = SettingsController(cfg: cfg, store: secretStore) {
    final store = DramaStore(rootDir: dramaRoot ?? 'pipeline_out/drama');
    final pricing = dramaPricingFromConfig(cfg);
    _drama =
        dramaController ??
        DramaController(
          store: store,
          drafts: DramaDraftService(
            llm: dramaLlm ?? QwenDramaLlm(cfg: cfg),
          ),
          priceYuanPerSecond: pricing.i2vYuanPerSecond,
          pricing: pricing,
          runner: DramaRunner(
            store: store,
            gateway: DashScopeDramaMediaGateway(cfg: cfg, pricing: pricing),
          ),
        );
  }

  final PipelineConfig cfg;
  final Directory staticDir;
  final int port;

  /// Test seam: when set, replaces the real 万相 generation.
  final SpeakerVideoRunner? speakerRunner;

  /// Test seam: when set, replaces the real image generation.
  final ImageRunner? imageRunner;

  /// Test seam: when set, replaces the real image-edit batch.
  final ImageEditRunner? imageEditRunner;

  /// Test seam: when set, replaces the real text-to-video generation.
  final VideoRunner? videoRunner;

  /// The cartoon presenter composited into every clip (from the bundled asset).
  final File? avatarImage;

  /// Absolute dir clips are written to; null → a per-user default under `$HOME`.
  final String? outputDir;

  /// Absolute dir images are written to; null → `$HOME/conatus_viva/images`.
  final String? imagesOutputDir;

  /// Absolute dir generic videos are written to; null →
  /// `$HOME/conatus_viva/videos`.
  final String? videosOutputDir;

  /// 短剧计划单根目录；null → `pipeline_out`（相对 CWD）。测试 seam。
  final String? plansDir;

  /// 短剧工作台 controller；测试注入 fake LLM / temp store。
  final DramaController? dramaController;

  /// 剧集存储根目录；null → `pipeline_out/drama`。
  final String? dramaRoot;

  /// 测试 seam：替换真实 LLM。
  final DramaLlm? dramaLlm;

  /// 设置页密钥存储；null → 设置 API 只读，PUT 返回 501。
  final SecretStore? secretStore;

  late final DramaController _drama;
  final SettingsController _settings;

  final Map<String, RunRecord> _runs;
  final Map<String, JobRunRecord> _imageJobs;
  final Map<String, JobRunRecord> _videoJobs;

  HttpServer? _server;

  /// The port the server is actually bound to, or `null` before [start].
  int? get boundPort => _server?.port;

  /// Starts the server; prints the bound URL to stdout.
  Future<void> start() async {
    final stored = await secretStore?.readAll();
    if (stored != null && stored.isNotEmpty) {
      cfg.updateSecrets(stored);
    }
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
      case ApiRoute.createVideo:
        await _createVideo(req);
      case ApiRoute.getVideo:
        await _getVideo(req);
      case ApiRoute.getVideoFile:
        await _getVideoFile(req);
      case ApiRoute.getShortDramaPlan:
        await _getShortDramaPlan(req);
      case ApiRoute.settings:
        await _settings.handle(req);
      case ApiRoute.drama:
        await _drama.handle(req);
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
        for (final model in kVideoModels)
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
    if (req.contentLength > _maxImageBodyBytes) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': '请求体超过 40MB',
      });
      return;
    }
    final body = await _readJsonBody(req, maxBytes: _maxImageBodyBytes);
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

    final rawItems = body['items'];
    if (rawItems is List) {
      if (mode != ImageMode.i2i) {
        _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
          'error': '包含 items 时 mode 必须是 i2i',
        });
        return;
      }
      if (rawItems.length > 20) {
        _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
          'error': '单次最多 20 条编辑任务',
        });
        return;
      }
      final items = <ImageEditItem>[];
      for (final raw in rawItems) {
        if (raw is! Map) {
          _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
            'error': 'items 条目格式错误',
          });
          return;
        }
        final refs = raw['refs'];
        items.add(
          ImageEditItem(
            prompt: (raw['prompt'] as String?)?.trim() ?? '',
            image: (raw['image'] as String?) ?? '',
            refs: refs is List
                ? <String>[
                    for (final ref in refs)
                      if (ref is String) ref,
                  ]
                : const <String>[],
          ),
        );
      }
      final batch = ImageEditBatch(
        model: model.id,
        family: model.family,
        items: items,
        size: (body['size'] as String?)?.trim(),
        seed: body['seed'] is int ? body['seed'] as int : null,
      );
      try {
        validateImageBatch(batch);
      } on PipelineError catch (e) {
        _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
          'error': e.message,
        });
        return;
      }
      final id = _newRunId('img');
      _imageJobs[id] = JobRunRecord(id: id);
      unawaited(_runImageEdits(id, batch));
      _sendJson(req, HttpStatus.accepted, <String, dynamic>{'id': id});
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
      record.images.addAll(job.images);
      record.cost = job.cost;
      final okCount = job.images.where((i) => i.ok).length;
      if (okCount == 0) {
        record.status = 'failed';
        record.error =
            '图片已生成但全部下载失败；任务可能已计费，请到百炼控制台核对后再决定是否重试';
        record.logs.add('失败：全部图片下载失败');
        return;
      }
      record.status = 'completed';
      record.logs.add('完成：$okCount 张');
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

  Future<void> _runImageEdits(String id, ImageEditBatch batch) async {
    final record = _imageJobs[id]!;
    record.logs.add(
      '开始：模型 ${batch.model}，编辑 ${batch.items.length} 条',
    );
    try {
      final runner = imageEditRunner ?? _defaultImageEditRunner;
      final job = await runner(
        batch: batch,
        contentId: id,
        onProgress: record.logs.add,
      );
      record.images.addAll(job.images);
      record.cost = job.cost;
      final okCount = job.images.where((i) => i.ok).length;
      if (okCount == 0) {
        record.status = 'failed';
        record.error =
            '全部编辑任务失败；若控制台显示已生成，请核对后再决定是否重试';
        record.logs.add('失败：全部条目失败');
        return;
      }
      record.status = 'completed';
      record.logs.add('完成：$okCount/${batch.items.length} 条');
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

  Future<ImageJob> _defaultImageEditRunner({
    required ImageEditBatch batch,
    required String contentId,
    required void Function(String message) onProgress,
  }) {
    final model = findImageModel(batch.model)!;
    final client = buildImageClient(
      request: ImageRequest(
        model: batch.model,
        family: batch.family,
        mode: ImageMode.i2i,
        prompt: batch.items.first.prompt,
        n: 1,
      ),
      apiKey: cfg.requireApiKey(),
      host: cfg.apiHost,
    );
    final prices = resolvePrices(
      defaults: model.defaultPrices,
      overrides: cfg.imagePrices,
      model: model.id,
    );
    return generateImageEdits(
      client: client,
      model: batch.model,
      family: batch.family,
      items: batch.items,
      baseDir: imagesOutputDir ?? _defaultImagesDir(),
      contentId: contentId,
      unitPrice: unitPrice(prices: prices, tier: priceTierFor(batch.size)),
      size: batch.size,
      seed: batch.seed,
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
        for (final image in record.images)
          <String, Object?>{
            'index': image.index,
            'path': image.path,
            'ok': image.ok,
            if (image.error != null) 'error': image.error,
          },
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
    ImageJobImage? image;
    if (index != null) {
      for (final candidate in record.images) {
        if (candidate.index == index && candidate.ok) {
          image = candidate;
          break;
        }
      }
    }
    if (image == null) {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'image not found',
      });
      return;
    }
    final file = File(image.path);
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

  Future<void> _createVideo(HttpRequest req) async {
    if (req.headers.contentType?.mimeType != 'application/json') {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'expected application/json',
      });
      return;
    }
    if (req.contentLength > _maxVideoBodyBytes) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': '请求体超过 20MB',
      });
      return;
    }
    final body = await _readJsonBody(req, maxBytes: _maxVideoBodyBytes);
    if (body == null) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'invalid JSON body',
      });
      return;
    }
    final modelId = (body['model'] as String?)?.trim() ?? '';
    final model = findVideoModel(modelId);
    if (model == null) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': '未知视频模型：$modelId',
      });
      return;
    }
    final modeName = (body['mode'] as String?)?.trim() ?? 't2v';
    final mode = switch (modeName) {
      't2v' => VideoMode.t2v,
      'i2v' => VideoMode.i2v,
      _ => null,
    };
    if (mode == null) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'mode 必须是 t2v/i2v',
      });
      return;
    }
    if (!model.modes.contains(mode)) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': '模型 ${model.id} 不支持 ${mode.name}',
      });
      return;
    }
    final firstFrame = (body['image'] as String?)?.trim() ?? '';
    if (mode == VideoMode.i2v) {
      if (firstFrame.isEmpty) {
        _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
          'error': '图生视频需要首帧图片',
        });
        return;
      }
      if (!isValidDataUrl(firstFrame)) {
        _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
          'error': '首帧图片必须是 PNG / JPEG / WebP 的 data URL',
        });
        return;
      }
      if (_dataUrlBytes(firstFrame) > _maxFirstFrameBytes) {
        _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
          'error': '首帧图片超过 10MB',
        });
        return;
      }
    }
    final prompt = (body['prompt'] as String?)?.trim() ?? '';
    if (mode == VideoMode.t2v && prompt.isEmpty) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'prompt 不能为空',
      });
      return;
    }
    final duration = body['duration'];
    if (duration is! int ||
        duration < model.durationMin ||
        duration > model.durationMax) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error':
            'duration 必须在 ${model.durationMin}..${model.durationMax} 秒',
      });
      return;
    }
    final resolution =
        (body['resolution'] as String?)?.trim() ??
        (model.resolutions.contains('720P')
            ? '720P'
            : model.resolutions.first);
    if (!model.resolutions.contains(resolution)) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'resolution 必须是 ${model.resolutions.join("/")}',
      });
      return;
    }
    final ratio = mode == VideoMode.i2v
        ? 'adaptive'
        : ((body['ratio'] as String?)?.trim() ?? 'adaptive');
    if (!_kxVideoRatios.contains(ratio)) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'ratio 必须是 ${_kxVideoRatios.join("/")}',
      });
      return;
    }
    final audio = body['audio'] is bool ? body['audio'] as bool : true;

    final id = _newRunId('vid');
    _videoJobs[id] = JobRunRecord(id: id);
    unawaited(
      _runVideo(
        id: id,
        prompt: prompt,
        firstFrameDataUrl: mode == VideoMode.i2v ? firstFrame : null,
        model: model,
        resolution: resolution,
        ratio: ratio,
        durationS: duration,
        audio: audio,
      ),
    );
    _sendJson(req, HttpStatus.accepted, <String, dynamic>{'id': id});
  }

  Future<void> _runVideo({
    required String id,
    required String prompt,
    required String? firstFrameDataUrl,
    required VideoModel model,
    required String resolution,
    required String ratio,
    required int durationS,
    required bool audio,
  }) async {
    final record = _videoJobs[id]!;
    record.logs.add(
      '开始：模型 ${model.id}，${firstFrameDataUrl == null ? '文生视频' : '图生视频'}，'
      '$resolution，$durationS 秒，音频=${audio ? '开' : '关'}',
    );
    try {
      final runner = videoRunner ?? _defaultVideoRunner;
      final result = await runner(
        prompt: prompt,
        firstFrameDataUrl: firstFrameDataUrl,
        model: model.id,
        resolution: resolution,
        ratio: ratio,
        durationS: durationS,
        audio: audio,
        contentId: id,
        onProgress: record.logs.add,
      );
      record.status = 'completed';
      record.filePath = result.filePath;
      final prices = resolvePrices(
        defaults: model.defaultPrices,
        overrides: cfg.videoPrices,
        model: model.id,
      );
      record.cost =
          durationS * unitPrice(prices: prices, tier: resolution);
      record.logs.add('完成：${result.filePath}');
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

  Future<VideoGenResult> _defaultVideoRunner({
    required String prompt,
    required String? firstFrameDataUrl,
    required String model,
    required String resolution,
    required String ratio,
    required int durationS,
    required bool audio,
    required String contentId,
    required void Function(String message) onProgress,
  }) {
    final client = Wan30VideoClient(
      apiKey: cfg.requireApiKey(),
      host: cfg.apiHost,
      model: model,
      resolution: resolution,
      ratio: ratio,
      watermark: cfg.t2vWatermark,
      seed: cfg.t2vSeed,
      audio: audio,
    );
    return generateVideo(
      client: client,
      prompt: prompt,
      firstFrameDataUrl: firstFrameDataUrl,
      durationS: durationS,
      outFile:
          '${videosOutputDir ?? _defaultVideosDir()}/$contentId/video.mp4',
      pollSeconds: cfg.t2vPollSeconds,
      maxWaitMinutes: cfg.t2vMaxWaitMinutes,
      onProgress: onProgress,
    );
  }

  Future<void> _getVideo(HttpRequest req) async {
    final id = req.uri.pathSegments[2];
    final record = _videoJobs[id];
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
      if (record.filePath != null) 'video_path': record.filePath,
      if (record.error != null) 'error': record.error,
    });
  }

  Future<void> _getVideoFile(HttpRequest req) async {
    final id = req.uri.pathSegments[2];
    final record = _videoJobs[id];
    if (record == null) {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'job not found',
      });
      return;
    }
    final path = record.filePath;
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

  /// 读取短剧渲染计划单（`GET /api/short-drama/plans/<content_id>`）。
  ///
  /// 只读、无鉴权，靠 loopback 隔离。路径由经过校验的 id 拼出，不接受任意
  /// 路径；id 只允许 `[A-Za-z0-9_-]`，从根目录读 `<id>/07_plan.json`。
  Future<void> _getShortDramaPlan(HttpRequest req) async {
    final segments = req.uri.pathSegments;
    if (segments.length != 4 ||
        segments[0] != 'api' ||
        segments[1] != 'short-drama' ||
        segments[2] != 'plans') {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'invalid content id',
      });
      return;
    }
    final id = segments[3];
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      _sendJson(req, HttpStatus.badRequest, <String, dynamic>{
        'error': 'invalid content id',
      });
      return;
    }

    final file = File('${plansDir ?? 'pipeline_out'}/$id/07_plan.json');
    final String text;
    try {
      text = await file.readAsString();
    } on FileSystemException {
      _sendJson(req, HttpStatus.notFound, <String, dynamic>{
        'error': 'plan not found',
      });
      return;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      _sendJson(req, HttpStatus.internalServerError, <String, dynamic>{
        'error': 'invalid plan file',
      });
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      _sendJson(req, HttpStatus.internalServerError, <String, dynamic>{
        'error': 'invalid plan file',
      });
      return;
    }
    _sendJson(req, HttpStatus.ok, decoded);
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

  Future<Map<String, dynamic>?> _readJsonBody(
    HttpRequest req, {
    int? maxBytes,
  }) async {
    try {
      final chunks = <int>[];
      await for (final chunk in req) {
        chunks.addAll(chunk);
        if (maxBytes != null && chunks.length > maxBytes) return null;
      }
      final decoded = jsonDecode(utf8.decode(chunks));
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
