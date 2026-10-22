import 'dart:convert';

import 'package:flutter_wanxiang/pipeline/bailian/image_client.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

ImageRequest _req({
  ImageMode mode = ImageMode.t2i,
  List<String> refs = const [],
  String? negative,
  String? size,
  int n = 1,
}) => ImageRequest(
  model: 'qwen-image-3.0-pro',
  family: ImageFamily.qwen3,
  mode: mode,
  prompt: '一只猫',
  negativePrompt: negative,
  size: size,
  n: n,
  seed: 7,
  refImages: refs,
);

void main() {
  test('qwen body carries messages, refs and negative prompt', () async {
    var body = <String, dynamic>{};
    final client = QwenImageClient(
      apiKey: 'k',
      model: 'qwen-image-3.0-pro',
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(req.headers['X-DashScope-Async'], 'enable');
        return http.Response(
          '{"output":{"task_id":"t1","task_status":"PENDING"}}',
          200,
        );
      }),
    );
    await client.submit(
      _req(
        mode: ImageMode.i2i,
        refs: ['data:image/png;base64,AAA'],
        negative: '模糊',
        size: '1024*1024',
      ),
    );
    expect(body['model'], 'qwen-image-3.0-pro');
    final content =
        (body['input'] as Map)['messages'][0]['content'] as List<dynamic>;
    expect(content.first, {'image': 'data:image/png;base64,AAA'});
    expect(content.last, {'text': '一只猫'});
    expect((body['parameters'] as Map)['negative_prompt'], '模糊');
    expect((body['parameters'] as Map)['size'], '1024*1024');
  });

  test('wan body uses size tier and sequential flag', () async {
    var body = <String, dynamic>{};
    final client = WanImageClient(
      apiKey: 'k',
      model: 'wan2.7-image-pro',
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          '{"output":{"task_id":"t1","task_status":"PENDING"}}',
          200,
        );
      }),
    );
    await client.submit(
      ImageRequest(
        model: 'wan2.7-image-pro',
        family: ImageFamily.wan27,
        mode: ImageMode.series,
        prompt: '四季',
        size: '2K',
        n: 4,
        refImages: const [],
      ),
    );
    final params = body['parameters'] as Map<String, dynamic>;
    expect(params['enable_sequential'], isTrue);
    expect(params['size'], '2K');
    expect(params['n'], 4);
    expect(params.containsKey('thinking_mode'), isFalse);
  });

  test('z-image body uses prompt and results url parsing', () async {
    var body = <String, dynamic>{};
    final client = ZImageClient(
      apiKey: 'k',
      model: 'z-image-turbo',
      client: MockClient((req) async {
        if (req.method == 'POST') {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(
            '{"output":{"task_id":"t1","task_status":"PENDING"}}',
            200,
          );
        }
        return http.Response(
          '{"output":{"task_id":"t1","task_status":"SUCCEEDED",'
          '"results":[{"url":"https://x/1.png"}]}}',
          200,
        );
      }),
    );
    await client.submit(
      ImageRequest(
        model: 'z-image-turbo',
        family: ImageFamily.zImage,
        mode: ImageMode.t2i,
        prompt: '一只猫',
        n: 1,
        seed: 7,
        refImages: const [],
      ),
    );
    expect((body['input'] as Map)['prompt'], '一只猫');
    expect((body['parameters'] as Map)['seed'], 7);
    final task = await client.poll('t1');
    expect(task.status, ImageTaskStatus.succeeded);
    expect(task.imageUrls.single.toString(), 'https://x/1.png');
  });

  test('choices-shaped response is parsed for qwen and wan', () async {
    final client = QwenImageClient(
      apiKey: 'k',
      model: 'qwen-image-3.0-pro',
      client: MockClient(
        (req) async => http.Response(
          '{"output":{"task_id":"t1","task_status":"SUCCEEDED","choices":['
          '{"message":{"content":[{"image":"https://x/a.png"},{"image":"https://x/b.png"}]}}]}}',
          200,
        ),
      ),
    );
    final task = await client.poll('t1');
    expect(task.imageUrls.map((u) => u.toString()), [
      'https://x/a.png',
      'https://x/b.png',
    ]);
  });

  test('5xx is transient, 400 is fatal', () async {
    Future<void> expectClass(int status, ErrorClass cls) async {
      final client = QwenImageClient(
        apiKey: 'k',
        model: 'qwen-image-3.0-pro',
        client: MockClient(
          (req) async => http.Response('{"message":"x"}', status),
        ),
      );
      await expectLater(
        client.poll('t1'),
        throwsA(isA<PipelineError>().having((e) => e.cls, 'cls', cls)),
      );
    }

    await expectClass(500, ErrorClass.transient);
    await expectClass(400, ErrorClass.fatal);
  });
}
