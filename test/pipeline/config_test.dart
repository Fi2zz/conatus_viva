import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:test/test.dart';

void main() {
  test('loads pipeline_config.json with spec defaults', () async {
    final c = await PipelineConfig.load(file: File('pipeline_config.json'), env: {});
    expect(c.llmModel, 'qwen3.8-flash');
    expect(c.ttsModel, 'qwen-audio-3.1-tts-flash');
    expect(c.i2vModel, 'wan2.6-i2v-flash');
    expect(c.i2vResolution, '720P');
    expect(c.i2vWatermark, isTrue);
    expect(c.i2vSeed, 42);
    expect(c.targetCount, 4);
    expect(c.baseUrl, 'https://dashscope.aliyuncs.com/compatible-mode/v1');
  });

  test('requireApiKey throws without env var', () async {
    final c = await PipelineConfig.load(file: File('pipeline_config.json'), env: {});
    expect(() => c.requireApiKey(), throwsA(isA<ConfigException>()));
  });

  test('load throws ConfigException when config file is missing', () async {
    await expectLater(
      PipelineConfig.load(file: File('no_such_config.json'), env: {}),
      throwsA(isA<ConfigException>()),
    );
  });
}
