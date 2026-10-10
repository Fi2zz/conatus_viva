import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:test/test.dart';

void main() {
  /// Self-contained config file (the real pipeline_config.json is
  /// gitignored — it carries the operator's workspace_id).
  Future<File> writeConfig(Directory dir, String json) async {
    final file = File('${dir.path}/cfg.json');
    await file.writeAsString(json);
    return file;
  }

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_config_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('loads spec defaults from a minimal config', () async {
    final c = await PipelineConfig.load(file: await writeConfig(tmp, '{}'), env: {});
    expect(c.llmModel, 'qwen3.8-flash');
    expect(c.ttsModel, 'qwen-audio-3.1-tts-flash');
    expect(c.ttsFallbackModel, 'qwen3-tts-flash');
    expect(c.i2vModel, 'wan2.6-i2v-flash');
    expect(c.i2vResolution, '720P');
    expect(c.i2vWatermark, isTrue);
    expect(c.i2vSeed, 42);
    expect(c.targetCount, 4);
    expect(c.ossPrefix, 'pipeline-exp/');
  });

  test('workspace_id routes every endpoint to the workspace maas host', () async {
    final c = await PipelineConfig.load(
      file: await writeConfig(tmp, '{"workspace_id": "ws-test123"}'),
      env: {},
    );
    expect(c.workspaceId, 'ws-test123');
    expect(c.apiHost, 'https://ws-test123.cn-beijing.maas.aliyuncs.com');
    expect(
      c.baseUrl,
      'https://ws-test123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1',
    );
  });

  test('empty workspace_id keeps the default dashscope host', () async {
    final c = await PipelineConfig.load(
      file: await writeConfig(tmp, '{"workspace_id": ""}'),
      env: {},
    );
    expect(c.apiHost, PipelineConfig.defaultApiHost);
    expect(c.baseUrl, PipelineConfig.defaultBaseUrl);
  });

  test('requireApiKey throws without env var', () async {
    final c = await PipelineConfig.load(file: await writeConfig(tmp, '{}'), env: {});
    expect(() => c.requireApiKey(), throwsA(isA<ConfigException>()));
  });

  test('load throws ConfigException when config file is missing', () async {
    await expectLater(
      PipelineConfig.load(file: File('${tmp.path}/no_such.json'), env: {}),
      throwsA(isA<ConfigException>()),
    );
  });
}
