import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/dialect_map.dart';
import 'package:flutter_wanxiang/pipeline/ffmpeg.dart';
import 'package:flutter_wanxiang/pipeline/speaker_video.dart';
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

Future<String> _createId(PipelineServer server, String theme) async {
  final created = await _postJson(server.boundPort!, '/api/t2v', {
    'duration': 5,
    'dialect': '河南',
    'theme': theme,
  });
  expect(created.status, 202);
  return (jsonDecode(created.body) as Map<String, dynamic>)['id'] as String;
}

Future<Map<String, dynamic>> _poll(PipelineServer server, String id) async {
  var body = <String, dynamic>{};
  for (var i = 0; i < 50; i++) {
    final poll = await _get(server.boundPort!, '/api/t2v/$id');
    body = jsonDecode(poll.body) as Map<String, dynamic>;
    if (body['status'] != 'running') break;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return body;
}

void main() {
  late Directory staticDir;
  late Directory outDir;
  late File outVideo;
  late PipelineServer server;

  setUp(() async {
    staticDir = Directory.systemTemp.createTempSync('conatus_server_static');
    File(
      '${staticDir.path}/index.html',
    ).writeAsStringSync('<html>frontend</html>');
    File('${staticDir.path}/app.js').writeAsStringSync('console.log(1)');

    outDir = Directory.systemTemp.createTempSync('conatus_server_out');
    outVideo = File('${outDir.path}/video.mp4')
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);

    server = PipelineServer(
      cfg: _cfg,
      staticDir: staticDir,
      port: 0,
      speakerRunner:
          ({
            required String theme,
            required String dialect,
            required int durationS,
            required String contentId,
            required void Function(String) onProgress,
          }) async {
            onProgress('假生成：$theme / $dialect / ${durationS}s');
            return SpeakerVideoResult(
              rawVideoPath: '${outDir.path}/raw.mp4',
              finalVideoPath: outVideo.path,
              durationS: durationS,
              taskId: 't1',
            );
          },
      avatarImage: File('${outDir.path}/avatar.jpg'),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (staticDir.existsSync()) staticDir.deleteSync(recursive: true);
    if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  });

  test('serves index.html for /', () async {
    final res = await _get(server.boundPort!, '/');
    expect(res.status, 200);
    expect(res.body, contains('frontend'));
  });

  test('serves a bundled file with its content type', () async {
    final res = await _get(server.boundPort!, '/app.js');
    expect(res.status, 200);
    expect(res.body, contains('console.log'));
  });

  test('spa routes fall back to index.html', () async {
    final res = await _get(server.boundPort!, '/some/deep/route');
    expect(res.status, 200);
    expect(res.body, contains('frontend'));
  });

  test('a static dir without index.html yields the JSON error page', () async {
    final empty = Directory.systemTemp.createTempSync('conatus_server_empty');
    final bare = PipelineServer(cfg: _cfg, staticDir: empty, port: 0);
    await bare.start();
    try {
      final res = await _get(bare.boundPort!, '/');
      expect(res.status, 404);
      expect(res.body, contains('"error":"not found"'));
    } finally {
      await bare.stop();
      empty.deleteSync(recursive: true);
    }
  });

  test('POST /api/t2v runs and serves the mp4', () async {
    final created = await _postJson(server.boundPort!, '/api/t2v', {
      'duration': 5,
      'dialect': 'henan',
      'theme': '河南美食',
    });
    expect(created.status, 202);
    final id =
        (jsonDecode(created.body) as Map<String, dynamic>)['id'] as String;

    var body = <String, dynamic>{};
    for (var i = 0; i < 50; i++) {
      final poll = await _get(server.boundPort!, '/api/t2v/$id');
      expect(poll.status, 200);
      body = jsonDecode(poll.body) as Map<String, dynamic>;
      if (body['status'] != 'running') break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(body['status'], 'completed');
    expect(body['video_path'], outVideo.path);
    expect(body['logs'], contains(contains('假生成')));

    final video = await _get(server.boundPort!, '/api/t2v/$id/video');
    expect(video.status, 200);
    expect(video.body.length, 4);
  });

  test('rejects empty theme and out-of-range duration', () async {
    final emptyTheme = await _postJson(server.boundPort!, '/api/t2v', {
      'duration': 5,
      'dialect': 'henan',
      'theme': '   ',
    });
    expect(emptyTheme.status, 400);
    expect(emptyTheme.body, contains('theme'));

    final badDuration = await _postJson(server.boundPort!, '/api/t2v', {
      'duration': 99,
      'dialect': 'henan',
      'theme': 'x',
    });
    expect(badDuration.status, 400);
    expect(badDuration.body, contains('duration'));
  });

  test('download of unknown run is 404 JSON', () async {
    final res = await _get(server.boundPort!, '/api/t2v/nope/video');
    expect(res.status, 404);
    expect(res.body, contains('"error"'));
  });

  test('dialects payload carries the t2v price and limits', () async {
    final res = await _get(server.boundPort!, '/api/dialects');
    expect(res.status, 200);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final t2v = data['t2v'] as Map<String, dynamic>;
    expect(t2v['yuan_per_second'], 0.42);
    expect(t2v['duration_min'], 2);
    expect(t2v['duration_max'], 30);
  });

  test('edit-models payload lists the three edit models', () async {
    final res = await _get(server.boundPort!, '/api/edit-models');
    expect(res.status, 200);
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final models = (data['edit_models'] as List).cast<Map<String, dynamic>>();
    expect(models.map((m) => m['id']).toList(), [
      'wan2.7-videoedit',
      'happyhorse-1.0-video-edit',
      'wanx2.1-vace-plus',
    ]);
    expect(models[0]['billing'], 'input_output');
  });

  test('dialect codes resolve to their own instruction (no mandarin fallback)',
      () async {
    final res = await _get(server.boundPort!, '/api/dialects');
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    final dialects = (data['dialects'] as List).cast<Map<String, dynamic>>();
    for (final d in dialects) {
      final code = d['code'] as String;
      expect(
        resolveDialect(code).instruction,
        d['instruction'],
        reason: 'code=$code must resolve to its own dialect',
      );
    }
    final henan = dialects.firstWhere(
      (d) => (d['instruction'] as String).contains('河南'),
    );
    expect(henan['code'], '河南');
    expect(henan['name'], '河南话');
  });

  test('duration 0 / negative / non-number are rejected', () async {
    for (final bad in <Object>[0, -1, 'abc']) {
      final res = await _postJson(server.boundPort!, '/api/t2v', {
        'duration': bad,
        'dialect': '河南',
        'theme': 'x',
      });
      expect(res.status, 400, reason: 'duration=$bad must be rejected');
    }
  });

  test('missing API key yields a failed run with a Chinese message', () async {
    final s = PipelineServer(
      cfg: _cfg,
      staticDir: staticDir,
      port: 0,
      avatarImage: File('${outDir.path}/avatar.jpg'),
    );
    await s.start();
    try {
      final id = await _createId(s, '河南美食');
      final body = await _poll(s, id);
      expect(body['status'], 'failed');
      expect(body['error'], contains('请设置环境变量'));
      expect(body.containsKey('video_path'), isFalse);
    } finally {
      await s.stop();
    }
  });

  test('an overlay failure fails the run with the ffmpeg error', () async {
    final s = PipelineServer(
      cfg: _cfg,
      staticDir: staticDir,
      port: 0,
      avatarImage: File('${outDir.path}/avatar.jpg'),
      speakerRunner:
          ({
            required String theme,
            required String dialect,
            required int durationS,
            required String contentId,
            required void Function(String) onProgress,
          }) async {
            throw const FfmpegException(exitCode: 1, stderr: 'overlay boom');
          },
    );
    await s.start();
    try {
      final id = await _createId(s, '河南美食');
      final body = await _poll(s, id);
      expect(body['status'], 'failed');
      expect(body['error'], contains('overlay boom'));
      expect(body.containsKey('video_path'), isFalse);
    } finally {
      await s.stop();
    }
  });
}
