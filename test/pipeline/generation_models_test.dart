import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:test/test.dart';

void main() {
  test('catalog covers the five image models with their capabilities', () {
    expect(kImageModels.map((m) => m.id), [
      'qwen-image-3.0-pro',
      'qwen-image-3.0',
      'wan2.7-image-pro',
      'wan2.7-image',
      'z-image-turbo',
    ]);
    final z = findImageModel('z-image-turbo')!;
    expect(z.modes, {ImageMode.t2i});
    expect(z.maxImages, 1);
    expect(findImageModel('wan2.7-image')!.modes, contains(ImageMode.series));
    expect(findImageModel('qwen-image-3.0')!.maxRefImages, 3);
  });

  test('video catalog covers wan3.0 t2v/i2v and the wan2.6 i2v flash', () {
    expect(kVideoModels.map((m) => m.id), [
      'wan3.0-video',
      'wan3.0-video-prime',
      'wan2.6-i2v-flash',
    ]);
    expect(findVideoModel('wan3.0-video')!.modes, {
      VideoMode.t2v,
      VideoMode.i2v,
    });
    expect(findVideoModel('wan3.0-video-prime')!.modes, {
      VideoMode.t2v,
      VideoMode.i2v,
    });
    final flash = findVideoModel('wan2.6-i2v-flash')!;
    expect(flash.modes, {VideoMode.i2v});
    expect(flash.resolutions, ['720P', '1080P']);
    expect(flash.durationMin, 2);
    expect(flash.durationMax, 15);
    expect(flash.supportsAudio, isFalse);
    expect(flash.defaultPrices, {'720P': 0.15, '1080P': 0.25});
  });

  test('priceTierFor maps pixel sizes by area', () {
    expect(priceTierFor(null), '2K');
    expect(priceTierFor('1K'), '1K');
    expect(priceTierFor('1024*1024'), '1K');
    expect(priceTierFor('2048*2048'), '2K');
    expect(priceTierFor('4096*4096'), '4K');
    expect(priceTierFor('abc'), '2K');
  });

  test('resolvePrices lets config override catalog defaults per tier', () {
    final merged = resolvePrices(
      defaults: {'2K': 0.5},
      overrides: {
        'qwen-image-3.0-pro': {'1K': 0.35},
      },
      model: 'qwen-image-3.0-pro',
    );
    expect(merged, {'2K': 0.5, '1K': 0.35});
  });

  test('unitPrice falls back to the cheapest configured tier', () {
    expect(unitPrice(prices: {'1K': 0.2, '2K': 0.5}, tier: '4K'), 0.2);
    expect(unitPrice(prices: {'2K': 0.5}, tier: '2K'), 0.5);
    expect(unitPrice(prices: {}, tier: '2K'), 0);
  });
}
