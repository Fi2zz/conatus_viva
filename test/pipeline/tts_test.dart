import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/artifacts.dart';
import 'package:flutter_wanxiang/pipeline/bailian/tts.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/dialect_map.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/state.dart';
import 'package:flutter_wanxiang/pipeline/steps/script.dart';
import 'package:flutter_wanxiang/pipeline/steps/tts_step.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late List<int> wavBytes;
  late Directory caseDir;
  var caseIndex = 0;

  setUpAll(() async {
    // One fixture wav for the whole suite: `ffmpeg -f lavfi -i sine`,
    // 1s of 440Hz at 24kHz mono — the format the step requests.
    tmp = Directory.systemTemp.createTempSync('conatus_tts_test');
    final fixture = File('${tmp.path}/sine.wav');
    final result = await Process.run('ffmpeg', [
      '-y',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=1',
      '-ar',
      '24000',
      '-ac',
      '1',
      '-c:a',
      'pcm_s16le',
      fixture.path,
    ]);
    expect(
      result.exitCode,
      0,
      reason: 'ffmpeg fixture generation failed: ${result.stderr}',
    );
    wavBytes = fixture.readAsBytesSync();
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  setUp(() {
    caseDir = Directory('${tmp.path}/case${caseIndex++}')
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (caseDir.existsSync()) caseDir.deleteSync(recursive: true);
  });

  /// A 200 reply whose body is the wav bytes themselves.
  http.Response wavResponse() => http.Response.bytes(
    List<int>.of(wavBytes),
    200,
    headers: <String, String>{'content-type': 'audio/wav'},
  );

  /// A 200 reply whose body is a JSON error/envelope.
  http.Response jsonResponse(Map<String, dynamic> body) => http.Response(
    jsonEncode(body),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  PipelineConfig makeConfig({String? voiceId, String fallback = 'longxia'})
    => PipelineConfig(
      llmModel: 'qwen3.8-flash',
      ttsModel: 'qwen-audio-3.1-tts-flash',
      ttsFallbackModel: 'qwen3-tts-flash',
      ttsVoiceId: voiceId,
      ttsFallbackVoice: fallback,
      i2vModel: 'wan2.6-i2v-flash',
      i2vResolution: '720P',
      i2vWatermark: true,
      i2vSeed: 42,
      i2vPollSeconds: 15,
      i2vMaxWaitMinutes: 10,
      ossBucket: '',
      ossEndpoint: '',
      ossPrefix: 'pipeline-exp/',
      targetCount: 4,
      minClipS: 2,
      maxClipS: 15,
    );

  VideoScript scriptOf(List<String> lines) => VideoScript(
    segments: <SegmentScript>[
      for (var i = 0; i < lines.length; i++)
        SegmentScript(photoId: 'p$i', line: lines[i], motionPrompt: null),
    ],
    totalChars: lines.fold<int>(0, (sum, line) => sum + line.length),
  );

  /// The instruction carried by a captured TTS request body — only the
  /// qwen-audio-* family carries one (inside `input`); Qwen-TTS bodies
  /// have no instruction channel, so this returns null for them.
  String? instructionOf(Map<String, dynamic> body) {
    final input = body['input'];
    if (input is Map<String, dynamic>) return input['instruction'] as String?;
    return null;
  }

  group('TtsClient', () {
    test(
      'qwen-audio hits SpeechSynthesizer with in-input instruction, qwen3 hits multimodal-generation without one',
      () async {
        final bodies = <Map<String, dynamic>>[];
        final urls = <String>[];
        final client = TtsClient(
          apiKey: 'test-key',
          client: MockClient((request) async {
            urls.add(request.url.toString());
            expect(request.headers['Authorization'], 'Bearer test-key');
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return wavResponse();
          }),
        );

        await client.synth(
          text: '你好',
          model: 'qwen-audio-3.1-tts-flash',
          fallbackVoice: 'v1',
          instruction: '请用河南话表达。',
        );
        await client.synth(
          text: '你好',
          model: 'qwen3-tts-flash',
          fallbackVoice: 'v1',
          instruction: '请用普通话表达。',
        );

        expect(bodies, hasLength(2));
        // qwen-audio family → SpeechSynthesizer, instruction INSIDE input.
        expect(bodies[0]['input'], isA<Map>().having(
          (input) => input['instruction'],
          'instruction',
          '请用河南话表达。',
        ));
        expect(bodies[0].containsKey('instruction'), isFalse);
        expect(
          urls[0],
          '${TtsClient.defaultHost}${TtsClient.speechPath}',
        );
        // Qwen-TTS family → multimodal-generation, no instruction channel,
        // no control-tag prefix, language pinned.
        expect(instructionOf(bodies[1]), isNull);
        expect(bodies[1].containsKey('instructions'), isFalse);
        expect(
          (bodies[1]['input'] as Map<String, dynamic>)['language_type'],
          'Chinese',
        );
        expect(
          (bodies[1]['input'] as Map<String, dynamic>)['text'],
          isNot(startsWith('[very slowly]')),
        );
        expect(
          urls[1],
          '${TtsClient.defaultHost}${TtsClient.generationPath}',
        );
      },
    );

    test('workspace host applies to both endpoint families', () async {
      final urls = <String>[];
      final client = TtsClient(
        apiKey: 'test-key',
        host: 'https://ws-123.cn-beijing.maas.aliyuncs.com',
        client: MockClient((request) async {
          urls.add(request.url.toString());
          return wavResponse();
        }),
      );

      await client.synth(
        text: '你好',
        model: 'qwen-audio-3.1-tts-flash',
        fallbackVoice: 'v1',
        instruction: 'x',
      );
      await client.synth(
        text: '你好',
        model: 'qwen3-tts-flash',
        fallbackVoice: 'v1',
        instruction: 'x',
      );

      const host = 'https://ws-123.cn-beijing.maas.aliyuncs.com';
      expect(urls[0], '$host${TtsClient.speechPath}');
      expect(urls[1], '$host${TtsClient.generationPath}');
    });

    test('text prefixed with [very slowly] and wav 24000 requested', () async {
      http.Request? captured;
      final client = TtsClient(
        apiKey: 'test-key',
        client: MockClient((request) async {
          captured = request;
          return wavResponse();
        }),
      );

      final audio = await client.synth(
        text: '今天天气很好',
        model: 'qwen-audio-3.1-tts-flash',
        voiceId: null,
        fallbackVoice: 'fv',
        instruction: 'x',
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      final input = body['input'] as Map<String, dynamic>;
      expect(input['text'], startsWith('[very slowly]'));
      expect(input['text'], '[very slowly]今天天气很好');
      expect(input['format'], 'wav');
      expect(input['sample_rate'], 24000);
      // voiceId ?? fallbackVoice
      expect(input['voice'], 'fv');
      // The bytes are on disk and ffprobe measured them (≈1s fixture).
      expect(audio.wav.readAsBytesSync(), wavBytes);
      expect(audio.seconds, closeTo(1.0, 0.05));

      // A configured voice_id wins over the fallback voice.
      await client.synth(
        text: 'a',
        model: 'qwen3-tts-flash',
        voiceId: 'vid',
        fallbackVoice: 'fv',
        instruction: 'x',
      );
      final body2 = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect((body2['input'] as Map<String, dynamic>)['voice'], 'vid');
    });

    test('401 maps to fatal without retry', () async {
      var calls = 0;
      final client = TtsClient(
        apiKey: 'bad-key',
        client: MockClient((request) async {
          calls++;
          return http.Response(
            '{"code":"InvalidApiKey","message":"invalid key"}',
            401,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      client.sleep = (_) async {};

      await expectLater(
        client.synth(
          text: '你好',
          model: 'qwen-audio-3.1-tts-flash',
          fallbackVoice: 'v',
          instruction: 'i',
        ),
        throwsA(
          isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal),
        ),
      );
      expect(calls, 1); // fatal fails fast — no retry consumed
    });

    test('audio url reply is downloaded and stored immediately', () async {
      final tts = TtsClient(
        apiKey: 'test-key',
        client: MockClient((request) async {
          if (request.url.host == 'example.test') return wavResponse();
          // Non-streaming reply: JSON envelope carrying a 24h audio URL.
          return jsonResponse(<String, dynamic>{
            'output': <String, dynamic>{
              'audio': <String, dynamic>{
                'url': 'https://example.test/audio/seg.wav',
              },
            },
          });
        }),
      );

      final audio = await tts.synth(
        text: '你好',
        model: 'qwen-audio-3.1-tts-flash',
        fallbackVoice: 'v',
        instruction: 'i',
      );

      expect(audio.wav.readAsBytesSync(), wavBytes);
      expect(audio.wav.existsSync(), isTrue);
      expect(audio.seconds, closeTo(1.0, 0.05));
    });
  });

  group('runTtsStep', () {
    test('dialect failure falls back to mandarin then succeeds', () async {
      final instructions = <String>[];
      final tts = TtsClient(
        apiKey: 'test-key',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final instruction = instructionOf(body) ?? '<none>';
          instructions.add(instruction);
          if (instruction == '请用河南话表达。') {
            return http.Response(
              '{"code":"InternalError","message":"synthesis failed"}',
              500,
              headers: <String, String>{'content-type': 'application/json'},
            );
          }
          return wavResponse();
        }),
      );
      tts.sleep = (_) async {}; // never wait out real backoff in tests

      final work = Workdir(caseDir.path, 'c1');
      final state = ContentState.load(work.dir);

      final audios = await runTtsStep(
        script: scriptOf(<String>['今天天气很好']),
        dialect: kDialectTable['河南']!,
        // voice_id set → qwen-audio path, which is the family that carries
        // the dialect instruction the mock keys on.
        cfg: makeConfig(voiceId: 'cloned_v1'),
        tts: tts,
        work: work,
        state: state,
      );

      // The dialect attempt got exactly one transient retry, then the step
      // re-synthesized the segment with the mandarin instruction.
      expect(
        instructions.where((i) => i == '请用河南话表达。'),
        hasLength(2),
      );
      expect(instructions.where((i) => i == '请用普通话表达。'), hasLength(1));
      // The mandarin track is what landed on disk.
      expect(audios, hasLength(1));
      expect(audios.first.wav.path, '${work.dir}/04_audio/seg_0.wav');
      expect(work.file('04_audio/seg_0.wav').readAsBytesSync(), wavBytes);
      expect(work.file(ArtifactPaths.durations).existsSync(), isTrue);
      expect(state.step('tts').status, StepStatus.succeeded);
    });

    test('durations.json written with measured seconds', () async {
      final models = <String>[];
      final tts = TtsClient(
        apiKey: 'test-key',
        client: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          models.add(body['model'] as String);
          return wavResponse();
        }),
      );

      final work = Workdir(caseDir.path, 'c1');
      final state = ContentState.load(work.dir);

      final audios = await runTtsStep(
        script: scriptOf(<String>['第一句台词', '第二句台词']),
        dialect: mandarinSpec,
        cfg: makeConfig(),
        tts: tts,
        work: work,
        state: state,
      );

      // spec §3: no voice_id → fallback model with its system voice.
      expect(models, everyElement('qwen3-tts-flash'));

      final durationsFile = work.file(ArtifactPaths.durations);
      expect(durationsFile.existsSync(), isTrue);
      final durations =
          (jsonDecode(durationsFile.readAsStringSync()) as List<dynamic>)
              .cast<num>();
      expect(durations, hasLength(2));
      for (final seconds in durations) {
        expect(seconds.toDouble(), closeTo(1.0, 0.05));
      }

      expect(audios, hasLength(2));
      expect(audios[0].wav.path, '${work.dir}/04_audio/seg_0.wav');
      expect(audios[1].wav.path, '${work.dir}/04_audio/seg_1.wav');
      expect(audios[1].seconds, closeTo(1.0, 0.05));
      expect(work.file('04_audio/seg_1.wav').readAsBytesSync(), wavBytes);
      // Atomic publishes leave no temp files behind.
      expect(work.exists('04_audio/durations.json.tmp'), isFalse);
      expect(work.exists('04_audio/seg_0.wav.tmp'), isFalse);

      final record = state.step('tts');
      expect(record.status, StepStatus.succeeded);
      expect(record.attempts, 1);
      expect(record.t, <String>['start', 'end']);
    });

    test('existing durations.json skips re-synthesis', () async {
      final work = Workdir(caseDir.path, 'c1');
      final state = ContentState.load(work.dir);
      // Artifacts from a previous run.
      work.dirOf(ArtifactPaths.audioDir).createSync(recursive: true);
      for (var i = 0; i < 2; i++) {
        work.file('04_audio/seg_$i.wav').writeAsBytesSync(wavBytes);
      }
      work.file(ArtifactPaths.durations).writeAsStringSync('[1.0,1.0]');

      final tts = TtsClient(
        apiKey: 'test-key',
        client: MockClient((request) async {
          fail('must not synthesize when durations.json exists');
        }),
      );

      final audios = await runTtsStep(
        script: scriptOf(<String>['a', 'b']),
        dialect: mandarinSpec,
        cfg: makeConfig(),
        tts: tts,
        work: work,
        state: state,
      );

      expect(audios.map((a) => a.seconds), <double>[1.0, 1.0]);
      expect(audios[0].wav.readAsBytesSync(), wavBytes);
      // The skip happens before any state transition (artifact-exists skip).
      expect(state.step('tts').attempts, 0);
      expect(work.exists(ArtifactPaths.state), isFalse);
    });

    test('dialect and mandarin both failing is fatal', () async {
      var calls = 0;
      final tts = TtsClient(
        apiKey: 'test-key',
        client: MockClient((request) async {
          calls++;
          return http.Response(
            '{"code":"InternalError","message":"synthesis failed"}',
            500,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      );
      tts.sleep = (_) async {};

      final work = Workdir(caseDir.path, 'c1');
      final state = ContentState.load(work.dir);

      await expectLater(
        runTtsStep(
          script: scriptOf(<String>['台词']),
          dialect: kDialectTable['河南']!,
          cfg: makeConfig(),
          tts: tts,
          work: work,
          state: state,
        ),
        throwsA(
          isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal),
        ),
      );

      // 2 dialect requests (initial + one transient retry) + 2 mandarin.
      expect(calls, 4);
      final record = state.step('tts');
      expect(record.status, StepStatus.failed);
      expect(record.error?.cls, ErrorClass.fatal);
      // The failure is persisted, not just in memory.
      final reloaded = ContentState.load(work.dir);
      expect(reloaded.step('tts').status, StepStatus.failed);
      expect(reloaded.step('tts').error?.cls, ErrorClass.fatal);
    });

    test('voice_id set switches to qwen-audio model with voice', () async {
      http.Request? captured;
      final tts = TtsClient(
        apiKey: 'test-key',
        client: MockClient((request) async {
          captured = request;
          return wavResponse();
        }),
      );

      final work = Workdir(caseDir.path, 'c1');
      final state = ContentState.load(work.dir);

      await runTtsStep(
        script: scriptOf(<String>['台词']),
        dialect: kDialectTable['河南']!,
        cfg: makeConfig(voiceId: 'cloned_v1'),
        tts: tts,
        work: work,
        state: state,
      );

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['model'], 'qwen-audio-3.1-tts-flash');
      expect((body['input'] as Map<String, dynamic>)['voice'], 'cloned_v1');
      expect(
        (body['input'] as Map<String, dynamic>)['instruction'],
        '请用河南话表达。',
      );
    });
  });
}
