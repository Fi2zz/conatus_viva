/// 短剧媒体网关：把图片、i2v 与本地 ffmpeg 藏在可注入接口后。
///
/// 真实实现复用现有 DashScope 客户端；测试用 fake 网关，不碰网络。
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../bailian/i2v.dart';
import '../bailian/image_client.dart';
import '../bailian/uploader.dart';
import '../config.dart';
import '../errors.dart';
import '../ffmpeg.dart';
import '../generation_models.dart';
import '../image_generation.dart';
import '../render_plan.dart';
import 'pricing.dart';

class DramaMediaResult {
  const DramaMediaResult({
    required this.path,
    required this.costYuan,
    required this.model,
    this.durationS,
  });

  final String path;
  final double costYuan;
  final String model;
  final double? durationS;
}

abstract interface class DramaMediaGateway {
  Future<DramaMediaResult> generateImage({
    required String model,
    required ImageMode mode,
    required String prompt,
    required String baseDir,
    required String contentId,
    List<File> refFiles = const <File>[],
    String size = '1K',
    required void Function(String) onLog,
  });

  Future<DramaMediaResult> generateI2vClip({
    required String model,
    required String resolution,
    required File firstFrame,
    required String prompt,
    required int durationS,
    required File outFile,
    required void Function(String) onLog,
  });

  Future<void> renderLocalClip({
    required File image,
    required File outFile,
    required ShotRoute route,
    required int width,
    required int height,
    required int durationS,
  });

  Future<void> normalizeClip({
    required File input,
    required File outFile,
    required int width,
    required int height,
  });
}

class DashScopeDramaMediaGateway implements DramaMediaGateway {
  DashScopeDramaMediaGateway({
    required this.cfg,
    required this.pricing,
    this.client,
    Future<void> Function(Duration delay)? sleep,
    DateTime Function()? now,
  }) : _sleep = sleep ?? ((Duration d) => Future<void>.delayed(d)),
       _now = now ?? DateTime.now;

  final PipelineConfig cfg;
  final DramaPricing pricing;
  final http.Client? client;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  @override
  Future<DramaMediaResult> generateImage({
    required String model,
    required ImageMode mode,
    required String prompt,
    required String baseDir,
    required String contentId,
    List<File> refFiles = const <File>[],
    String size = '1K',
    required void Function(String) onLog,
  }) async {
    final apiKey = cfg.requireApiKey();
    final found = findImageModel(model);
    if (found == null) {
      throw PipelineError(ErrorClass.fatal, '未知图片模型：$model');
    }
    final request = ImageRequest(
      model: found.id,
      family: found.family,
      mode: mode,
      prompt: prompt,
      n: 1,
      size: size,
      refImages: <String>[
        for (final ref in refFiles) await _dataUrl(ref),
      ],
    );
    final imageClient = buildImageClient(
      request: request,
      apiKey: apiKey,
      client: client,
      host: cfg.apiHost,
    );
    final price = pricing.imagePrice(found.id, priceTierFor(size));
    final job = await generateImages(
      client: imageClient,
      request: request,
      baseDir: baseDir,
      contentId: contentId,
      unitPrice: price,
      pollSeconds: cfg.imagePollSeconds,
      maxWaitMinutes: cfg.imageMaxWaitMinutes,
      sleep: _sleep,
      now: _now,
      onProgress: onLog,
    );
    final ok = job.images.where((image) => image.ok).toList();
    if (ok.isEmpty) {
      final reason = job.images.isEmpty
          ? '没有返回图片'
          : job.images.first.error ?? '下载失败';
      throw PipelineError(ErrorClass.fatal, '图片生成失败：$reason');
    }
    return DramaMediaResult(
      path: ok.first.path,
      costYuan: job.cost,
      model: found.id,
    );
  }

  @override
  Future<DramaMediaResult> generateI2vClip({
    required String model,
    required String resolution,
    required File firstFrame,
    required String prompt,
    required int durationS,
    required File outFile,
    required void Function(String) onLog,
  }) async {
    final apiKey = cfg.requireApiKey();
    final videoClient = I2vClient(
      apiKey: apiKey,
      client: client,
      host: cfg.apiHost,
      model: model,
      resolution: resolution,
      watermark: cfg.i2vWatermark,
      seed: cfg.i2vSeed,
    );
    final published = await const Base64ImageUrlProvider().publish(firstFrame);
    onLog('提交图生视频任务（${durationS}s）…');
    var task = await videoClient.submit(
      imgUrl: published.url,
      prompt: prompt,
      durationS: durationS,
    );
    final deadline = _now().add(Duration(minutes: cfg.i2vMaxWaitMinutes));
    while (task.status == I2vStatus.running) {
      if (_now().isAfter(deadline)) {
        throw PipelineError(
          ErrorClass.fatal,
          'i2v 超时（${cfg.i2vMaxWaitMinutes} 分钟）',
        );
      }
      await _sleep(Duration(seconds: cfg.i2vPollSeconds));
      task = await videoClient.poll(task.taskId);
    }
    if (task.status == I2vStatus.failed) {
      throw PipelineError(
        ErrorClass.fatal,
        'i2v 失败：${task.errorCode ?? 'unknown'}',
      );
    }
    final url = task.videoUrl;
    if (url == null) {
      throw PipelineError(ErrorClass.fatal, 'i2v 成功但没有视频地址');
    }
    final bytes = await videoClient.downloadClip(url);
    _writeBytes(outFile, bytes);
    onLog('片段已下载：${outFile.path}');
    return DramaMediaResult(
      path: outFile.path,
      costYuan: durationS * pricing.videoPrice(model, resolution),
      model: model,
      durationS: durationS.toDouble(),
    );
  }

  @override
  Future<void> renderLocalClip({
    required File image,
    required File outFile,
    required ShotRoute route,
    required int width,
    required int height,
    required int durationS,
  }) async {
    outFile.parent.createSync(recursive: true);
    final args = route == ShotRoute.micro
        ? microArgsFor(
            img: image,
            durationS: durationS,
            out: outFile,
            width: width,
            height: height,
          )
        : kenBurnsArgsFor(
            img: image,
            durationS: durationS,
            out: outFile,
            width: width,
            height: height,
          );
    await runFfmpeg(args);
    final actual = await mediaDurationSeconds(outFile);
    if ((actual - durationS).abs() > 0.3) {
      throw PipelineError(
        ErrorClass.fatal,
        '本地片段时长异常：期望 ${durationS}s，实际 ${actual.toStringAsFixed(2)}s',
      );
    }
  }

  @override
  Future<void> normalizeClip({
    required File input,
    required File outFile,
    required int width,
    required int height,
  }) async {
    outFile.parent.createSync(recursive: true);
    await runFfmpeg(
      normalizeArgsFor(
        input: input,
        out: outFile,
        width: width,
        height: height,
      ),
    );
  }

  Future<String> _dataUrl(File file) async {
    final bytes = await file.readAsBytes();
    return 'data:${_mimeFor(file.path)};base64,${base64Encode(bytes)}';
  }

  static String _mimeFor(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
    switch (ext) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      default:
        return 'image/jpeg';
    }
  }

  static void _writeBytes(File file, List<int> bytes) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(file.path);
  }
}
