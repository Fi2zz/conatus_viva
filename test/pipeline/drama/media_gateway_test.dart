import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/drama/media_gateway.dart';
import 'package:flutter_wanxiang/pipeline/drama/pricing.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/ffmpeg.dart';
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:flutter_wanxiang/pipeline/render_plan.dart';
import 'package:test/test.dart';

DramaPricing _pricing() => DramaPricing(
  i2vYuanPerSecond: 0.15,
  imagePrice: (_, _) => 0.2,
  videoPrice: (_, _) => 0.15,
);

Future<PipelineConfig> _cfg(Directory dir, {String? key}) async {
  final file = File('${dir.path}/cfg.json')..writeAsStringSync('{}');
  final cfg = await PipelineConfig.load(
    file: file,
    env: const <String, String>{},
  );
  if (key != null) cfg.updateSecrets(<String, String?>{'DASHSCOPE_API_KEY': key});
  return cfg;
}

Future<File> _image(Directory dir) async {
  final out = File('${dir.path}/src.png');
  final r = await Process.run('ffmpeg', <String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'color=c=red:s=320x240:d=1',
    '-frames:v',
    '1',
    out.path,
  ]);
  if (r.exitCode != 0) throw StateError('${r.stderr}');
  return out;
}

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('conatus_gateway_test');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('image generation fails before network when API key is missing', () async {
    final cfg = await _cfg(temp);
    final gateway = DashScopeDramaMediaGateway(cfg: cfg, pricing: _pricing());
    expect(
      () => gateway.generateImage(
        model: 'wan2.7-image',
        mode: ImageMode.t2i,
        prompt: 'x',
        baseDir: temp.path,
        contentId: 'hash',
        onLog: (_) {},
      ),
      throwsA(isA<ConfigException>()),
    );
  });

  test('unknown image model fails before network', () async {
    final cfg = await _cfg(temp, key: 'sk-test');
    final gateway = DashScopeDramaMediaGateway(cfg: cfg, pricing: _pricing());
    expect(
      () => gateway.generateImage(
        model: 'no-such-model',
        mode: ImageMode.t2i,
        prompt: 'x',
        baseDir: temp.path,
        contentId: 'hash',
        onLog: (_) {},
      ),
      throwsA(isA<PipelineError>()),
    );
  });

  test('i2v fails before network when API key is missing', () async {
    final cfg = await _cfg(temp);
    final gateway = DashScopeDramaMediaGateway(cfg: cfg, pricing: _pricing());
    expect(
      () => gateway.generateI2vClip(
        model: 'wan2.6-i2v-flash',
        resolution: '720P',
        firstFrame: File('${temp.path}/missing.png'),
        prompt: 'x',
        durationS: 3,
        outFile: File('${temp.path}/out.mp4'),
        onLog: (_) {},
      ),
      throwsA(isA<ConfigException>()),
    );
  });

  test('local clip writes a playable vertical mp4 at zero cost', () async {
    final cfg = await _cfg(temp);
    final gateway = DashScopeDramaMediaGateway(cfg: cfg, pricing: _pricing());
    final image = await _image(temp);
    final out = File('${temp.path}/local.mp4');
    await gateway.renderLocalClip(
      image: image,
      outFile: out,
      route: ShotRoute.kenburns,
      width: 1080,
      height: 1920,
      durationS: 2,
    );
    expect(out.existsSync(), isTrue);
    expect(await mediaDurationSeconds(out), closeTo(2.0, 0.2));
  });

  test('normalizeClip writes the requested vertical size', () async {
    final cfg = await _cfg(temp);
    final gateway = DashScopeDramaMediaGateway(cfg: cfg, pricing: _pricing());
    final image = await _image(temp);
    final src = File('${temp.path}/src.mp4');
    await gateway.renderLocalClip(
      image: image,
      outFile: src,
      route: ShotRoute.micro,
      width: 1280,
      height: 720,
      durationS: 2,
    );
    final out = File('${temp.path}/norm.mp4');
    await gateway.normalizeClip(
      input: src,
      outFile: out,
      width: 1080,
      height: 1920,
    );
    expect(out.existsSync(), isTrue);
    expect(await mediaDurationSeconds(out), closeTo(2.0, 0.2));
  });
}
