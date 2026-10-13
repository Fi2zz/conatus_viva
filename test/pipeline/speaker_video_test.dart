import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/wan30_video.dart';
import 'package:flutter_wanxiang/pipeline/speaker_video.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// DashScope async mock that captures the submitted prompt and serves a
/// PENDING → SUCCEEDED task plus a tiny download body.
class _Mock {
  String? prompt;

  http.Client get client => MockClient(_onRequest);

  Future<http.Response> _onRequest(http.Request req) async {
    if (req.method == 'POST') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      prompt = (body['input'] as Map<String, dynamic>)['prompt'] as String?;
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
      return http.Response(
        jsonEncode(<String, dynamic>{
          'output': <String, dynamic>{
            'task_status': 'SUCCEEDED',
            'video_url': 'https://video.example.com/v.mp4',
          },
        }),
        200,
      );
    }
    return http.Response.bytes(<int>[1, 2, 3], 200);
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_speaker_video_test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  test('appends dialect instruction and writes raw + final paths', () async {
    final mock = _Mock();

    final result = await generateSpeakerVideo(
      client: Wan30VideoClient(apiKey: 'k', client: mock.client, audio: true),
      theme: '河南美食',
      dialect: '河南',
      durationS: 5,
      contentId: 'run-1',
      avatar: File('${tmp.path}/avatar.jpg'),
      baseDir: tmp.path,
      sleep: (_) async {},
      overlay: ({required video, required avatar, required out}) async {
        File(out.path).writeAsBytesSync(<int>[0]);
      },
    );

    expect(mock.prompt, contains('河南美食'));
    expect(mock.prompt, contains('请用河南话表达。'));
    expect(result.rawVideoPath, endsWith('run-1/raw.mp4'));
    expect(result.finalVideoPath, endsWith('run-1/video.mp4'));
    expect(result.durationS, 5);
    expect(result.taskId, 't1');
    expect(File(result.finalVideoPath).existsSync(), isTrue);
  });

  test('duration limits are 2..30 seconds', () {
    expect(t2vMinDurationS, 2);
    expect(t2vMaxDurationS, 30);
  });
}
