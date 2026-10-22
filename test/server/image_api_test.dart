import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/image_client.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/image_generation.dart';
import 'package:flutter_wanxiang/server/pipeline_server.dart';
import 'package:test/test.dart';

const _cfg = PipelineConfig(
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
}
