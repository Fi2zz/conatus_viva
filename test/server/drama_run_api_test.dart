import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/drama/controller.dart';
import 'package:flutter_wanxiang/pipeline/drama/cost.dart';
import 'package:flutter_wanxiang/pipeline/drama/episode.dart';
import 'package:flutter_wanxiang/pipeline/drama/llm.dart';
import 'package:flutter_wanxiang/pipeline/drama/media_gateway.dart';
import 'package:flutter_wanxiang/pipeline/drama/pricing.dart';
import 'package:flutter_wanxiang/pipeline/drama/runner.dart';
import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/drama/store.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:flutter_wanxiang/server/pipeline_server.dart';
import 'package:test/test.dart';

import '../pipeline/drama/fake_gateway.dart';

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

DramaPricing _pricing() => DramaPricing(
  i2vYuanPerSecond: 0.15,
  imagePrice: (_, _) => 0.2,
  videoPrice: (_, _) => 0.15,
);

DramaSeries _series({String id = 'jietiao', double totalBudget = 120}) =>
    DramaSeries.create(
      seriesId: id,
      title: '借条',
      totalBudgetYuan: totalBudget,
      cast: <String, DramaCastMember>{
        'erniu': const DramaCastMember(
          castId: 'erniu',
          name: '二舅',
          description: '五十岁',
        ),
      },
    );

Storyboard _board() => Storyboard.fromJson(<String, Object?>{
  'content_id': 'ep07',
  'cast': <String, Object?>{'erniu': <String, Object?>{'name': '二舅'}},
  'shots': <Object?>[
    <String, Object?>{
      'id': 's01',
      'kind': 'action',
      'speaker': 'erniu',
      'line': '还钱。',
      'duration_s': 3,
      'priority': 'hook',
      'visual': '借条特写',
    },
    <String, Object?>{
      'id': 's02',
      'kind': 'establishing',
      'line': '',
      'duration_s': 2,
      'priority': 'normal',
      'visual': '院门口',
    },
  ],
});

Future<void> _seed(
  DramaStore store, {
  String id = 'jietiao',
  double totalBudget = 120,
}) async {
  final series = _series(id: id, totalBudget: totalBudget);
  store.createSeries(series);
  final episode = DramaEpisode.create(
    series: series,
    episodeId: 'ep07',
    title: '堂屋对峙',
  );
  store.createEpisode(episode);
  final board = _board();
  store.writeStoryboard(id, 'ep07', board);
  final plan = buildDramaPlan(
    storyboard: board,
    episode: episode,
    priceYuanPerSecond: 0.15,
  );
  store.writePlanJson(id, 'ep07', plan.toJson());
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

Future<Map<String, dynamic>> _pollRun(int port, String runId) async {
  for (var i = 0; i < 50; i++) {
    final res = await _send(
      port,
      'GET',
      '/api/drama/series/jietiao/episodes/ep07/runs/$runId',
    );
    if (res.status != 200) throw StateError('run poll ${res.status}: ${res.body}');
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    if (body['status'] != 'running') return body;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('run did not finish');
}

void main() {
  late Directory temp;
  late Directory staticDir;
  late DramaStore store;
  late PipelineServer server;
  late int port;

  Future<PipelineServer> start({DramaMediaGateway? gateway}) async {
    final controller = DramaController(
      store: store,
      drafts: DramaDraftService(llm: _NoopLlm()),
      priceYuanPerSecond: 0.15,
      pricing: _pricing(),
      runner: DramaRunner(
        store: store,
        gateway: gateway ?? FakeDramaMediaGateway(),
      ),
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
    temp = Directory.systemTemp.createTempSync('drama_run_api');
    staticDir = Directory.systemTemp.createTempSync('drama_run_static');
    File('${staticDir.path}/index.html').writeAsStringSync('<html></html>');
    store = DramaStore(rootDir: '${temp.path}/drama');
    await _seed(store);
    server = await start();
    port = server.boundPort!;
  });

  tearDown(() async {
    await server.stop();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
    if (staticDir.existsSync()) staticDir.deleteSync(recursive: true);
  });

  test('frame run returns 202, completes, and serves the frame asset', () async {
    final start = await _send(
      port,
      'POST',
      '/api/drama/series/jietiao/episodes/ep07/steps/frame:run',
      <String, Object?>{'target': 'all'},
    );
    expect(start.status, 202);
    final runId = (jsonDecode(start.body) as Map<String, dynamic>)['run_id'];
    final run = await _pollRun(port, runId as String);
    expect(run['status'], 'completed');
    expect(
      (run['items'] as List<Object?>).map((item) => (item as Map)['kind']),
      containsAll(<String>['frame', 'clip', 't2v']),
    );

    final bundle = await _send(
      port,
      'GET',
      '/api/drama/series/jietiao/episodes/ep07',
    );
    final decoded = jsonDecode(bundle.body) as Map<String, dynamic>;
    final path =
        ((decoded['state'] as Map<String, dynamic>)['shots']
                as Map<String, dynamic>)['s01']['frame']['path']
            as String;
    final asset = await _send(
      port,
      'GET',
      '/api/drama/series/jietiao/episodes/ep07/assets/${path.substring('assets/'.length)}',
    );
    expect(asset.status, 200);
  });

  test('estimate uses the new step format and returns i2v budget', () async {
    final res = await _send(
      port,
      'POST',
      '/api/drama/series/jietiao/episodes/ep07/estimate',
      <String, Object?>{'step': 'frame', 'target': 'all'},
    );
    expect(res.status, 200);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final items = body['items'] as List<Object?>;
    expect(items, isNotEmpty);
    expect(
      items.where((item) => (item as Map<String, dynamic>)['kind'] == 't2v'),
      isNotEmpty,
    );
    expect(body['i2v_estimated_yuan'], closeTo(0.45, 0.001));
    expect((body['budget'] as Map<String, dynamic>)['i2v_total_yuan'], 20);
  });

  test('edit run writes out/final.mp4 and final.srt', () async {
    for (final step in <String>['frame', 'voice', 'edit', 'pack']) {
      final res = await _send(
        port,
        'POST',
        '/api/drama/series/jietiao/episodes/ep07/steps/$step:run',
        <String, Object?>{'target': 'all'},
      );
      expect(res.status, 202, reason: step);
      final runId = (jsonDecode(res.body) as Map<String, dynamic>)['run_id'];
      final run = await _pollRun(port, runId as String);
      expect(run['status'], 'completed', reason: step);
    }
    final video = await _send(
      port,
      'GET',
      '/api/drama/series/jietiao/episodes/ep07/out/final.mp4',
    );
    expect(video.status, 200);
    final srt = await _send(
      port,
      'GET',
      '/api/drama/series/jietiao/episodes/ep07/out/final.srt',
    );
    expect(srt.status, 200);
    expect(srt.body, contains('还钱。'));
    final pkg = await _send(
      port,
      'GET',
      '/api/drama/series/jietiao/episodes/ep07/out/package.json',
    );
    expect(pkg.status, 200);
    expect(pkg.body, contains('final.mp4'));
  });

  test('voice run and audio reconcile work end to end', () async {
    final voice = await _send(
      port,
      'POST',
      '/api/drama/series/jietiao/episodes/ep07/steps/voice:run',
      <String, Object?>{},
    );
    expect(voice.status, 202);
    final runId = (jsonDecode(voice.body) as Map<String, dynamic>)['run_id'];
    final run = await _pollRun(port, runId as String);
    expect(run['status'], 'completed');

    final preview = await _send(
      port,
      'POST',
      '/api/drama/series/jietiao/episodes/ep07/audio:reconcile',
      <String, Object?>{'apply': false},
    );
    expect(preview.status, 200);
    final previewBody = jsonDecode(preview.body) as Map<String, dynamic>;
    expect(previewBody['applied'], isFalse);
    final changes = previewBody['changes'] as List<Object?>;
    expect(changes, isNotEmpty);
    expect((changes.first as Map<String, dynamic>)['shot_id'], 's01');

    final applied = await _send(
      port,
      'POST',
      '/api/drama/series/jietiao/episodes/ep07/audio:reconcile',
      <String, Object?>{'apply': true},
    );
    expect(applied.status, 200);
    final appliedBody = jsonDecode(applied.body) as Map<String, dynamic>;
    expect(appliedBody['applied'], isTrue);
    final bundle = appliedBody['bundle'] as Map<String, dynamic>;
    final shots = (bundle['storyboard'] as Map<String, dynamic>)['shots']
        as List<Object?>;
    final s01 = shots.firstWhere(
      (item) => (item as Map<String, dynamic>)['id'] == 's01',
    ) as Map<String, dynamic>;
    expect(s01['duration_s'], 2.5);
    final missing = await _send(
      port,
      'GET',
      '/api/drama/series/jietiao/episodes/ep07/runs/ghost',
    );
    expect(missing.status, 404);
  });

  test('asset path escape is 400', () async {
    final res = await _send(
      port,
      'GET',
      '/api/drama/series/jietiao/episodes/ep07/assets/..%2Fstate.json',
    );
    expect(res.status, 400);
  });

  test('over-budget frame run is 409 and creates no run', () async {
    await server.stop();
    final lowStore = DramaStore(rootDir: '${temp.path}/low');
    await _seed(lowStore, id: 'low', totalBudget: 0.01);
    // 用低预算剧替换 server 的 store。
    store = lowStore;
    server = await start();
    port = server.boundPort!;
    final res = await _send(
      port,
      'POST',
      '/api/drama/series/low/episodes/ep07/steps/frame:run',
      <String, Object?>{'target': 'frame'},
    );
    expect(res.status, 409);
    expect((jsonDecode(res.body) as Map<String, dynamic>)['code'], 'budget_exceeded');
  });

  test('read/cancel a run from another episode is 404', () async {
    final start = await _send(
      port,
      'POST',
      '/api/drama/series/jietiao/episodes/ep07/steps/frame:run',
      <String, Object?>{'target': 'frame'},
    );
    expect(start.status, 202);
    final runId = (jsonDecode(start.body) as Map<String, dynamic>)['run_id'];
    final wrongRead = await _send(
      port,
      'GET',
      '/api/drama/series/other/episodes/ep07/runs/$runId',
    );
    expect(wrongRead.status, 404);
    final wrongCancel = await _send(
      port,
      'POST',
      '/api/drama/series/other/episodes/ep07/runs/$runId:cancel',
      <String, Object?>{},
    );
    expect(wrongCancel.status, 404);
  });

  test('second concurrent run is 409 episode_busy', () async {
    await server.stop();
    final gate = Completer<void>();
    server = await start(gateway: FakeDramaMediaGateway(imageGate: gate.future));
    port = server.boundPort!;
    final first = await _send(
      port,
      'POST',
      '/api/drama/series/jietiao/episodes/ep07/steps/frame:run',
      <String, Object?>{'target': 'frame'},
    );
    expect(first.status, 202);
    final second = await _send(
      port,
      'POST',
      '/api/drama/series/jietiao/episodes/ep07/steps/frame:run',
      <String, Object?>{'target': 'frame'},
    );
    expect(second.status, 409);
    expect((jsonDecode(second.body) as Map<String, dynamic>)['code'], 'episode_busy');
    gate.complete();
  });
}

class _NoopLlm implements DramaLlm {
  @override
  Future<Map<String, dynamic>> chatJson({
    required String system,
    required String user,
  }) async => <String, dynamic>{};
}
