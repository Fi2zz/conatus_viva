import 'dart:convert';

import 'package:flutter_wanxiang/pipeline/bailian/dashscope_video.dart';
import 'package:flutter_wanxiang/pipeline/bailian/wan30_video.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// DashScope async-task mock for the wan3.0 client: captures the submit
/// request and serves queued poll replies (the last one repeats).
class _CapturingClient {
  http.Request? lastPost;
  final List<http.Response> pollQueue = <http.Response>[];
  List<int> videoBytes = <int>[];

  http.Client get client => MockClient(_onRequest);

  Future<http.Response> _onRequest(http.Request req) async {
    if (req.method == 'POST') {
      lastPost = req;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'output': <String, dynamic>{
            'task_id': 'task-30',
            'task_status': 'PENDING',
          },
        }),
        200,
      );
    }
    if (req.url.path.startsWith('/api/v1/tasks/')) {
      return pollQueue.length > 1 ? pollQueue.removeAt(0) : pollQueue.first;
    }
    return http.Response.bytes(videoBytes, 200);
  }
}

http.Response pollRes(String status, {String? videoUrl}) => http.Response(
  jsonEncode(<String, dynamic>{
    'output': <String, dynamic>{'task_status': status, 'video_url': ?videoUrl},
  }),
  200,
);

void main() {
  test('wan3.0 submit sends first_frame media and no shot_type', () async {
    final cap = _CapturingClient();
    final client = Wan30VideoClient(apiKey: 'test-key', client: cap.client);

    final task = await client.submit(
      imgUrl: 'https://img.example.com/a.jpg',
      prompt: '云在动',
      durationS: 5,
    );

    expect(task.taskId, 'task-30');
    expect(task.status, I2vStatus.running);

    final req = cap.lastPost!;
    expect(
      req.url.toString(),
      'https://dashscope.aliyuncs.com/api/v1/services/aigc/'
      'video-generation/video-synthesis',
    );
    expect(req.headers['X-DashScope-Async'], 'enable');
    expect(req.headers['Authorization'], 'Bearer test-key');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(body['model'], 'wan3.0-video');
    expect(body['input'], <String, dynamic>{
      'prompt': '云在动',
      'media': <dynamic>[
        <String, dynamic>{
          'type': 'first_frame',
          'url': 'https://img.example.com/a.jpg',
        },
      ],
    });
    final params = body['parameters'] as Map<String, dynamic>;
    expect(params, <String, dynamic>{
      'resolution': '720P',
      'duration': 5,
      'ratio': 'adaptive',
      'audio': false,
      'prompt_extend': true,
      'watermark': true,
      'seed': 42,
    });
    expect(params.containsKey('shot_type'), isFalse);
  });

  test('wan3.0 text-to-video sends prompt only (no media)', () async {
    final cap = _CapturingClient();
    final client = Wan30VideoClient(
      apiKey: 'k',
      client: cap.client,
      audio: true,
    );

    final task = await client.submitTextToVideo(
      prompt: '一只猫在草地上奔跑',
      durationS: 6,
    );

    expect(task.taskId, 'task-30');
    final body = jsonDecode(cap.lastPost!.body) as Map<String, dynamic>;
    expect(body['model'], 'wan3.0-video');
    expect(body['input'], <String, dynamic>{'prompt': '一只猫在草地上奔跑'});
    expect((body['input'] as Map).containsKey('media'), isFalse);
    final params = body['parameters'] as Map<String, dynamic>;
    expect(params['duration'], 6);
    expect(params['ratio'], 'adaptive');
    expect(params['audio'], true);
    expect(params.containsKey('shot_type'), isFalse);
  });

  test('wan3.0 forwards a prime model name verbatim', () async {
    final cap = _CapturingClient();
    final client = Wan30VideoClient(
      apiKey: 'k',
      client: cap.client,
      model: 'wan3.0-video-prime',
    );

    await client.submit(imgUrl: 'u', prompt: 'p', durationS: 2);

    final body = jsonDecode(cap.lastPost!.body) as Map<String, dynamic>;
    expect(body['model'], 'wan3.0-video-prime');
  });

  test('wan3.0 poll parses a succeeded task video url', () async {
    final cap = _CapturingClient();
    cap.pollQueue.add(
      pollRes('SUCCEEDED', videoUrl: 'https://video.example.com/v.mp4'),
    );
    final client = Wan30VideoClient(apiKey: 'k', client: cap.client);

    final task = await client.poll('task-30');

    expect(task.status, I2vStatus.succeeded);
    expect(task.videoUrl.toString(), 'https://video.example.com/v.mp4');
  });

  test('wan3.0 client satisfies the shared VideoGenClient contract', () {
    final client = Wan30VideoClient(apiKey: 'k');
    expect(client, isA<VideoGenClient>());
  });
}
