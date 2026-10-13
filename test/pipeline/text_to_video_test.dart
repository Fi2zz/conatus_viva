import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/wan30_video.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/text_to_video.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// DashScope async mock for the t2v flow: counts submits/polls/downloads and
/// serves queued poll replies (the last one repeats).
class _Mock {
  int submits = 0;
  int polls = 0;
  int downloads = 0;
  List<int> videoBytes = <int>[];
  final List<http.Response> pollQueue = <http.Response>[];

  http.Client get client => MockClient(_onRequest);

  Future<http.Response> _onRequest(http.Request req) async {
    if (req.method == 'POST') {
      submits++;
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

  Future<TextToVideoResult> run(_Mock mock, {String? outFile, int durationS = 5}) {
    return generateTextToVideo(
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
