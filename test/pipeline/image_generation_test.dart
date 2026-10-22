import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/image_client.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:flutter_wanxiang/pipeline/image_generation.dart';
import 'package:test/test.dart';

ImageRequest _req({int n = 2, List<String> refs = const [], String? size}) =>
    ImageRequest(
      model: 'qwen-image-3.0-pro',
      family: ImageFamily.qwen3,
      mode: refs.isEmpty ? ImageMode.t2i : ImageMode.i2i,
      prompt: '一只猫',
      size: size,
      n: n,
      refImages: refs,
    );

class _FakeClient implements ImageGenClient {
  _FakeClient({
    this.statuses = const [
      ImageTaskStatus.running,
      ImageTaskStatus.succeeded,
    ],
  });

  static const List<String> _urls = ['https://x/1.png', 'https://x/2.png'];

  final List<ImageTaskStatus> statuses;
  int polls = 0;

  @override
  Future<ImageTask> submit(ImageRequest request) async => ImageTask(
    taskId: 't1',
    status: ImageTaskStatus.running,
    imageUrls: const [],
  );

  @override
  Future<ImageTask> poll(String taskId) async {
    final status =
        statuses[polls++ < statuses.length ? polls - 1 : statuses.length - 1];
    return ImageTask(
      taskId: taskId,
      status: status,
      imageUrls: status == ImageTaskStatus.succeeded
          ? _urls.map(Uri.parse).toList()
          : const [],
    );
  }

  @override
  Future<List<int>> download(Uri url) async => [1, 2, 3];
}

class _FailingDownloadClient extends _FakeClient {
  @override
  Future<List<int>> download(Uri url) async {
    if (url.path.endsWith('2.png')) {
      throw const PipelineError(ErrorClass.transient, 'boom');
    }
    return [1, 2, 3];
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('conatus_img_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('submits, polls, downloads and charges per successful image', () async {
    final job = await generateImages(
      client: _FakeClient(),
      request: _req(n: 2),
      baseDir: tmp.path,
      contentId: 'c1',
      unitPrice: 0.5,
      sleep: (_) async {},
      onProgress: (_) {},
    );
    expect(job.cost, 1.0);
    expect(job.images.map((i) => i.ok), [true, true]);
    expect(File('${tmp.path}/c1/image-01.png').existsSync(), isTrue);
    expect(File('${tmp.path}/c1/image-02.png').existsSync(), isTrue);
    expect(File('${tmp.path}/c1/.tmp-image-01.png').existsSync(), isFalse);
  });

  test('a failed download keeps the others and only charges successes', () async {
    final job = await generateImages(
      client: _FailingDownloadClient(),
      request: _req(n: 2),
      baseDir: tmp.path,
      contentId: 'c2',
      unitPrice: 0.5,
      sleep: (_) async {},
    );
    expect(job.cost, 0.5);
    expect(job.images.map((i) => i.ok), [true, false]);
  });

  test('terminal failure throws and writes nothing', () async {
    await expectLater(
      generateImages(
        client: _FakeClient(
          statuses: const [
            ImageTaskStatus.running,
            ImageTaskStatus.failed,
          ],
        ),
        request: _req(),
        baseDir: tmp.path,
        contentId: 'c3',
        unitPrice: 0.5,
        sleep: (_) async {},
      ),
      throwsA(isA<PipelineError>()),
    );
    expect(Directory('${tmp.path}/c3').existsSync(), isFalse);
  });

  test('validation rejects unsupported mode, refs and size before any request', () {
    expect(
      () => validateImageRequest(
        ImageRequest(
          model: 'z-image-turbo',
          family: ImageFamily.zImage,
          mode: ImageMode.i2i,
          prompt: 'x',
          n: 1,
          refImages: const ['data:image/png;base64,AAA'],
        ),
      ),
      throwsA(isA<PipelineError>()),
    );
    expect(
      () => validateImageRequest(
        _req(refs: List.filled(4, 'data:image/png;base64,AAA')),
      ),
      throwsA(isA<PipelineError>()),
    );
    expect(
      () => validateImageRequest(_req(size: '0*0')),
      throwsA(isA<PipelineError>()),
    );
    expect(isValidDataUrl('data:image/png;base64,AAA'), isTrue);
    expect(isValidDataUrl('https://x/a.png'), isFalse);
  });

  test('invalid refs, oversized payloads and bad sizes are rejected locally', () {
    expect(
      () => validateImageRequest(
        _req(refs: const ['https://x/a.png']),
      ),
      throwsA(isA<PipelineError>()),
    );
    final huge =
        'data:image/png;base64,${'A' * (10 * 1024 * 1024 * 4 ~/ 3 + 8)}';
    expect(
      () => validateImageRequest(_req(refs: [huge])),
      throwsA(isA<PipelineError>()),
    );
    expect(
      () => validateImageRequest(_req(size: 'abc')),
      throwsA(isA<PipelineError>()),
    );
    expect(
      () => validateImageRequest(_req(size: '4096*4096')),
      throwsA(isA<PipelineError>()),
    );
    expect(
      () => validateImageRequest(
        ImageRequest(
          model: 'wan2.7-image-pro',
          family: ImageFamily.wan27,
          mode: ImageMode.series,
          prompt: 'x',
          size: '4K',
          n: 2,
          refImages: const [],
        ),
      ),
      throwsA(isA<PipelineError>()),
    );
  });

  test('invalid requests never reach the client', () async {
    final client = _CountingClient();
    await expectLater(
      generateImages(
        client: client,
        request: _req(size: 'abc'),
        baseDir: tmp.path,
        contentId: 'c4',
        unitPrice: 0.5,
        sleep: (_) async {},
      ),
      throwsA(isA<PipelineError>()),
    );
    expect(client.submits, 0);
  });

  test('timeout fails without writing any file', () async {
    final dir = '${tmp.path}/c5';
    var clock = DateTime(2026, 1, 1, 12);
    await expectLater(
      generateImages(
        client: _StuckClient(),
        request: _req(),
        baseDir: tmp.path,
        contentId: 'c5',
        unitPrice: 0.5,
        maxWaitMinutes: 1,
        sleep: (_) async => clock = clock.add(const Duration(seconds: 30)),
        now: () => clock,
      ),
      throwsA(
        isA<PipelineError>().having(
          (e) => e.message,
          'message',
          contains('控制台'),
        ),
      ),
    );
    expect(Directory(dir).existsSync(), isFalse);
  });
}

class _CountingClient extends _FakeClient {
  int submits = 0;

  @override
  Future<ImageTask> submit(ImageRequest request) async {
    submits++;
    return super.submit(request);
  }
}

class _StuckClient extends _FakeClient {
  @override
  Future<ImageTask> poll(String taskId) async => ImageTask(
    taskId: taskId,
    status: ImageTaskStatus.running,
    imageUrls: const [],
  );
}
