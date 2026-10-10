import 'dart:convert';
import 'dart:io';

import 'package:conatus/conatus.dart';
import 'package:flutter_wanxiang/pipeline/artifacts.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/ffmpeg.dart';
import 'package:flutter_wanxiang/pipeline/monthly_video_tool.dart';
import 'package:flutter_wanxiang/pipeline/orchestrator.dart';
import 'package:flutter_wanxiang/pipeline/state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// One MockClient routing every Bailian call by URL path: LLM chat
/// (classify vs script split by content shape), TTS, i2v submit/poll,
/// clip download, and image upload. Counters make the rerun idempotency
/// contract (zero http calls) observable.
class MockBailian {
  MockBailian({required this.wavBytes, required this.mp4Bytes});

  final List<int> wavBytes;
  final List<int> mp4Bytes;

  int llmCalls = 0;
  int ttsCalls = 0;
  int i2vSubmits = 0;
  int i2vPolls = 0;
  int i2vDownloads = 0;
  int uploads = 0;

  /// Per-photo classify replies, consumed in photo order; the last one
  /// repeats when the queue drains.
  final List<String> classifyReplies = <String>[];

  /// Every TTS `instruction(s)` parameter seen, in request order.
  final List<String> ttsInstructions = <String>[];

  int get totalCalls =>
      llmCalls + ttsCalls + i2vSubmits + i2vPolls + i2vDownloads + uploads;

  http.Client get client => MockClient(_handle);

  Future<http.Response> _handle(http.Request req) async {
    final path = req.url.path;
    if (path.endsWith('/chat/completions')) return _llm(req);
    if (path.contains('/audio/tts')) return _tts(req);
    if (path.contains('video-synthesis')) {
      i2vSubmits++;
      return _json(<String, dynamic>{
        'output': <String, dynamic>{
          'task_id': 'task-$i2vSubmits',
          'task_status': 'PENDING',
        },
      });
    }
    if (path.contains('/api/v1/tasks/')) {
      i2vPolls++;
      final taskId = path.split('/').last;
      return _json(<String, dynamic>{
        'output': <String, dynamic>{
          'task_status': 'SUCCEEDED',
          'video_url': 'http://mock.local/clips/$taskId.mp4',
        },
      });
    }
    if (path.endsWith('/uploads')) {
      uploads++;
      return _json(<String, dynamic>{
        'data': <String, dynamic>{'url': 'https://img.example.com/u.jpg'},
      });
    }
    if (path.startsWith('/clips/')) {
      i2vDownloads++;
      return http.Response.bytes(mp4Bytes, 200);
    }
    return http.Response('no mock route: $path', 500);
  }

  http.Response _json(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  /// Classify requests carry image content parts (user content is a list);
  /// the script request is a plain string prompt carrying `photo=<id>` refs.
  http.Response _llm(http.Request req) {
    llmCalls++;
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final messages = body['messages'] as List<dynamic>;
    final content = (messages[1] as Map<String, dynamic>)['content'];
    if (content is List) return _chatReply(_nextClassifyReply());
    return _chatReply(_scriptReply(content as String));
  }

  String _nextClassifyReply() => classifyReplies.length > 1
      ? classifyReplies.removeAt(0)
      : classifyReplies.first;

  String _scriptReply(String prompt) {
    final ids = RegExp(r'photo=([^\s；]+)')
        .allMatches(prompt)
        .map((m) => m.group(1)!)
        .toList();
    final segments = <Map<String, dynamic>>[
      for (var i = 0; i < ids.length; i++)
        <String, dynamic>{'photo': ids[i], 'line': '这是第${i + 1}段温暖的回忆。'},
    ];
    return jsonEncode(<String, dynamic>{'segments': segments});
  }

  http.Response _chatReply(String content) => _json(<String, dynamic>{
    'choices': <dynamic>[
      <String, dynamic>{
        'message': <String, dynamic>{'content': content},
      },
    ],
  });

  http.Response _tts(http.Request req) {
    ttsCalls++;
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    final input = body['input'] as Map<String, dynamic>;
    // The orchestrator tests run the qwen-audio path (voiceId set below),
    // which carries the dialect instruction inside `input`.
    ttsInstructions.add(input['instruction'] as String);
    return http.Response.bytes(
      List<int>.of(wavBytes),
      200,
      headers: <String, String>{'content-type': 'audio/wav'},
    );
  }
}

const String _personReply =
    '{"has_person": true, "quality": 4, "motion_hint": "", '
    '"caption": "一张合影"}';
const String _sceneReply =
    '{"has_person": false, "quality": 5, "motion_hint": "云缓慢飘动", '
    '"caption": "窗外风景"}';

PipelineConfig makeConfig() => PipelineConfig(
  llmModel: 'qwen3.8-flash',
  ttsModel: 'qwen-audio-3.1-tts-flash',
  ttsFallbackModel: 'qwen3-tts-flash',
  ttsVoiceId: 'voice_test',
  ttsFallbackVoice: 'longxia',
  i2vModel: 'wan2.6-i2v-flash',
  i2vResolution: '720P',
  i2vWatermark: true,
  i2vSeed: 42,
  i2vPollSeconds: 15,
  i2vMaxWaitMinutes: 10,
  ossBucket: 'test-bucket',
  ossEndpoint: 'oss-cn-hangzhou.aliyuncs.com',
  ossPrefix: 'pipeline-exp/',
  targetCount: 4,
  minClipS: 2,
  maxClipS: 15,
  baseUrl: 'http://mock.local/v1',
  env: const <String, String>{'DASHSCOPE_API_KEY': 'test-key'},
);

void main() {
  late Directory tmp;
  late MockBailian mock;
  late List<String> photoPaths;

  Future<File> makePhoto(String name, String size) async {
    final file = File('${tmp.path}/$name.jpg');
    await runFfmpeg([
      '-v', 'error', '-y',
      '-f', 'lavfi',
      '-i', 'testsrc=size=$size:rate=1',
      '-frames:v', '1',
      file.path,
    ]);
    return file;
  }

  /// Real fixtures generated once per test: a 2s sine wav (TTS reply) and a
  /// tiny 320x180 clip (i2v download); images differ in bytes so select's
  /// content-hash dedupe keeps all three.
  Future<void> makeFixtures() async {
    final wav = File('${tmp.path}/fixture.wav');
    await runFfmpeg([
      '-v', 'error', '-y',
      '-f', 'lavfi',
      '-i', 'sine=frequency=440:duration=2',
      wav.path,
    ]);
    final clip = File('${tmp.path}/fixture.mp4');
    await runFfmpeg([
      '-v', 'error', '-y',
      '-f', 'lavfi',
      '-i', 'testsrc=size=320x180:rate=12,format=yuv420p',
      '-t', '1',
      '-c:v', 'libx264',
      '-pix_fmt', 'yuv420p',
      clip.path,
    ]);
    mock = MockBailian(
      wavBytes: wav.readAsBytesSync(),
      mp4Bytes: clip.readAsBytesSync(),
    );
    mock.classifyReplies.addAll(<String>[_personReply, _sceneReply]);
    final photos = <File>[
      await makePhoto('p1', '1600x1000'),
      await makePhoto('p2', '1280x800'),
      await makePhoto('p3', '800x600'),
    ];
    photoPaths = [for (final p in photos) p.path];
    wav.deleteSync();
    clip.deleteSync();
  }

  VivaPipeline makePipeline() =>
      VivaPipeline(cfg: makeConfig(), http: mock.client, baseDir: tmp.path);

  PipelineInput makeInput({String contentId = 't1', bool dryRun = false}) =>
      PipelineInput(
        photos: photoPaths,
        dialect: '河南',
        count: 4,
        contentId: contentId,
        dryRun: dryRun,
      );

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('conatus_orchestrator_test');
    await makeFixtures();
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('full offline pipeline yields final.mp4 + srt with state completed',
      () async {
    final result = await makePipeline().run(makeInput());

    expect(result.status, 'completed', reason: result.error);
    expect(result.segments.length, 3);
    expect(
      result.segments.where((s) => s.route == SegmentState.routeI2v).length,
      2,
    );
    expect(result.estimatedYuan, closeTo(0.6, 1e-9)); // 2 段 × 2s × 0.15

    final work = Workdir(tmp.path, 't1');
    expect(work.file(ArtifactPaths.finalVideo).existsSync(), isTrue);
    expect(work.file(ArtifactPaths.finalSrt).existsSync(), isTrue);
    expect(result.videoPath, work.file(ArtifactPaths.finalVideo).path);

    final reloaded = ContentState.load(work.dir);
    expect(reloaded.step('compose').status, StepStatus.succeeded);
    expect(reloaded.contentId, 't1');
    expect(work.file(ArtifactPaths.meta).existsSync(), isTrue);
  });

  test('rerun skips every step (zero http calls)', () async {
    await makePipeline().run(makeInput());
    final callsBefore = mock.totalCalls;
    expect(callsBefore, greaterThan(0));

    final result = await makePipeline().run(makeInput());

    expect(mock.totalCalls, callsBefore);
    expect(result.status, 'completed', reason: result.error);
    expect(result.segments.length, 3);
  });

  test('dry run stops after tts with cost plan', () async {
    final result = await makePipeline().run(
      makeInput(contentId: 't-dry', dryRun: true),
    );

    expect(result.status, 'dry_run', reason: result.error);
    expect(result.videoPath, isNull);
    expect(mock.ttsCalls, 3);
    expect(mock.i2vSubmits, 0);

    final plan = jsonDecode(result.plan!) as Map<String, dynamic>;
    expect(plan['i2v_segments'], 2);
    expect(plan['kenburns_segments'], 1);
    expect(plan['i2v_seconds'], 4);
    expect(plan['estimated_yuan'], closeTo(0.6, 1e-9));
    expect(result.estimatedYuan, closeTo(0.6, 1e-9));

    final work = Workdir(tmp.path, 't-dry');
    expect(work.exists(ArtifactPaths.renderStatus), isFalse);
    expect(result.segments.every((s) => s.status == 'planned'), isTrue);
  });

  test('tool schema exposes spec params and high risk', () {
    final tool = GenerateMonthlyVideoTool(pipeline: makePipeline());

    expect(tool.name, 'generate_monthly_video');
    expect(tool.riskLevel, ToolRisk.high);

    final schema = tool.toSchema();
    final parameters = schema['parameters'] as Map<String, Object?>;
    final properties = parameters['properties'] as Map<String, Object?>;
    for (final name in <String>[
      'photos', 'dialect', 'count', 'content_id', 'dry_run',
    ]) {
      expect(properties.containsKey(name), isTrue, reason: 'missing $name');
    }
    expect(parameters['required'], containsAll(<String>['photos', 'dialect']));
    final count = properties['count'] as Map<String, Object?>;
    expect(count['type'], 'integer');
    expect(count['default'], 4);
    final dryRun = properties['dry_run'] as Map<String, Object?>;
    expect(dryRun['type'], 'boolean');
    expect(dryRun['default'], false);
    final photos = properties['photos'] as Map<String, Object?>;
    expect(photos['type'], 'array');
  });

  test('dialect unknown region still completes via mandarin', () async {
    final input = PipelineInput(
      photos: photoPaths,
      dialect: 'nowhere',
      count: 4,
      contentId: 't-nowhere',
      dryRun: true,
    );

    final result = await makePipeline().run(input);

    expect(result.status, 'dry_run', reason: result.error);
    expect(mock.ttsCalls, 3);
    for (final instruction in mock.ttsInstructions) {
      expect(instruction, '请用普通话表达。');
    }
  });
}
