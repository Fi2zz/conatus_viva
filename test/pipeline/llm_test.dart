import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/llm.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File photo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_llm_test');
    photo = File('${tmp.path}/photo.jpg')
      ..writeAsBytesSync(<int>[0xFF, 0xD8, 0x00, 0x01]);
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// A well-formed `chat/completions` response carrying [content].
  http.Response chatOk(String content) => http.Response(
    jsonEncode(<String, dynamic>{
      'choices': <dynamic>[
        <String, dynamic>{
          'message': <String, dynamic>{'role': 'assistant', 'content': content},
        },
      ],
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  QwenClient makeClient(http.Client transport) => QwenClient(
    apiKey: 'test-key',
    baseUrl: 'https://example.test/v1',
    client: transport,
  );

  test('chat sends qwen3.8-flash with image content array', () async {
    http.Request? captured;
    final client = makeClient(
      MockClient((request) async {
        captured = request;
        return chatOk('ok');
      }),
    );

    final reply = await client.chat(
      system: 'sys prompt',
      user: 'describe this photo',
      images: [photo],
    );

    expect(reply, 'ok');
    expect(
      captured!.url.toString(),
      'https://example.test/v1/chat/completions',
    );
    expect(captured!.headers['Authorization'], 'Bearer test-key');

    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['model'], 'qwen3.8-flash');

    final messages = body['messages'] as List<dynamic>;
    final system = messages.first as Map<String, dynamic>;
    expect(system['role'], 'system');
    expect(system['content'], 'sys prompt');

    final user = messages[1] as Map<String, dynamic>;
    expect(user['role'], 'user');
    final content = user['content'];
    expect(content, isA<List<dynamic>>());
    final parts = content! as List<dynamic>;
    final textPart = parts.first as Map<String, dynamic>;
    expect(textPart['type'], 'text');
    expect(textPart['text'], 'describe this photo');
    final imagePart = parts[1] as Map<String, dynamic>;
    expect(imagePart['type'], 'image_url');
    final url =
        (imagePart['image_url'] as Map<String, dynamic>)['url'] as String;
    expect(
      url,
      'data:image/jpeg;base64,${base64Encode(photo.readAsBytesSync())}',
    );
  });

  test('429 retried then succeeds', () async {
    var calls = 0;
    final client = makeClient(
      MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            '{"error":{"message":"rate limited"}}',
            429,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }
        return chatOk('second try');
      }),
    );
    client.sleep = (_) async {}; // never wait out real backoff in tests

    final reply = await client.chat(system: 's', user: 'u');

    expect(reply, 'second try');
    expect(calls, 2);
  });

  test('401 maps to fatal PipelineError', () async {
    var calls = 0;
    final client = makeClient(
      MockClient((request) async {
        calls++;
        return http.Response(
          '{"error":{"message":"invalid api key"}}',
          401,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    client.sleep = (_) async {};

    await expectLater(
      client.chat(system: 's', user: 'u'),
      throwsA(
        isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal),
      ),
    );
    expect(calls, 1);
  });

  test('chatJson strips markdown fence and parses', () async {
    http.Request? captured;
    final client = makeClient(
      MockClient((request) async {
        captured = request;
        return chatOk('```json\n{"a":1}\n```');
      }),
    );

    final result = await client.chatJson(system: 's', user: 'u');

    expect(result, <String, dynamic>{'a': 1});
    // The system prompt must demand bare JSON output.
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    final messages = body['messages'] as List<dynamic>;
    final system = messages.first as Map<String, dynamic>;
    expect(system['content'], contains('JSON'));
  });

  test('chatJson retries a parse failure as transient', () async {
    var calls = 0;
    final client = makeClient(
      MockClient((request) async {
        calls++;
        if (calls == 1) return chatOk('not json at all');
        return chatOk('{"a":2}');
      }),
    );
    client.sleep = (_) async {};

    final result = await client.chatJson(system: 's', user: 'u');

    expect(result, <String, dynamic>{'a': 2});
    expect(calls, 2);
  });
}
