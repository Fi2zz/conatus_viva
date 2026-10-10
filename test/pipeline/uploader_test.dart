import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/uploader.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File photo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_uploader_test');
    photo = File('${tmp.path}/photo.jpg')
      ..writeAsBytesSync(<int>[0xFF, 0xD8, 0x00, 0x01]);
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  PipelineConfig makeConfig({Map<String, String> env = const <String, String>{}})
    => PipelineConfig(
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
      env: env,
    );

  group('DashScopeUploadProvider', () {
    test('DashScopeUploadProvider parses upload response url', () async {
      http.Request? captured;
      final provider = DashScopeUploadProvider(
        apiKey: 'test-key',
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode(<String, dynamic>{
              'request_id': 'req-1',
              'data': <String, dynamic>{
                'url':
                    'https://dashscope-sample.oss-cn-hangzhou.aliyuncs.com/demo.jpg',
                'hash': 'abc123',
              },
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );

      final published = await provider.publish(photo);

      expect(provider.name, 'dashscope');
      expect(
        published.url,
        'https://dashscope-sample.oss-cn-hangzhou.aliyuncs.com/demo.jpg',
      );
      final before = DateTime.now();
      expect(published.expiresAt.isAfter(before), isTrue);

      expect(captured!.method, 'POST');
      expect(
        captured!.url.toString(),
        'https://dashscope.aliyuncs.com/api/v1/uploads',
      );
      expect(captured!.headers['Authorization'], 'Bearer test-key');
      expect(captured!.headers['content-type'], startsWith('multipart/form-data'));
      final bodyText = utf8.decode(captured!.bodyBytes, allowMalformed: true);
      expect(bodyText, contains('name="file"'));
      expect(bodyText, contains('filename="photo.jpg"'));
      expect(captured!.bodyBytes, containsAll(photo.readAsBytesSync()));
    });

    test('upload failure maps to transient', () async {
      final provider = DashScopeUploadProvider(
        apiKey: 'test-key',
        client: MockClient(
          (_) async => http.Response('server exploded', 500),
        ),
      );

      await expectLater(
        provider.publish(photo),
        throwsA(
          isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.transient),
        ),
      );
    });

    test('401 upload maps to fatal', () async {
      final provider = DashScopeUploadProvider(
        apiKey: 'bad-key',
        client: MockClient(
          (_) async => http.Response(
            '{"message":"invalid key"}',
            401,
            headers: <String, String>{'content-type': 'application/json'},
          ),
        ),
      );

      await expectLater(
        provider.publish(photo),
        throwsA(
          isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal),
        ),
      );
    });

    test('malformed success envelope maps to transient', () async {
      final provider = DashScopeUploadProvider(
        apiKey: 'test-key',
        client: MockClient(
          (_) async => http.Response(
            '<html>gateway error</html>',
            200,
            headers: <String, String>{'content-type': 'text/html'},
          ),
        ),
      );

      await expectLater(
        provider.publish(photo),
        throwsA(
          isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.transient),
        ),
      );
    });
  });

  group('pickProvider', () {
    final client = MockClient((_) async => http.Response('', 200));

    test('base64 provider is the zero-network default', () {
      final provider = pickProvider(
        prefer: 'base64',
        cfg: makeConfig(),
        client: client,
      );
      expect(provider, isA<Base64ImageUrlProvider>());
      expect(provider.name, 'base64');
    });

    test('provider selection switches on prefer flag', () {
      final oss = pickProvider(
        prefer: 'oss',
        cfg: makeConfig(
          env: <String, String>{
            'OSS_ACCESS_KEY_ID': 'fake-ak',
            'OSS_ACCESS_KEY_SECRET': 'fake-sk',
          },
        ),
        client: client,
      );
      expect(oss, isA<OssSignedUrlProvider>());
      expect(oss.name, 'oss');

      final dashscope = pickProvider(
        prefer: 'dashscope',
        cfg: makeConfig(
          env: <String, String>{'DASHSCOPE_API_KEY': 'fake-key'},
        ),
        client: client,
      );
      expect(dashscope, isA<DashScopeUploadProvider>());
      expect(dashscope.name, 'dashscope');
    });

    test('unknown prefer value throws ArgumentError', () {
      expect(
        () => pickProvider(
          prefer: 's3',
          cfg: makeConfig(
            env: <String, String>{'DASHSCOPE_API_KEY': 'fake-key'},
          ),
          client: client,
        ),
        throwsArgumentError,
      );
    });

    test('oss prefer without credentials fails fast', () {
      expect(
        () => pickProvider(prefer: 'oss', cfg: makeConfig(), client: client),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('Base64ImageUrlProvider', () {
    test('publishes a data URL with mime from extension, no http', () async {
      final provider = Base64ImageUrlProvider();

      final published = await provider.publish(photo);

      expect(
        published.url,
        'data:image/jpeg;base64,${base64Encode(photo.readAsBytesSync())}',
      );
      expect(published.expiresAt.isAfter(DateTime.now()), isTrue);
    });

    test('png/webp/bmp extensions map to their mime types', () async {
      final provider = Base64ImageUrlProvider();
      for (final ext in <String>['png', 'webp', 'bmp']) {
        final f = File('${tmp.path}/x.$ext')
          ..writeAsBytesSync(<int>[0x01]);
        final published = await provider.publish(f);
        expect(published.url, startsWith('data:image/$ext;base64,'));
      }
    });

    test('unreadable photo is fatal', () async {
      final provider = Base64ImageUrlProvider();
      await expectLater(
        provider.publish(File('${tmp.path}/missing.jpg')),
        throwsA(
          isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal),
        ),
      );
    });
  });

  group('OssSignedUrlProvider', () {
    test('publish signs PUT with OSS V1 header', () async {
      http.Request? captured;
      final provider = OssSignedUrlProvider(
        accessKeyId: 'fake-ak',
        accessKeySecret: 'fake-sk',
        bucket: 'test-bucket',
        endpoint: 'oss-cn-hangzhou.aliyuncs.com',
        prefix: 'pipeline-exp/',
        now: () => DateTime.utc(2022, 6, 7, 5, 15, 16),
        client: MockClient((request) async {
          captured = request;
          return http.Response('', 200);
        }),
      );

      final published = await provider.publish(photo);

      expect(provider.name, 'oss');
      expect(
        published.url,
        'https://test-bucket.oss-cn-hangzhou.aliyuncs.com/pipeline-exp/photo.jpg',
      );
      // The reported lifetime is pinned to the documented conservative window.
      expect(published.expiresAt, DateTime.utc(2022, 6, 7, 6, 15, 16));

      expect(captured!.method, 'PUT');
      expect(captured!.url.toString(), published.url);
      expect(captured!.headers['content-type'], 'image/jpeg');
      expect(captured!.headers['Date'], 'Tue, 07 Jun 2022 05:15:16 GMT');
      // Golden value computed offline, independent of this implementation:
      // printf 'PUT\n\nimage/jpeg\nTue, 07 Jun 2022 05:15:16 GMT\n'
      //        '/test-bucket/pipeline-exp/photo.jpg'
      //   | openssl dgst -sha1 -hmac 'fake-sk' -binary | base64
      expect(
        captured!.headers['Authorization'],
        'OSS fake-ak:s2T84asGi3Zuh3hmxH79C60cSjU=',
      );
      expect(captured!.bodyBytes, containsAll(photo.readAsBytesSync()));
    });

    test('OSS PUT 403 maps to fatal', () async {
      final provider = OssSignedUrlProvider(
        accessKeyId: 'fake-ak',
        accessKeySecret: 'fake-sk',
        bucket: 'test-bucket',
        endpoint: 'oss-cn-hangzhou.aliyuncs.com',
        prefix: 'pipeline-exp/',
        client: MockClient(
          (_) async => http.Response('SignatureDoesNotMatch', 403),
        ),
      );

      await expectLater(
        provider.publish(photo),
        throwsA(
          isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal),
        ),
      );
    });
  });
}
