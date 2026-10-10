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
    // The repo config carries a workspace_id → every DashScope-family
    // endpoint (LLM baseUrl included) lands on the workspace maas host.
    expect(c.workspaceId, isNotEmpty);
    expect(
      c.baseUrl,
      'https://${c.workspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
    );
    expect(
      c.apiHost,
      'https://${c.workspaceId}.cn-beijing.maas.aliyuncs.com',
    );
    expect(c.ossPrefix, 'pipeline-exp/');
  });

  test('empty workspace_id keeps the default dashscope host', () async {
    final tmp = Directory.systemTemp.createTempSync('conatus_config_test');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File('${tmp.path}/cfg.json')
      ..writeAsStringSync('{"workspace_id": ""}');

    final c = await PipelineConfig.load(file: file, env: {});

    expect(c.apiHost, PipelineConfig.defaultApiHost);
    expect(c.baseUrl, PipelineConfig.defaultBaseUrl);
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
