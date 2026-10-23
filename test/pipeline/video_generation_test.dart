import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/wan30_video.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/video_generation.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// DashScope async mock for the t2v flow: counts submits/polls/downloads and
/// serves queued poll replies (the last one repeats).
class _Mock {
  int submits = 0;
  int polls = 0;
  int downloads = 0;
  String? lastPostBody;
  List<int> videoBytes = <int>[];
  final List<http.Response> pollQueue = <http.Response>[];

  http.Client get client => MockClient(_onRequest);

  Future<http.Response> _onRequest(http.Request req) async {
    if (req.method == 'POST') {
      submits++;
      lastPostBody = req.body;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'output': <String, dynamic>{
            'task_id': 't1',
            'task_status': 'PENDING',
          },
        }),
        200,
      );
    }
    if (req.url.path.startsWith('/api/v1/tasks/')) {
      polls++;
      return pollQueue.length > 1 ? pollQueue.removeAt(0) : pollQueue.first;
    }
    downloads++;
    return http.Response.bytes(videoBytes, 200);
  }
}

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

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_t2v_test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  Future<VideoGenResult> run(_Mock mock, {String? outFile, int durationS = 5}) {
    return generateVideo(
      client: Wan30VideoClient(apiKey: 'k', client: mock.client, audio: true),
      prompt: '一只猫在草地上奔跑',
      durationS: durationS,
      outFile: outFile ?? '${tmp.path}/out/video.mp4',
      sleep: (_) async {},
    );
  }

  test('submits, polls, downloads and writes the mp4', () async {
    final mock = _Mock()
      ..videoBytes = <int>[1, 2, 3, 4, 5]
      ..pollQueue.addAll(<http.Response>[
        pollRes('RUNNING'),
        pollRes('SUCCEEDED', videoUrl: 'https://video.example.com/v.mp4'),
      ]);

    final result = await run(mock);

    expect(mock.submits, 1);
    expect(mock.polls, 2);
    expect(mock.downloads, 1);
    expect(result.taskId, 't1');
    expect(result.durationS, 5);
    expect(result.filePath, '${tmp.path}/out/video.mp4');
    final file = File(result.filePath);
    expect(file.existsSync(), isTrue);
    expect(file.readAsBytesSync(), <int>[1, 2, 3, 4, 5]);
  });

  test('first-frame image routes to i2v media, prompt optional', () async {
    const image = 'data:image/png;base64,AAAA';
    final mock = _Mock()
      ..videoBytes = <int>[9]
      ..pollQueue.add(
        pollRes('SUCCEEDED', videoUrl: 'https://video.example.com/v.mp4'),
      );

    final result = await generateVideo(
      client: Wan30VideoClient(apiKey: 'k', client: mock.client),
      prompt: '',
      durationS: 5,
      outFile: '${tmp.path}/i2v.mp4',
      firstFrameDataUrl: image,
      sleep: (_) async {},
    );

    final body = jsonDecode(mock.lastPostBody!) as Map<String, dynamic>;
    expect(body['input'], <String, dynamic>{
      'media': <dynamic>[
        <String, dynamic>{'type': 'first_frame', 'url': image},
      ],
    });
    expect(result.filePath, '${tmp.path}/i2v.mp4');
    expect(mock.downloads, 1);
  });

  test('audit rejection surfaces as an auditReject error, no download', () async {
    final mock = _Mock()
      ..pollQueue.add(pollRes('FAILED', code: 'IPInfringementSuspect'));

    await expectLater(
      run(mock),
      throwsA(
        isA<PipelineError>().having(
          (e) => e.cls,
          'cls',
          ErrorClass.auditReject,
        ),
      ),
    );
    expect(mock.downloads, 0);
  });
}
