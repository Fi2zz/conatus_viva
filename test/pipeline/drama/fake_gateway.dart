import 'dart:async';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/drama/media_gateway.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:flutter_wanxiang/pipeline/render_plan.dart';

/// 测试用媒体网关：写占位文件，不碰网络。
class FakeDramaMediaGateway implements DramaMediaGateway {
  FakeDramaMediaGateway({
    this.imageCost = 0.2,
    this.clipCost = 0.45,
    this.imageGate,
  });

  final double imageCost;
  final double clipCost;

  /// 测试取消：在每次图片生成前等待这个 future。
  final Future<void>? imageGate;

  int imageCalls = 0;
  int clipCalls = 0;
  int localCalls = 0;
  int? failImageCall;
  int? failClipCall;
  int? failLocalCall;
  final List<String> imagePrompts = <String>[];
  bool failAllImages = false;
  bool failAllClips = false;
  bool missingKey = false;

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
    imageCalls += 1;
    imagePrompts.add(prompt);
    if (missingKey) throw ConfigException('DASHSCOPE_API_KEY is not set');
    if (failImageCall == imageCalls) {
      throw PipelineError(ErrorClass.fatal, 'fake image failure');
    }
    if (imageGate != null) await imageGate;
    if (failAllImages) {
      throw PipelineError(ErrorClass.fatal, 'fake image failure');
    }
    final path = '$baseDir/$contentId/image-01.png';
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
    return DramaMediaResult(
      path: path,
      costYuan: imageCost,
      model: model,
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
    clipCalls += 1;
    if (missingKey) throw ConfigException('DASHSCOPE_API_KEY is not set');
    if (failClipCall == clipCalls) {
      throw PipelineError(ErrorClass.fatal, 'fake clip failure');
    }
    if (failAllClips) {
      throw PipelineError(ErrorClass.fatal, 'fake clip failure');
    }
    outFile.parent.createSync(recursive: true);
    outFile.writeAsBytesSync(<int>[4, 5, 6]);
    return DramaMediaResult(
      path: outFile.path,
      costYuan: clipCost,
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
    localCalls += 1;
    if (failLocalCall == localCalls) {
      throw PipelineError(ErrorClass.fatal, 'fake local failure');
    }
    outFile.parent.createSync(recursive: true);
    outFile.writeAsBytesSync(<int>[7, 8, 9]);
  }

  @override
  Future<void> normalizeClip({
    required File input,
    required File outFile,
    required int width,
    required int height,
  }) async {
    outFile.parent.createSync(recursive: true);
    input.copySync(outFile.path);
  }
}
