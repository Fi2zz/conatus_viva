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

  test('t2v section defaults to the wan3.0 text-to-video settings', () async {
    final c = await PipelineConfig.load(file: await writeConfig(tmp, '{}'), env: {});
    expect(c.t2vModel, 'wan3.0-video');
    expect(c.t2vResolution, '720P');
    expect(c.t2vRatio, 'adaptive');
    expect(c.t2vDuration, 5);
    expect(c.t2vAudio, isTrue);
    expect(c.t2vWatermark, isFalse);
    expect(c.t2vSeed, isNull);
    expect(c.t2vPollSeconds, 15);
    expect(c.t2vMaxWaitMinutes, 10);
  });

  test('t2v section overrides from config', () async {
    final c = await PipelineConfig.load(
      file: await writeConfig(
        tmp,
        '{"t2v": {"model": "wan3.0-video-prime", "resolution": "1080P", '
            '"duration": 8, "audio": false, "watermark": true, "seed": 7}}',
      ),
      env: {},
    );
    expect(c.t2vModel, 'wan3.0-video-prime');
    expect(c.t2vResolution, '1080P');
    expect(c.t2vDuration, 8);
    expect(c.t2vAudio, isFalse);
    expect(c.t2vWatermark, isTrue);
    expect(c.t2vSeed, 7);
  });

  test('t2v yuan_per_second parses, defaults to the wan3.0 price', () async {
    final c = await PipelineConfig.load(
      file: await writeConfig(tmp, '{"t2v": {"yuan_per_second": 0.2}}'),
      env: {},
    );
    expect(c.t2vYuanPerSecond, 0.2);

    final dflt = await PipelineConfig.load(
      file: await writeConfig(tmp, '{}'),
      env: {},
    );
    // wan3.0-video 720P 限时 7 折实价；原价 0.6 见
    // docs/万相视频生成与编辑成本核算_v1.0.md。
    expect(dflt.t2vYuanPerSecond, 0.42);
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

  test('image section defaults', () async {
    final c = await PipelineConfig.load(file: await writeConfig(tmp, '{}'), env: {});
    expect(c.imagePollSeconds, 5);
    expect(c.imageMaxWaitMinutes, 10);
    expect(c.imageDefaultModel, 'qwen-image-3.0-pro');
    expect(c.imagePrices, isEmpty);
    expect(c.videoPrices, isEmpty);
  });

  test('pricing tables parse model → tier → price', () async {
    final c = await PipelineConfig.load(
      file: await writeConfig(
        tmp,
        '{"image": {"poll_seconds": 3, "default_model": "wan2.7-image"},'
        ' "pricing": {"image": {"wan2.7-image-pro": {"2K": 0.5, "4K": 1.0}},'
        ' "video": {"wan3.0-video": {"720P": 0.42}}}}',
      ),
      env: {},
    );
    expect(c.imagePollSeconds, 3);
    expect(c.imageDefaultModel, 'wan2.7-image');
    expect(c.imagePrices['wan2.7-image-pro'], {'2K': 0.5, '4K': 1.0});
    expect(c.videoPrices['wan3.0-video'], {'720P': 0.42});
  });

  test('malformed pricing values are ignored', () async {
    final c = await PipelineConfig.load(
      file: await writeConfig(
        tmp,
        '{"pricing": {"image": {"x": {"2K": "free", "1K": 0.2}}, "video": []}}',
      ),
      env: {},
    );
    expect(c.imagePrices['x'], {'1K': 0.2});
    expect(c.videoPrices, isEmpty);
  });
}
