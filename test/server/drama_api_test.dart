import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/drama/controller.dart';
import 'package:flutter_wanxiang/pipeline/drama/cost.dart';
import 'package:flutter_wanxiang/pipeline/drama/hash.dart';
import 'package:flutter_wanxiang/pipeline/drama/llm.dart';
import 'package:flutter_wanxiang/pipeline/drama/store.dart';
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

class _FakeLlm implements DramaLlm {
  _FakeLlm({this.badDraft = false});

  final bool badDraft;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> chatJson({
    required String system,
    required String user,
  }) async {
    calls += 1;
    if (badDraft) return <String, dynamic>{'shots': 'bad'};
    if (system.contains('拆片')) {
      return <String, dynamic>{
        'logline': '二舅逼债',
        'synopsis': '小满翻出第二张借条',
        'beats': <Object?>[
          <String, Object?>{'id': 'hook', 'label': '钩子', 'summary': '借条拍桌'},
        ],
        'cast_new': <String, Object?>{
          'xiaoman': <String, Object?>{'name': '小满'},
        },
        'cast_updates': <String, Object?>{},
      };
    }
    return <String, dynamic>{
      'title': '堂屋对峙',
      'shots': <Object?>[
        <String, Object?>{
          'id': 's01',
          'kind': 'action',
          'framing': '中景',
          'speaker': 'erniu',
          'line': '',
          'duration_s': 3,
          'priority': 'hook',
          'visual': '借条特写',
        },
      ],
    };
  }
}

typedef _Res = ({int status, String body});

Future<_Res> _send(
  int port,
  String method,
  String path, [
  Map<String, Object?>? body,
]) async {
  final client = HttpClient();
  try {
    final req = await client.open(method, '127.0.0.1', port, path);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return (status: res.statusCode, body: text);
  } finally {
    client.close(force: true);
  }
}

Future<_Res> _get(int port, String path) => _send(port, 'GET', path);
Future<_Res> _post(int port, String path, [Map<String, Object?>? body]) =>
    _send(port, 'POST', path, body);
Future<_Res> _put(int port, String path, Map<String, Object?> body) =>
    _send(port, 'PUT', path, body);

Future<void> _seed(int port) async {
  final series = await _post(port, '/api/drama/series', <String, Object?>{
    'series_id': 'jietiao',
    'title': '借条',
    'dialect': 'henan',
    'planned_episodes': 80,
    'total_budget_yuan': 120,
    'i2v_budget_yuan': 20,
  });
  expect(series.status, 201);
  final episode = await _post(
    port,
    '/api/drama/series/jietiao/episodes',
    <String, Object?>{
      'episode_id': 'ep07',
      'title': '堂屋对峙',
      'number': 7,
    },
  );
  expect(episode.status, 201);
}

void main() {
  late Directory staticDir;
  late Directory root;
  late PipelineServer server;

  Future<PipelineServer> start({
    _FakeLlm? llm,
    Directory? storeRoot,
  }) async {
    final dir = storeRoot ?? Directory.systemTemp.createTempSync('drama_api');
    final controller = DramaController(
      store: DramaStore(rootDir: '${dir.path}/drama'),
      drafts: DramaDraftService(llm: llm ?? _FakeLlm()),
      priceYuanPerSecond: defaultDramaI2vPriceYuanPerSecond(),
    );
    final s = PipelineServer(
      cfg: _cfg,
      staticDir: staticDir,
      port: 0,
      dramaController: controller,
    );
    await s.start();
    return s;
  }

  setUp(() async {
    staticDir = Directory.systemTemp.createTempSync('drama_api_static');
    File('${staticDir.path}/index.html').writeAsStringSync('<html></html>');
    root = Directory.systemTemp.createTempSync('drama_api_root');
    server = await start(storeRoot: root);
  });

  tearDown(() async {
    await server.stop();
    if (staticDir.existsSync()) staticDir.deleteSync(recursive: true);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('create series -> create episode -> bundle has 8 steps', () async {
    final port = server.boundPort!;
    final created = await _post(port, '/api/drama/series', <String, Object?>{
      'series_id': 'jietiao',
      'title': '借条',
      'dialect': 'henan',
      'planned_episodes': 80,
      'total_budget_yuan': 120,
      'i2v_budget_yuan': 20,
    });
    expect(created.status, 201);
    final decodedSeries = jsonDecode(created.body) as Map<String, dynamic>;
    expect(decodedSeries['series']['series_id'], 'jietiao');

    final episode = await _post(
      port,
      '/api/drama/series/jietiao/episodes',
      <String, Object?>{
        'episode_id': 'ep07',
        'title': '堂屋对峙',
        'number': 7,
      },
    );
    expect(episode.status, 201);

    final bundle = await _get(port, '/api/drama/series/jietiao/episodes/ep07');
    expect(bundle.status, 200);
    final decoded = jsonDecode(bundle.body) as Map<String, dynamic>;
    expect(decoded['steps'] as List<Object?>, hasLength(8));
    expect(((decoded['steps'] as List<Object?>).first as Map<String, dynamic>)['key'], 'split');
    expect(decoded['plan'], isNull);
    expect(decoded['capabilities']['cast'], isFalse);

    final list = await _get(port, '/api/drama/series');
    final listed = jsonDecode(list.body) as Map<String, dynamic>;
    expect(((listed['series'] as List<Object?>).first as Map<String, dynamic>)['episode_count'], 1);
  });

  test('save storyboard returns a deterministic plan', () async {
    final port = server.boundPort!;
    await _seed(port);
    final res = await _put(
      port,
      '/api/drama/series/jietiao/episodes/ep07/storyboard',
      <String, Object?>{
        'storyboard': <String, Object?>{
          'content_id': 'ep07',
          'budget_yuan': 20,
          'shots': <Object?>[
            <String, Object?>{'id': 's01', 'kind': 'action', 'duration_s': 3},
            <String, Object?>{'id': 's02', 'kind': 'speak_off', 'line': '还钱。', 'duration_s': 2},
          ],
        },
      },
    );
    expect(res.status, 200);
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final plan = decoded['plan'] as Map<String, dynamic>;
    expect(((plan['shots'] as List<Object?>).first as Map<String, dynamic>)['route'], 'i2v');
    expect((plan['totals'] as Map<String, dynamic>)['i2v_seconds'], 3);
    expect((decoded['state'] as Map<String, dynamic>)['plan_hash'], isNotNull);
  });

  test('invalid id/path is 400 and missing series is 404', () async {
    final port = server.boundPort!;
    expect((await _get(port, '/api/drama/series/bad.id')).status, 400);
    expect((await _get(port, '/api/drama/series/nope')).status, 404);
    expect((await _get(port, '/api/drama/nope')).status, 404);
  });

  test('duplicate create is 409', () async {
    final port = server.boundPort!;
    await _seed(port);
    final again = await _post(port, '/api/drama/series', <String, Object?>{
      'series_id': 'jietiao',
      'title': '借条',
      'dialect': 'henan',
      'planned_episodes': 80,
      'total_budget_yuan': 120,
      'i2v_budget_yuan': 20,
    });
    expect(again.status, 409);
  });

  test('PUT missing series is 404 and does not create it', () async {
    final port = server.boundPort!;
    final res = await _put(port, '/api/drama/series/ghost', <String, Object?>{
      'series': <String, Object?>{'series_id': 'ghost', 'title': '幽灵剧'},
    });
    expect(res.status, 404);
    expect((await _get(port, '/api/drama/series/ghost')).status, 404);
  });

  test('PUT missing episode is 404 and does not create it', () async {
    final port = server.boundPort!;
    await _seed(port);
    final bundle = jsonDecode(
      (await _get(port, '/api/drama/series/jietiao/episodes/ep07')).body,
    ) as Map<String, dynamic>;
    final episode = Map<String, Object?>.from(
      bundle['episode'] as Map<String, dynamic>,
    )..['episode_id'] = 'ep99';
    final res = await _put(
      port,
      '/api/drama/series/jietiao/episodes/ep99',
      <String, Object?>{'episode': episode},
    );
    expect(res.status, 404);
    expect(
      (await _get(port, '/api/drama/series/jietiao/episodes/ep99')).status,
      404,
    );
  });

  test('extract returns a draft and estimate is unpriced', () async {
    final port = server.boundPort!;
    await _seed(port);
    final estimate = await _post(
      port,
      '/api/drama/series/jietiao/episodes/ep07/estimate',
      <String, Object?>{
        'targets': <Object?>['story'],
      },
    );
    expect(estimate.status, 200);
    final estimateBody = jsonDecode(estimate.body) as Map<String, dynamic>;
    expect(estimateBody['unpriced'] as List<Object?>, hasLength(1));
    expect(((estimateBody['unpriced'] as List<Object?>).first as Map<String, dynamic>)['kind'], 'llm');

    final extract = await _post(
      port,
      '/api/drama/series/jietiao/episodes/ep07/story:extract',
    );
    expect(extract.status, 200);
    expect((jsonDecode(extract.body) as Map<String, dynamic>)['logline'], '二舅逼债');

    final withText = await _post(
      port,
      '/api/drama/series/jietiao/episodes/ep07/story:extract',
      <String, Object?>{'text': '新的故事文本'},
    );
    expect(withText.status, 200);
    expect(
      (jsonDecode(withText.body) as Map<String, dynamic>)['source_hash'],
      dramaHash(<String, Object?>{'text': '新的故事文本'}),
    );
  });

  test('unwired step run is 501', () async {
    final port = server.boundPort!;
    await _seed(port);
    final res = await _post(
      port,
      '/api/drama/series/jietiao/episodes/ep07/steps/frame:run',
      <String, Object?>{},
    );
    expect(res.status, 501);
  });

  test('invalid storyboard duration is 400 and does not write a plan', () async {
    final port = server.boundPort!;
    await _seed(port);
    final res = await _put(
      port,
      '/api/drama/series/jietiao/episodes/ep07/storyboard',
      <String, Object?>{
        'storyboard': <String, Object?>{
          'content_id': 'ep07',
          'shots': <Object?>[
            <String, Object?>{'id': 's01', 'kind': 'action', 'duration_s': 0},
          ],
        },
      },
    );
    expect(res.status, 400);
    final bundle = jsonDecode(
      (await _get(port, '/api/drama/series/jietiao/episodes/ep07')).body,
    ) as Map<String, dynamic>;
    expect(bundle['plan'], isNull);
  });

  test('chinese line survives save and read', () async {
    final port = server.boundPort!;
    await _seed(port);
    final res = await _put(
      port,
      '/api/drama/series/jietiao/episodes/ep07/storyboard',
      <String, Object?>{
        'storyboard': <String, Object?>{
          'content_id': 'ep07',
          'shots': <Object?>[
            <String, Object?>{
              'id': 's01',
              'kind': 'speak_off',
              'line': '你欠我的，今天该还了。',
              'duration_s': 3,
            },
          ],
        },
      },
    );
    expect(res.status, 200);
    final bundle = jsonDecode(res.body) as Map<String, dynamic>;
    expect(bundle['storyboard']['shots'][0]['line'], '你欠我的，今天该还了。');
  });

  test('unfixable LLM draft is 422 and does not write', () async {
    final badRoot = Directory.systemTemp.createTempSync('drama_api_bad');
    final bad = await start(llm: _FakeLlm(badDraft: true), storeRoot: badRoot);
    try {
      final port = bad.boundPort!;
      await _seed(port);
      final res = await _post(
        port,
        '/api/drama/series/jietiao/episodes/ep07/storyboard:draft',
        <String, Object?>{},
      );
      expect(res.status, 422);
      final bundle = jsonDecode(
        (await _get(port, '/api/drama/series/jietiao/episodes/ep07')).body,
      ) as Map<String, dynamic>;
      expect(bundle['storyboard'], isNull);
    } finally {
      await bad.stop();
      badRoot.deleteSync(recursive: true);
    }
  });
}
