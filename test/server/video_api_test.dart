import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/video_generation.dart';
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
  String? capturedFirstFrame;
  String? capturedRatio;

  setUp(() async {
    capturedFirstFrame = null;
    capturedRatio = null;
    staticDir = Directory.systemTemp.createTempSync('conatus_vid_static');
    File('${staticDir.path}/index.html').writeAsStringSync('<html></html>');
    outDir = Directory.systemTemp.createTempSync('conatus_vid_out');
    server = PipelineServer(
      cfg: _cfg,
      staticDir: staticDir,
      port: 0,
      videosOutputDir: outDir.path,
      videoRunner:
          ({
            required String prompt,
            required String? firstFrameDataUrl,
            required String model,
            required String resolution,
            required String ratio,
            required int durationS,
            required bool audio,
            required String contentId,
            required void Function(String) onProgress,
          }) async {
            capturedFirstFrame = firstFrameDataUrl;
            capturedRatio = ratio;
            final path = '${outDir.path}/$contentId/video.mp4';
            Directory('${outDir.path}/$contentId').createSync(recursive: true);
            File(path).writeAsBytesSync(<int>[1, 2]);
            onProgress('fake');
            return VideoGenResult(
              filePath: path,
              taskId: 't1',
              durationS: durationS,
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

  test('GET /api/models advertises per-model video modes', () async {
    final res = await _get(server.boundPort!, '/api/models');
    expect(res.status, 200);
    final video = ((jsonDecode(res.body) as Map<String, dynamic>)['video']
            as List)
        .cast<Map<String, dynamic>>();
    expect(video, isNotEmpty);
    for (final model in video) {
      expect(model['modes'], isNotEmpty);
    }
    final byId = {for (final model in video) model['id']: model};
    for (final id in <String>['wan3.0-video', 'wan3.0-video-prime']) {
      expect(byId[id]!['modes'], containsAll(<String>['t2v', 'i2v']));
    }
    expect(byId['wan2.6-i2v-flash']!['modes'], ['i2v']);
  });

  test('POST /api/videos then poll and download', () async {
    final created = await _postJson(server.boundPort!, '/api/videos', {
      'model': 'wan3.0-video',
      'prompt': '一只猫',
      'resolution': '720P',
      'ratio': 'adaptive',
      'duration': 5,
      'audio': true,
    });
    expect(created.status, 202);
    final id =
        (jsonDecode(created.body) as Map<String, dynamic>)['id'] as String;

    var status = 'running';
    Map<String, dynamic> body = <String, dynamic>{};
    for (var i = 0; i < 50 && status == 'running'; i++) {
      body =
          jsonDecode((await _get(server.boundPort!, '/api/videos/$id')).body)
              as Map<String, dynamic>;
      status = body['status'] as String;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(status, 'completed');

    final file = await _get(server.boundPort!, '/api/videos/$id/video');
    expect(file.status, 200);
    expect(file.body, isNotEmpty);
  });

  test('i2v requires a first-frame image', () async {
    final res = await _postJson(server.boundPort!, '/api/videos', {
      'model': 'wan3.0-video',
      'mode': 'i2v',
      'prompt': '',
      'duration': 5,
    });
    expect(res.status, 400);
    expect(res.body, contains('首帧图片'));
  });

  test('i2v accepts a first-frame image and pins ratio adaptive', () async {
    const image = 'data:image/png;base64,AAAA';
    final created = await _postJson(server.boundPort!, '/api/videos', {
      'model': 'wan3.0-video',
      'mode': 'i2v',
      'image': image,
      'prompt': '',
      'resolution': '720P',
      'ratio': '16:9',
      'duration': 5,
      'audio': false,
    });
    expect(created.status, 202);
    final id =
        (jsonDecode(created.body) as Map<String, dynamic>)['id'] as String;

    var status = 'running';
    for (var i = 0; i < 50 && status == 'running'; i++) {
      final body =
          jsonDecode((await _get(server.boundPort!, '/api/videos/$id')).body)
              as Map<String, dynamic>;
      status = body['status'] as String;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(status, 'completed');
    expect(capturedFirstFrame, image);
    expect(capturedRatio, 'adaptive');
  });

  test('i2v rejects malformed and oversized first-frame images', () async {
    for (final image in <String>[
      'https://example.com/a.png',
      'data:image/png;base64,@@@',
    ]) {
      final res = await _postJson(server.boundPort!, '/api/videos', {
        'model': 'wan3.0-video',
        'mode': 'i2v',
        'image': image,
        'duration': 5,
      });
      expect(res.status, 400);
    }

    final oversized = 'data:image/png;base64,${'A' * (14 * 1024 * 1024)}';
    final res = await _postJson(server.boundPort!, '/api/videos', {
      'model': 'wan3.0-video',
      'mode': 'i2v',
      'image': oversized,
      'duration': 5,
    });
    expect(res.status, 400);
    expect(res.body, contains('10MB'));
  });

  test('unknown model and out-of-range duration are 400', () async {
    expect(
      (await _postJson(server.boundPort!, '/api/videos', {
        'model': 'no-such-video-model',
        'prompt': 'x',
        'duration': 5,
      })).status,
      400,
    );
    expect(
      (await _postJson(server.boundPort!, '/api/videos', {
        'model': 'wan3.0-video',
        'prompt': 'x',
        'duration': 99,
      })).status,
      400,
    );
  });
}
