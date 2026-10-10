import 'dart:io';

import 'package:conatus/conatus.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/host.dart';
import 'package:test/test.dart';

/// Offline smoke for the CLI host assembly: no keys, no network.
PipelineConfig testConfig() => const PipelineConfig(
  llmModel: 'llm-x',
  ttsModel: 'tts-x',
  ttsFallbackModel: 'tts-fb',
  ttsVoiceId: null,
  ttsFallbackVoice: null,
  i2vModel: 'i2v-x',
  i2vResolution: '720P',
  i2vWatermark: false,
  i2vSeed: 1,
  i2vPollSeconds: 1,
  i2vMaxWaitMinutes: 1,
  ossBucket: '',
  ossEndpoint: '',
  ossPrefix: 'exp/',
  targetCount: 4,
  minClipS: 2,
  maxClipS: 15,
  env: <String, String>{'DASHSCOPE_API_KEY': 'sk-test'},
);

void main() {
  test('host registers tool with high risk and required params', () async {
    final ctx = await createHost(cfg: testConfig());
    addTearDown(ctx.dispose);

    final tools = ctx.tools;
    final tool = tools.get('generate_monthly_video');
    expect(tool, isNotNull, reason: 'tool must be registered');
    expect(tool!.riskLevel, ToolRisk.high);

    final schema = tools.describeOne('generate_monthly_video');
    expect(schema, isNotNull);
    final parameters = schema!['parameters'] as Map<String, Object?>;
    expect(
      parameters['required'],
      containsAll(<String>['photos', 'dialect']),
    );
  });

  test('missing api key exits with code 2 message', () {
    expect(exitCodeMissingEnv, 2);

    final message = validateEnv(const <String, String>{});
    expect(message, isNotNull);
    expect(message, contains('DASHSCOPE_API_KEY'));

    expect(validateEnv(const <String, String>{'DASHSCOPE_API_KEY': ''}),
        isNotNull);
    expect(
      validateEnv(const <String, String>{'DASHSCOPE_API_KEY': 'sk-x'}),
      isNull,
    );
  });

  test('expandPhotos splits comma lists and sorts directory images', () {
    final tmp = Directory.systemTemp.createTempSync('host-photos-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File('${tmp.path}/b.png').writeAsBytesSync(<int>[0]);
    File('${tmp.path}/a.jpg').writeAsBytesSync(<int>[0]);
    File('${tmp.path}/notes.txt').writeAsStringSync('x');

    expect(expandPhotos(' x.png , y.jpg '), <String>['x.png', 'y.jpg']);
    expect(
      expandPhotos(tmp.path),
      <String>['${tmp.path}/a.jpg', '${tmp.path}/b.png'],
    );
  });
}
