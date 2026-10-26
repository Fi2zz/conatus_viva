import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/image_client.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:flutter_wanxiang/pipeline/image_generation.dart';
import 'package:flutter_wanxiang/server/pipeline_server.dart';
import 'package:test/test.dart';

final _cfg = PipelineConfig(
  llmModel: 'qwen3.8-flash',
  ttsModel: 'qwen-audio-3.1-tts-flash',
  ttsFallbackModel: 'qwen3-tts-flash',
  ttsVoiceId: null,
  ttsFallbackVoice: 'Cherry',
  i2vModel: 'wan2.6-i2v-flash',
  i2vResolution: '720P',
  i2vWatermark: true,
  i2vSeed: 42,
  i2vPollSeconds: 15,
  i2vMaxWaitMinutes: 10,
  ossBucket: '',
  ossEndpoint: '',
  ossPrefix: 'pipeline-exp/',
  targetCount: 4,
  minClipS: 2,
  maxClipS: 15,
);

Future<({int status, String body})> _get(int port, String path) async {
  final client = HttpClient();
  try {
    final req = await client.get('127.0.0.1', port, path);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return (status: res.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}

Future<({int status, String body})> _postJson(
  int port,
  String path,
  Map<String, dynamic> body,
) async {
  final client = HttpClient();
  try {
    final req = await client.post('127.0.0.1', port, path);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return (status: res.statusCode, body: text);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory staticDir;
  late Directory outDir;
  late PipelineServer server;

  setUp(() async {
    staticDir = Directory.systemTemp.createTempSync('conatus_img_static');
    File('${staticDir.path}/index.html').writeAsStringSync('<html></html>');
    outDir = Directory.systemTemp.createTempSync('conatus_img_out');
    server = PipelineServer(
      cfg: _cfg,
      staticDir: staticDir,
      port: 0,
      imagesOutputDir: outDir.path,
      imageRunner:
          ({
            required ImageRequest request,
            required String contentId,
            required void Function(String) onProgress,
          }) async {
            final path = '${outDir.path}/$contentId/image-01.png';
            Directory('${outDir.path}/$contentId').createSync(recursive: true);
            File(path).writeAsBytesSync(<int>[9, 9]);
            onProgress('fake');
            return ImageJob(
              id: contentId,
              model: request.model,
              mode: request.mode,
              n: request.n,
              images: <ImageJobImage>[
                ImageJobImage(index: 1, path: path, ok: true),
              ],
              cost: 0.5,
            );
          },
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (staticDir.existsSync()) staticDir.deleteSync(recursive: true);
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  });

  test('GET /api/models returns both kinds with merged prices', () async {
    final res = await _get(server.boundPort!, '/api/models');
    expect(res.status, 200);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final image = body['image'] as List<dynamic>;
    expect(image.map((m) => m['id']), contains('qwen-image-3.0-pro'));
    expect((image.first['prices'] as Map).isNotEmpty, isTrue);
    expect(
      (body['video'] as List).map((m) => m['id']),
      contains('wan3.0-video'),
    );
  });

  test('POST /api/images runs a job and serves the file', () async {
    final created = await _postJson(server.boundPort!, '/api/images', {
      'model': 'qwen-image-3.0-pro',
      'mode': 't2i',
      'prompt': '一只猫',
      'n': 1,
    });
    expect(created.status, 202);
    final id =
        (jsonDecode(created.body) as Map<String, dynamic>)['id'] as String;

    var status = 'running';
    Map<String, dynamic> body = <String, dynamic>{};
    for (var i = 0; i < 50 && status == 'running'; i++) {
      body =
          jsonDecode((await _get(server.boundPort!, '/api/images/$id')).body)
              as Map<String, dynamic>;
      status = body['status'] as String;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(status, 'completed');
    expect(body['cost'], 0.5);
    expect((body['results'] as List).single['index'], 1);

    final file = await _get(server.boundPort!, '/api/images/$id/1');
    expect(file.status, 200);
  });

  test('unsupported mode and oversized refs are 400 before any run', () async {
    final bad = await _postJson(server.boundPort!, '/api/images', {
      'model': 'z-image-turbo',
      'mode': 'i2i',
      'prompt': 'x',
      'n': 1,
      'refs': ['data:image/png;base64,AAA'],
    });
    expect(bad.status, 400);
    expect(bad.body, contains('模式'));
    expect(bad.body, contains('t2i'));

    final tooMany = await _postJson(server.boundPort!, '/api/images', {
      'model': 'qwen-image-3.0-pro',
      'mode': 'i2i',
      'prompt': 'x',
      'n': 1,
      'refs': List.filled(4, 'data:image/png;base64,AAA'),
    });
    expect(tooMany.status, 400);
  });

  test('missing model is 400', () async {
    final res = await _postJson(server.boundPort!, '/api/images', {
      'prompt': 'x',
    });
    expect(res.status, 400);
  });

  test('illegal ref and bad size are 400', () async {
    final badRef = await _postJson(server.boundPort!, '/api/images', {
      'model': 'qwen-image-3.0-pro',
      'mode': 'i2i',
      'prompt': 'x',
      'n': 1,
      'refs': ['https://x/a.png'],
    });
    expect(badRef.status, 400);

    final badSize = await _postJson(server.boundPort!, '/api/images', {
      'model': 'qwen-image-3.0-pro',
      'mode': 't2i',
      'prompt': 'x',
      'n': 1,
      'size': 'abc',
    });
    expect(badSize.status, 400);
  });

  test('oversized body is rejected before reading', () async {
    final socket = await Socket.connect('127.0.0.1', server.boundPort!);
    final buffer = StringBuffer();
    final done = Completer<void>();
    socket.listen(
      (data) {
        buffer.write(utf8.decode(data, allowMalformed: true));
        if (!done.isCompleted && buffer.toString().contains('40MB')) {
          done.complete();
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (_) {
        if (!done.isCompleted) done.complete();
      },
    );
    final body = 'x' * (41 * 1024 * 1024);
    socket.add(
      utf8.encode(
        'POST /api/images HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${body.length}\r\n'
        '\r\n'
        '$body',
      ),
    );
    unawaited(socket.flush().catchError((_) {}));
    await done.future.timeout(const Duration(seconds: 10));
    socket.destroy();
    expect(buffer.toString(), contains('400'));
    expect(buffer.toString(), contains('40MB'));
  });

  test('a failed download is reported and not served', () async {
    await server.stop();
    final failing = PipelineServer(
      cfg: _cfg,
      staticDir: staticDir,
      port: 0,
      imagesOutputDir: outDir.path,
      imageRunner:
          ({
            required ImageRequest request,
            required String contentId,
            required void Function(String) onProgress,
          }) async {
            final good = '${outDir.path}/$contentId/image-02.png';
            Directory('${outDir.path}/$contentId').createSync(recursive: true);
            File(good).writeAsBytesSync(<int>[9]);
            return ImageJob(
              id: contentId,
              model: request.model,
              mode: request.mode,
              n: 2,
              images: <ImageJobImage>[
                ImageJobImage(
                  index: 1,
                  path: '${outDir.path}/$contentId/image-01.png',
                  ok: false,
                  error: 'boom',
                ),
                ImageJobImage(index: 2, path: good, ok: true),
              ],
              cost: 0.5,
            );
          },
    );
    await failing.start();
    server = failing;

    final created = await _postJson(server.boundPort!, '/api/images', {
      'model': 'qwen-image-3.0-pro',
      'mode': 't2i',
      'prompt': 'x',
      'n': 2,
    });
    final id =
        (jsonDecode(created.body) as Map<String, dynamic>)['id'] as String;

    var body = <String, dynamic>{};
    for (var i = 0; i < 50; i++) {
      body =
          jsonDecode((await _get(server.boundPort!, '/api/images/$id')).body)
              as Map<String, dynamic>;
      if (body['status'] != 'running') break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final results = body['results'] as List<dynamic>;
    expect(results.length, 2);
    expect(results.first['ok'], isFalse);
    expect(results.last['ok'], isTrue);
    expect(
      (await _get(server.boundPort!, '/api/images/$id/1')).status,
      404,
    );
    expect((await _get(server.boundPort!, '/api/images/$id/2')).status, 200);
  });

  test('POST /api/images with items runs one task per item', () async {
    await server.stop();
    final batch = PipelineServer(
      cfg: _cfg,
      staticDir: staticDir,
      port: 0,
      imagesOutputDir: outDir.path,
      imageEditRunner:
          ({
            required ImageEditBatch batch,
            required String contentId,
            required void Function(String) onProgress,
          }) async {
            Directory('${outDir.path}/$contentId').createSync(recursive: true);
            final results = <ImageJobImage>[];
            for (var i = 0; i < batch.items.length; i++) {
              final path =
                  '${outDir.path}/$contentId/image-0${i + 1}.png';
              if (i == 0) {
                File(path).writeAsBytesSync(<int>[1]);
                results.add(ImageJobImage(index: i + 1, path: path, ok: true));
              } else {
                results.add(
                  ImageJobImage(
                    index: i + 1,
                    path: '',
                    ok: false,
                    error: 'provider exploded',
                  ),
                );
              }
            }
            onProgress('fake batch');
            return ImageJob(
              id: contentId,
              model: batch.model,
              mode: ImageMode.i2i,
              n: batch.items.length,
              images: results,
              cost: 0.5,
            );
          },
    );
    await batch.start();
    server = batch;

    final created = await _postJson(server.boundPort!, '/api/images', {
      'model': 'qwen-image-3.0-pro',
      'mode': 'i2i',
      'items': [
        {'prompt': '第一张', 'image': 'data:image/png;base64,AAA'},
        {'prompt': '第二张', 'image': 'data:image/png;base64,BBB'},
      ],
    });
    expect(created.status, 202);
    final id =
        (jsonDecode(created.body) as Map<String, dynamic>)['id'] as String;

    var body = <String, dynamic>{};
    for (var i = 0; i < 50; i++) {
      body =
          jsonDecode((await _get(server.boundPort!, '/api/images/$id')).body)
              as Map<String, dynamic>;
      if (body['status'] != 'running') break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final results = body['results'] as List<dynamic>;
    expect(results.length, 2);
    expect(results.first['ok'], isTrue);
    expect(results.last['ok'], isFalse);
    expect(body['cost'], 0.5);
  });

  test('batch item without an image is 400', () async {
    final res = await _postJson(server.boundPort!, '/api/images', {
      'model': 'qwen-image-3.0-pro',
      'mode': 'i2i',
      'items': [
        {'prompt': '缺少图片'},
      ],
    });
    expect(res.status, 400);
  });
}
