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
///
/// Deliberately not a RegExp: the payload can be ~14MB, and the backtracking
/// `[...]+$` form overflows the stack at that size.
bool isValidDataUrl(String value) {
  const prefixes = <String>[
    'data:image/png;base64,',
    'data:image/jpeg;base64,',
    'data:image/jpg;base64,',
    'data:image/webp;base64,',
  ];
  String? payload;
  for (final prefix in prefixes) {
    if (value.startsWith(prefix)) {
      payload = value.substring(prefix.length);
      break;
    }
  }
  if (payload == null || payload.isEmpty) return false;
  for (final code in payload.codeUnits) {
    final ok =
        (code >= 0x30 && code <= 0x39) || // 0-9
        (code >= 0x41 && code <= 0x5a) || // A-Z
        (code >= 0x61 && code <= 0x7a) || // a-z
        code == 0x2b || // +
        code == 0x2f || // /
        code == 0x3d || // =
        code == 0x20 || // space
        code == 0x0a || // LF
        code == 0x0d || // CR
        code == 0x09; // tab
    if (!ok) return false;
  }
  return true;
}

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
    _checkDataUrl(ref, '参考图');
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

/// One independent edit instruction: a prompt, the image being edited, and
/// extra reference images (all `data:image/...;base64,...`).
class ImageEditItem {
  const ImageEditItem({
    required this.prompt,
    required this.image,
    this.refs = const <String>[],
  });

  final String prompt;
  final String image;
  final List<String> refs;
}

/// A batch of independent edit items sharing one model and output settings.
class ImageEditBatch {
  const ImageEditBatch({
    required this.model,
    required this.family,
    required this.items,
    this.size,
    this.seed,
  });

  final String model;
  final ImageFamily family;
  final List<ImageEditItem> items;
  final String? size;
  final int? seed;
}

/// Rejects one edit item the catalog cannot serve, before any paid call.
void validateImageEditItem(ImageEditItem item, ImageModel model) {
  if (!model.modes.contains(ImageMode.i2i)) {
    throw PipelineError(
      ErrorClass.fatal,
      '模型 ${model.id} 不支持图生图/编辑',
    );
  }
  if (item.prompt.trim().isEmpty) {
    throw const PipelineError(ErrorClass.fatal, '第 N 条提示词不能为空');
  }
  _checkDataUrl(item.image, '被编辑的图片');
  if (item.refs.length + 1 > model.maxRefImages) {
    throw PipelineError(
      ErrorClass.fatal,
      '参考图最多 ${model.maxRefImages - 1} 张'
      '（被编辑图片占用 1 个位置，模型 ${model.id}）',
    );
  }
  for (final ref in item.refs) {
    _checkDataUrl(ref, '参考图');
  }
}

/// Rejects a whole edit batch before any paid call: model support, per-item
/// assets and the shared size/seed settings.
void validateImageBatch(ImageEditBatch batch) {
  final model = findImageModel(batch.model);
  if (model == null) {
    throw PipelineError(ErrorClass.fatal, '未知图片模型：${batch.model}');
  }
  if (batch.items.isEmpty) {
    throw const PipelineError(ErrorClass.fatal, '至少需要一条编辑任务');
  }
  for (final item in batch.items) {
    validateImageEditItem(item, model);
    validateImageRequest(
      ImageRequest(
        model: batch.model,
        family: batch.family,
        mode: ImageMode.i2i,
        prompt: item.prompt,
        size: batch.size,
        n: 1,
        seed: batch.seed,
        refImages: <String>[item.image, ...item.refs],
      ),
    );
  }
}

void _checkDataUrl(String value, String what) {
  if (!isValidDataUrl(value)) {
    throw PipelineError(
      ErrorClass.fatal,
      '$what 必须是 data:image/{png,jpeg,webp};base64 格式',
    );
  }
  final payload = value.substring(value.indexOf(',') + 1).replaceAll(
    RegExp(r'\s'),
    '',
  );
  if (payload.length * 3 ~/ 4 > 10 * 1024 * 1024) {
    throw PipelineError(ErrorClass.fatal, '$what 单张不能超过 10MB');
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

  final urls = await _submitAndPoll(
    client: client,
    request: request,
    wait: wait,
    clock: clock,
    emit: emit,
    pollSeconds: pollSeconds,
    maxWaitMinutes: maxWaitMinutes,
  );

  final dir = Directory('$baseDir/$contentId')..createSync(recursive: true);
  final images = <ImageJobImage>[];
  var succeeded = 0;
  for (var i = 0; i < urls.length; i++) {
    final path = '${dir.path}/image-${(i + 1).toString().padLeft(2, '0')}.png';
    try {
      final bytes = await _withRetry(() => client.download(urls[i]), wait);
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


/// Submits one request, polls to a terminal state, and returns the image URLs.
Future<List<Uri>> _submitAndPoll({
  required ImageGenClient client,
  required ImageRequest request,
  required Future<void> Function(Duration) wait,
  required DateTime Function() clock,
  required void Function(String) emit,
  required int pollSeconds,
  required int maxWaitMinutes,
}) async {
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
        '图片任务 ${terminal.taskId} 超时（$maxWaitMinutes 分钟）；'
        '任务可能仍在运行，可在百炼控制台核对后再决定是否重试',
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
  return terminal.imageUrls;
}

/// Runs [items] as independent edit calls, one image each, sequentially.
///
/// A failed item is recorded and does not stop the rest; [ImageJob.cost] only
/// counts images that were generated and downloaded. Files are numbered across
/// the whole batch (`image-01.png`, `image-02.png`, ...).
Future<ImageJob> generateImageEdits({
  required ImageGenClient client,
  required String model,
  required ImageFamily family,
  required List<ImageEditItem> items,
  required String baseDir,
  required String contentId,
  required double unitPrice,
  String? size,
  int? seed,
  int pollSeconds = 5,
  int maxWaitMinutes = 10,
  Future<void> Function(Duration delay)? sleep,
  DateTime Function()? now,
  void Function(String message)? onProgress,
}) async {
  validateImageBatch(
    ImageEditBatch(
      model: model,
      family: family,
      items: items,
      size: size,
      seed: seed,
    ),
  );

  final wait = sleep ?? (Duration d) => Future<void>.delayed(d);
  final clock = now ?? DateTime.now;
  final emit = onProgress ?? (String _) {};

  final images = <ImageJobImage>[];
  var succeeded = 0;
  Directory? dir;

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    final index = i + 1;
    emit('第 $index/${items.length} 条：提交编辑任务…');
    final request = ImageRequest(
      model: model,
      family: family,
      mode: ImageMode.i2i,
      prompt: item.prompt,
      size: size,
      n: 1,
      seed: seed,
      refImages: <String>[item.image, ...item.refs],
    );
    try {
      validateImageRequest(request);
      final urls = await _submitAndPoll(
        client: client,
        request: request,
        wait: wait,
        clock: clock,
        emit: emit,
        pollSeconds: pollSeconds,
        maxWaitMinutes: maxWaitMinutes,
      );
      final bytes = await _withRetry(() => client.download(urls.first), wait);
      dir ??= Directory('$baseDir/$contentId')..createSync(recursive: true);
      final path =
          '${dir.path}/image-${index.toString().padLeft(2, '0')}.png';
      _writeFile(path, bytes);
      images.add(ImageJobImage(index: index, path: path, ok: true));
      succeeded++;
      emit('第 $index/${items.length} 条：完成');
    } on PipelineError catch (e) {
      images.add(
        ImageJobImage(
          index: index,
          path: '',
          ok: false,
          error: e.message,
        ),
      );
      emit('第 $index/${items.length} 条失败：${e.message}');
    }
  }
  emit('完成：$succeeded/${items.length} 张');

  return ImageJob(
    id: contentId,
    model: model,
    mode: ImageMode.i2i,
    n: items.length,
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
