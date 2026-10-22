import 'dart:io';

import 'bailian/image_client.dart';
import 'errors.dart';
import 'generation_models.dart';

/// One image in a finished job; [ok] is false when its download failed.
class ImageJobImage {
  const ImageJobImage({
    required this.index,
    required this.path,
    required this.ok,
    this.error,
  });

  final int index;
  final String path;
  final bool ok;
  final String? error;
}

/// Outcome of one image-generation run.
class ImageJob {
  const ImageJob({
    required this.id,
    required this.model,
    required this.mode,
    required this.n,
    required this.images,
    required this.cost,
  });

  final String id;
  final String model;
  final ImageMode mode;
  final int n;
  final List<ImageJobImage> images;

  /// Only successful images are billed.
  final double cost;
}

const List<Duration> _retryDelays = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
];

/// `data:image/(png|jpeg|webp);base64,<payload>`.
final RegExp _dataUrl = RegExp(
  r'^data:image/(png|jpeg|jpg|webp);base64,[A-Za-z0-9+/=\s]+$',
);

/// True when [value] is an accepted inline image.
bool isValidDataUrl(String value) => _dataUrl.hasMatch(value);

/// Rejects a request the catalog cannot serve, before any paid call.
///
/// Throws [PipelineError] with [ErrorClass.fatal]; the server maps it to 400.
void validateImageRequest(ImageRequest request) {
  final model = findImageModel(request.model);
  if (model == null) {
    throw PipelineError(ErrorClass.fatal, '未知图片模型：${request.model}');
  }
  if (!model.modes.contains(request.mode)) {
    final supported = model.modes.map((m) => m.name).join('/');
    throw PipelineError(
      ErrorClass.fatal,
      '模型 ${model.id} 不支持模式 ${request.mode.name}（支持：$supported）',
    );
  }
  if (request.prompt.trim().isEmpty) {
    throw const PipelineError(ErrorClass.fatal, 'prompt 不能为空');
  }

  final maxImages = request.mode == ImageMode.series ? 12 : model.maxImages;
  if (request.n < 1 || request.n > maxImages) {
    throw PipelineError(
      ErrorClass.fatal,
      '张数需在 1..$maxImages（模型 ${model.id}）',
    );
  }

  if (request.refImages.length > model.maxRefImages) {
    throw PipelineError(
      ErrorClass.fatal,
      '参考图最多 ${model.maxRefImages} 张（模型 ${model.id}）',
    );
  }
  if (request.mode == ImageMode.i2i && request.refImages.isEmpty) {
    throw const PipelineError(ErrorClass.fatal, '图生图至少需要 1 张参考图');
  }
  for (final ref in request.refImages) {
    if (!isValidDataUrl(ref)) {
      throw const PipelineError(
        ErrorClass.fatal,
        '参考图必须是 data:image/{png,jpeg,webp};base64 格式',
      );
    }
    final payload = ref.substring(ref.indexOf(',') + 1).replaceAll(
      RegExp(r'\s'),
      '',
    );
    if (payload.length * 3 ~/ 4 > 10 * 1024 * 1024) {
      throw const PipelineError(ErrorClass.fatal, '参考图单张不能超过 10MB');
    }
  }

  _validateSize(request, model);
}

void _validateSize(ImageRequest request, ImageModel model) {
  final size = request.size;
  if (size == null || size.isEmpty) return;

  const tiers = <String>{'1K', '2K', '4K'};
  if (tiers.contains(size)) {
    final allowedTiers = model.family == ImageFamily.wan27
        ? (model.id.endsWith('-pro') && request.mode == ImageMode.t2i
              ? const <String>{'1K', '2K', '4K'}
              : const <String>{'1K', '2K'})
        : const <String>{'1K', '2K'};
    if (!allowedTiers.contains(size)) {
      throw PipelineError(
        ErrorClass.fatal,
        '模型 ${model.id} 在 ${request.mode.name} 模式下不支持 $size',
      );
    }
    return;
  }

  final parts = size.split('*');
  final width = parts.length == 2 ? int.tryParse(parts[0]) : null;
  final height = parts.length == 2 ? int.tryParse(parts[1]) : null;
  if (width == null || height == null || width < 512 || height < 512) {
    throw PipelineError(ErrorClass.fatal, '非法尺寸：$size（格式 宽*高，最小 512*512）');
  }
  final maxArea = model.family == ImageFamily.wan27 &&
          model.id.endsWith('-pro') &&
          request.mode == ImageMode.t2i
      ? 4096 * 4096
      : 2048 * 2048;
  if (width * height > maxArea) {
    throw PipelineError(ErrorClass.fatal, '尺寸 $size 超出模型 ${model.id} 的上限');
  }
}

/// Drives one image task end to end: submit, poll, download every image.
///
/// Files land in `<baseDir>/<contentId>/image-XX.png` through a `.tmp` rename,
/// and only after the task succeeds, so a failed or timed-out run leaves no
/// half-written files. A failed single download keeps the rest and is excluded
/// from [ImageJob.cost].
Future<ImageJob> generateImages({
  required ImageGenClient client,
  required ImageRequest request,
  required String baseDir,
  required String contentId,
  required double unitPrice,
  int pollSeconds = 5,
  int maxWaitMinutes = 10,
  Future<void> Function(Duration delay)? sleep,
  DateTime Function()? now,
  void Function(String message)? onProgress,
}) async {
  validateImageRequest(request);

  final wait = sleep ?? (Duration d) => Future<void>.delayed(d);
  final clock = now ?? DateTime.now;
  final emit = onProgress ?? (String _) {};

  emit('提交图片任务（${request.model}，${request.mode.name}，n=${request.n}）…');
  final submitted = await _withRetry(() => client.submit(request), wait);
  emit('任务 ${submitted.taskId} 已提交，等待生成');

  final startedAt = clock();
  final deadline = startedAt.add(Duration(minutes: maxWaitMinutes));
  ImageTask terminal = submitted;
  while (terminal.status == ImageTaskStatus.running) {
    if (clock().isAfter(deadline)) {
      throw PipelineError(
        ErrorClass.fatal,
        '图片任务 ${terminal.taskId} 超时（$maxWaitMinutes 分钟）',
      );
    }
    await wait(Duration(seconds: pollSeconds));
    terminal = await _withRetry(() => client.poll(terminal.taskId), wait);
    emit('生成中（${terminal.status.name}）…');
  }
  if (terminal.status == ImageTaskStatus.failed) {
    throw PipelineError(
      ErrorClass.transient,
      '图片任务 ${terminal.taskId} 失败：${terminal.errorCode ?? 'unknown'}',
    );
  }
  if (terminal.imageUrls.isEmpty) {
    throw PipelineError(
      ErrorClass.transient,
      '图片任务 ${terminal.taskId} 成功但没有返回图片',
    );
  }

  final dir = Directory('$baseDir/$contentId')..createSync(recursive: true);
  final images = <ImageJobImage>[];
  var succeeded = 0;
  for (var i = 0; i < terminal.imageUrls.length; i++) {
    final path = '${dir.path}/image-${(i + 1).toString().padLeft(2, '0')}.png';
    try {
      final bytes = await _withRetry(
        () => client.download(terminal.imageUrls[i]),
        wait,
      );
      _writeFile(path, bytes);
      images.add(ImageJobImage(index: i + 1, path: path, ok: true));
      succeeded++;
    } on PipelineError catch (e) {
      images.add(
        ImageJobImage(index: i + 1, path: path, ok: false, error: e.message),
      );
      emit('第 ${i + 1} 张下载失败：${e.message}');
    }
  }
  emit('完成：$succeeded/${images.length} 张');

  return ImageJob(
    id: contentId,
    model: request.model,
    mode: request.mode,
    n: request.n,
    images: images,
    cost: unitPrice * succeeded,
  );
}

Future<T> _withRetry<T>(
  Future<T> Function() action,
  Future<void> Function(Duration) wait,
) async {
  for (var failures = 0; ; ) {
    try {
      return await action();
    } on PipelineError catch (e) {
      if (e.cls != ErrorClass.transient || failures >= _retryDelays.length) {
        rethrow;
      }
      await wait(_retryDelays[failures]);
      failures++;
    }
  }
}

void _writeFile(String path, List<int> bytes) {
  final tmp = File('${File(path).parent.path}/.tmp-${path.split('/').last}');
  try {
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(path);
  } on FileSystemException catch (e) {
    throw PipelineError(ErrorClass.fatal, 'cannot write $path: $e');
  } finally {
    if (tmp.existsSync()) tmp.deleteSync();
  }
}
