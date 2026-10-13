import 'dart:convert';

import 'package:flutter_wanxiang/pipeline/bailian/dashscope_video.dart';
import 'package:flutter_wanxiang/pipeline/bailian/i2v.dart';
import 'package:flutter_wanxiang/pipeline/bailian/video_client.dart';
import 'package:flutter_wanxiang/pipeline/bailian/wan30_video.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

VideoGenClient build(String model, {http.Client? client}) => buildVideoClient(
  model: model,
  apiKey: 'k',
  client: client,
  host: 'https://dashscope.aliyuncs.com',
  resolution: '720P',
  watermark: true,
  seed: 42,
);

void main() {
  test('wan3 models pick the wan3.0 client', () {
    expect(build('wan3.0-video'), isA<Wan30VideoClient>());
    expect(build('wan3.0-video-prime'), isA<Wan30VideoClient>());
  });

  test('other models pick the wan2.6 i2v client', () {
    expect(build('wan2.6-i2v-flash'), isA<I2vClient>());
    expect(build('wanx2.1-i2v-turbo'), isA<I2vClient>());
  });

  test('the selected model is forwarded to the client', () async {
    http.Request? lastPost;
    final client = MockClient((req) async {
      lastPost = req;
      return http.Response(
        jsonEncode(<String, dynamic>{
          'output': <String, dynamic>{'task_id': 't', 'task_status': 'PENDING'},
        }),
        200,
      );
    });

    await build(
      'wan3.0-video-prime',
      client: client,
    ).submit(imgUrl: 'u', prompt: 'p', durationS: 2);

    final body = jsonDecode(lastPost!.body) as Map<String, dynamic>;
    expect(body['model'], 'wan3.0-video-prime');
  });
}
