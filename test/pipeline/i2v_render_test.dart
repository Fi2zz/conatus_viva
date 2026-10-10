import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/artifacts.dart';
import 'package:flutter_wanxiang/pipeline/bailian/i2v.dart';
import 'package:flutter_wanxiang/pipeline/bailian/tts.dart';
import 'package:flutter_wanxiang/pipeline/bailian/uploader.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/ffmpeg.dart';
import 'package:flutter_wanxiang/pipeline/state.dart';
import 'package:flutter_wanxiang/pipeline/steps/classify.dart';
import 'package:flutter_wanxiang/pipeline/steps/render.dart';
import 'package:flutter_wanxiang/pipeline/steps/script.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// DashScope async-task mock: counts submits / polls / clip downloads and
/// serves queued poll replies (the last one repeats).
class MockI2v {
  int submits = 0;
  int polls = 0;
  int downloads = 0;
  http.Request? lastSubmit;
  List<int> videoBytes = <int>[];
  http.Response submitResponse = http.Response('unset', 500);
  final List<http.Response> pollQueue = <http.Response>[];

  http.Client get client => MockClient(_onRequest);

  Future<http.Response> _onRequest(http.Request req) async {
    if (req.method == 'POST') {
      submits++;
      lastSubmit = req;
      return submitResponse;
    }
    if (req.url.path.startsWith('/api/v1/tasks/')) {
      polls++;
      return pollQueue.length > 1 ? pollQueue.removeAt(0) : pollQueue.first;
    }
    downloads++;
    return http.Response.bytes(videoBytes, 200);
  }
}

class FakeUrls implements ImageUrlProvider {
  int calls = 0;

  @override
  String get name => 'fake';

  @override
  Future<ImageUrl> publish(File photo) async {
    calls++;
    return ImageUrl(
      url: 'https://img.example.com/published.jpg',
      expiresAt: DateTime.now().add(kPublishedUrlLifetime),
    );
  }
}

http.Response submitOk(String taskId) => http.Response(
  jsonEncode(<String, dynamic>{
    'output': <String, dynamic>{'task_id': taskId, 'task_status': 'PENDING'},
  }),
  200,
);

http.Response pollRes(String status, {String? videoUrl, String? code}) =>
    http.Response(
      jsonEncode(<String, dynamic>{
        'output': <String, dynamic>{
          'task_status': status,
          'video_url': ?videoUrl,
          'code': ?code,
        },
      }),
      200,
    );

PipelineConfig makeConfig() => PipelineConfig(
  llmModel: 'qwen3.8-flash',
  ttsModel: 'qwen-audio-3.1-tts-flash',
  ttsFallbackModel: 'qwen3-tts-flash',
  ttsVoiceId: null,
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
  env: const <String, String>{'DASHSCOPE_API_KEY': 'test-key'},
);

void main() {
  late Directory tmp;
  late Workdir work;

  /// Real fixture photo under `00_inputs/` so the render step can resolve
  /// `<id>.jpg` for Ken Burns and for the i2v URL publish.
  Future<File> placePhoto(String id) async {
    final dir = work.dirOf(ArtifactPaths.inputsDir)
      ..createSync(recursive: true);
    final img = File('${dir.path}/$id.jpg');
    await runFfmpeg([
      '-v', 'error', '-y',
      '-f', 'lavfi',
      '-i', 'testsrc=size=1600x1000:rate=1',
      '-frames:v', '1',
      img.path,
    ]);
    return img;
  }

  Future<void> runRender({
    required ContentState state,
    required MockI2v mock,
    required FakeUrls urls,
    bool person = false,
    double audioSeconds = 3.2,
  }) {
    return runRenderStep(
      scripts: <SegmentScript>[
        SegmentScript(
          photoId: '001_scene',
          line: '这一段台词',
          motionPrompt: person ? null : '背景光影微动',
        ),
      ],
      audios: <TtsAudio>[
        TtsAudio(wav: File('${tmp.path}/seg_0.wav'), seconds: audioSeconds),
      ],
      photos: <PhotoInfo>[
        PhotoInfo(
          id: '001_scene',
          hasPerson: person,
          quality: 5,
          motionHint: '',
          caption: '',
          personUnknown: false,
        ),
      ],
      work: work,
      state: state,
      i2v: I2vClient(apiKey: 'test-key', client: mock.client),
      urls: urls,
      cfg: makeConfig(),
      sleep: (_) async {},
    );
  }

  /// `width,height,avg_frame_rate` of the first video stream.
  Future<String> probeVideo(File f) async {
    final r = await Process.run('ffprobe', [
      '-v', 'quiet',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=width,height,avg_frame_rate',
      '-of', 'csv=p=0',
      f.path,
    ]);
    return (r.stdout as String).trim();
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_i2v_render_test');
    work = Workdir(tmp.path, 'content');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// Tiny real clip (320x180 @ 12fps) served as the i2v download, so the
  /// post-render normalization to 1280x720/24fps is observable with ffprobe.
  /// Generated with the local ffmpeg inside the test temp dir, never
  /// committed.
  Future<List<int>> makeVideoBytes() async {
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
    return clip.readAsBytesSync();
  }

  test('submit body pins 720P audio=false duration watermark seed', () async {
    final mock = MockI2v()..submitResponse = submitOk('task-1');
    final client = I2vClient(apiKey: 'test-key', client: mock.client);

    final task = await client.submit(
      imgUrl: 'https://img.example.com/a.jpg',
      prompt: '云在动',
      durationS: 5,
    );

    expect(task.taskId, 'task-1');
    expect(task.status, I2vStatus.running);

    final req = mock.lastSubmit!;
    expect(
      req.url.toString(),
      'https://dashscope.aliyuncs.com/api/v1/services/aigc/'
      'video-generation/video-synthesis',
    );
    expect(req.headers['X-DashScope-Async'], 'enable');
    expect(req.headers['Authorization'], 'Bearer test-key');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(body['model'], 'wan2.6-i2v-flash');
    expect(body['input'], <String, dynamic>{
      'img_url': 'https://img.example.com/a.jpg',
      'prompt': '云在动',
    });
    expect(body['parameters'], <String, dynamic>{
      'resolution': '720P',
      'duration': 5,
      'audio': false,
      'prompt_extend': true,
      'shot_type': 'multi',
      'watermark': true,
      'seed': 42,
    });
  });

  test('person segment never calls submit (kenBurns only)', () async {
    await placePhoto('001_scene');
    final mock = MockI2v();
    final urls = FakeUrls();
    final state = ContentState.load(work.dir);

    await runRender(state: state, mock: mock, urls: urls, person: true);

    expect(mock.submits, 0);
    expect(mock.polls, 0);
    expect(mock.downloads, 0);
    expect(urls.calls, 0);

    final clip = work.file('${ArtifactPaths.clipsDir}/seg_0.mp4');
    expect(clip.existsSync(), isTrue);
    expect(await mediaDurationSeconds(clip), closeTo(4, 0.5));
    expect(await probeVideo(clip), '1280,720,24/1');

    final seg = state.segments.single;
    expect(seg.route, SegmentState.routeKenburns);
    expect(seg.status, SegmentStatus.succeeded);
    expect(seg.durationS, 4); // ceil(3.2) clamped into [2, 15]
    expect(seg.costSeconds, 0);
    expect(state.cost.i2vSecondsTotal, 0);
  });

  test('resume polls existing task_id without resubmitting', () async {
    await placePhoto('001_scene');
    final mock = MockI2v();
    mock.videoBytes = await makeVideoBytes();
    mock.pollQueue.addAll(<http.Response>[
      pollRes('RUNNING'),
      pollRes('SUCCEEDED', videoUrl: 'https://video.example.com/v.mp4'),
    ]);
    final urls = FakeUrls();
    final state = ContentState.load(work.dir);
    state.segments.add(
      SegmentState(
        i: 0,
        route: SegmentState.routeI2v,
        audioS: 3.2,
        durationS: 4,
        status: SegmentStatus.submitted,
        taskId: 'task-old',
        submittedAt: DateTime.now()
            .subtract(const Duration(hours: 1))
            .toIso8601String(),
        costSeconds: 4,
      ),
    );
    state.save();

    await runRender(state: state, mock: mock, urls: urls);

    expect(mock.submits, 0);
    expect(mock.polls, 2);
    expect(mock.downloads, 1);
    expect(urls.calls, 0);

    final clip = work.file('${ArtifactPaths.clipsDir}/seg_0.mp4');
    expect(clip.existsSync(), isTrue);
    expect(state.segments[0].status, SegmentStatus.succeeded);
    expect(state.segments[0].taskId, 'task-old');
    expect(state.cost.i2vSecondsTotal, 4);

    // Every status transition was persisted along the way (process-kill safe).
    final reloaded = ContentState.load(work.dir);
    expect(reloaded.segments[0].status, SegmentStatus.succeeded);
  });

  test('stale task older than 24h triggers fresh submit', () async {
    await placePhoto('001_scene');
    final mock = MockI2v()
      ..submitResponse = submitOk('task-new')
      ..videoBytes = await makeVideoBytes();
    mock.pollQueue.add(
      pollRes('SUCCEEDED', videoUrl: 'https://video.example.com/v.mp4'),
    );
    final urls = FakeUrls();
    final state = ContentState.load(work.dir);
    state.segments.add(
      SegmentState(
        i: 0,
        route: SegmentState.routeI2v,
        audioS: 3.2,
        durationS: 4,
        status: SegmentStatus.submitted,
        taskId: 'task-stale',
        submittedAt: DateTime.now()
            .subtract(const Duration(hours: 25))
            .toIso8601String(),
        costSeconds: 4,
      ),
    );
    state.save();

    await runRender(state: state, mock: mock, urls: urls);

    expect(mock.submits, 1);
    expect(urls.calls, 1);
    final body = jsonDecode(mock.lastSubmit!.body) as Map<String, dynamic>;
    final params = body['parameters'] as Map<String, dynamic>;
    expect(params['duration'], 4); // ceil(3.2), clamped
    expect(state.segments[0].taskId, 'task-new');
    expect(state.segments[0].status, SegmentStatus.succeeded);
  });

  test('audit reject degrades to kenburns with zero cost', () async {
    await placePhoto('001_scene');
    final mock = MockI2v()..submitResponse = submitOk('task-1');
    mock.pollQueue.add(pollRes('FAILED', code: 'IPInfringementSuspect'));
    final urls = FakeUrls();
    final state = ContentState.load(work.dir);

    await runRender(state: state, mock: mock, urls: urls);

    expect(mock.submits, 1); // audit reject never retries
    expect(mock.downloads, 0);

    final seg = state.segments.single;
    expect(seg.status, SegmentStatus.degraded);
    expect(seg.route, SegmentState.routeKenburns);
    expect(seg.costSeconds, 0);
    expect(seg.error!.cls, ErrorClass.auditReject);
    expect(state.cost.i2vSecondsTotal, 0);
    expect(state.cost.degradedCount, 1);

    // Ken Burns fallback still produced a playable clip.
    final clip = work.file('${ArtifactPaths.clipsDir}/seg_0.mp4');
    expect(clip.existsSync(), isTrue);
    expect(await mediaDurationSeconds(clip), closeTo(4, 0.5));
  });

  test('segments normalized to 1280x720/24fps', () async {
    await placePhoto('001_scene');
    final mock = MockI2v()
      ..submitResponse = submitOk('task-1')
      ..videoBytes = await makeVideoBytes();
    mock.pollQueue.add(
      pollRes('SUCCEEDED', videoUrl: 'https://video.example.com/v.mp4'),
    );
    final urls = FakeUrls();
    final state = ContentState.load(work.dir);

    await runRender(state: state, mock: mock, urls: urls);

    // Fixture download is 320x180 @ 12fps; the stored clip must be normalized.
    final clip = work.file('${ArtifactPaths.clipsDir}/seg_0.mp4');
    expect(await probeVideo(clip), '1280,720,24/1');

    final statusFile = work.file(ArtifactPaths.renderStatus);
    expect(statusFile.existsSync(), isTrue);
    final status =
        jsonDecode(statusFile.readAsStringSync()) as Map<String, dynamic>;
    expect((status['segments'] as List).length, 1);
  });
}
