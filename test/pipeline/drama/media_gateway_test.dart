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

  test('composeEdit concatenates aligned vertical parts with audio', () async {
    final cfg = await _cfg(temp);
    final gateway = DashScopeDramaMediaGateway(cfg: cfg, pricing: _pricing());
    final image = await _image(temp);
    final clipA = File('${temp.path}/a.mp4');
    final clipB = File('${temp.path}/b.mp4');
    await gateway.renderLocalClip(
      image: image,
      outFile: clipA,
      route: ShotRoute.kenburns,
      width: 1080,
      height: 1920,
      durationS: 2,
    );
    await gateway.renderLocalClip(
      image: image,
      outFile: clipB,
      route: ShotRoute.micro,
      width: 1080,
      height: 1920,
      durationS: 2,
    );
    expect(await mediaDurationSeconds(clipA), closeTo(2, 0.3));
    expect(await mediaDurationSeconds(clipB), closeTo(2, 0.3));
    final audio = File('${temp.path}/line.wav');
    final r = await Process.run('ffmpeg', <String>[
      '-y',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=1',
      '-ar',
      '24000',
      '-ac',
      '1',
      audio.path,
    ]);
    expect(r.exitCode, 0);
    final out = File('${temp.path}/final.mp4');
    await gateway.composeEdit(
      parts: <DramaEditPart>[
        DramaEditPart(clip: clipA, durationS: 2, audio: audio, audioS: 1),
        DramaEditPart(clip: clipB, durationS: 2),
      ],
      outFile: out,
      width: 1080,
      height: 1920,
      onLog: (_) {},
    );
    expect(out.existsSync(), isTrue);
    expect(await mediaDurationSeconds(out), closeTo(4, 0.5));
    expect(await streamDurationSeconds(out, 'a:0'), greaterThan(3));
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
