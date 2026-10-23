import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
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

Future<({int status, String body, String contentType})> _get(
  int port,
  String path,
) async {
  final client = HttpClient();
  try {
    final req = await client.get('127.0.0.1', port, path);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return (
      status: res.statusCode,
      body: body,
      contentType: res.headers.contentType?.mimeType ?? '',
    );
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory staticDir;
  late Directory plansDir;
  late PipelineServer server;

  setUp(() async {
    staticDir = Directory.systemTemp.createTempSync('conatus_plan_static');
    File('${staticDir.path}/index.html').writeAsStringSync('<html></html>');
    plansDir = Directory.systemTemp.createTempSync('conatus_plan_out');
    server = PipelineServer(
      cfg: _cfg,
      staticDir: staticDir,
      port: 0,
      plansDir: plansDir.path,
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    if (staticDir.existsSync()) staticDir.deleteSync(recursive: true);
    if (plansDir.existsSync()) plansDir.deleteSync(recursive: true);
  });

  test('GET /api/short-drama/plans/<id> returns the plan JSON', () async {
    final plan = <String, dynamic>{
      'content_id': 'ep07',
      'title': '借条',
      'frame': <String, dynamic>{'width': 1080, 'height': 1920},
      'shots': <Map<String, dynamic>>[
        <String, dynamic>{
          'shot_id': 's01',
          'framing': 'over_shoulder',
          'speaker': 'erniu',
          'line': '你欠我的，今天该还了。',
          'priority': 'hook',
        },
      ],
    };
    final dir = Directory('${plansDir.path}/ep07');
    dir.createSync(recursive: true);
    File('${dir.path}/07_plan.json')
        .writeAsStringSync('${jsonEncode(plan)}\n');

    final res = await _get(server.boundPort!, '/api/short-drama/plans/ep07');
    expect(res.status, 200);
    expect(res.contentType, 'application/json');
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    expect(decoded['content_id'], 'ep07');
    expect(decoded['title'], '借条');
    final shots = (decoded['shots'] as List).cast<Map<String, dynamic>>();
    expect(shots.first['line'], '你欠我的，今天该还了。');
  });

  test('missing plan returns 404', () async {
    final res = await _get(server.boundPort!, '/api/short-drama/plans/nope');
    expect(res.status, 404);
    expect(jsonDecode(res.body), {'error': 'plan not found'});
  });

  test('invalid content id returns 400', () async {
    final res = await _get(server.boundPort!, '/api/short-drama/plans/bad.id');
    expect(res.status, 400);
    expect(jsonDecode(res.body), {'error': 'invalid content id'});
  });

  test('non-object plan file returns 500', () async {
    final dir = Directory('${plansDir.path}/ep08');
    dir.createSync(recursive: true);
    File('${dir.path}/07_plan.json').writeAsStringSync('[1,2,3]');

    final res = await _get(server.boundPort!, '/api/short-drama/plans/ep08');
    expect(res.status, 500);
    expect(jsonDecode(res.body), {'error': 'invalid plan file'});
  });

  test('trailing slash without id returns 400', () async {
    final res = await _get(server.boundPort!, '/api/short-drama/plans/');
    expect(res.status, 400);
    expect(jsonDecode(res.body), {'error': 'invalid content id'});
  });

  test('plan file with invalid JSON text returns 500', () async {
    final dir = Directory('${plansDir.path}/ep09');
    dir.createSync(recursive: true);
    File('${dir.path}/07_plan.json').writeAsStringSync('{');

    final res = await _get(server.boundPort!, '/api/short-drama/plans/ep09');
    expect(res.status, 500);
    expect(jsonDecode(res.body), {'error': 'invalid plan file'});
  });
}
