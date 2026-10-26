import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/drama/pricing.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('conatus_pricing_test');
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('config overrides win over catalog defaults', () async {
    final file = File('${temp.path}/cfg.json')
      ..writeAsStringSync(
        '{"pricing": {"image": {"wan2.7-image": {"1K": 0.5}}, '
        '"video": {"wan2.6-i2v-flash": {"720P": 0.2}}}}',
      );
    final cfg = await PipelineConfig.load(file: file, env: const <String, String>{});
    final pricing = dramaPricingFromConfig(cfg);
    expect(pricing.imagePrice('wan2.7-image', '1K'), 0.5);
    expect(pricing.videoPrice('wan2.6-i2v-flash', '720P'), 0.2);
    expect(pricing.i2vYuanPerSecond, 0.2);
  });

  test('missing model fails loudly instead of returning zero', () async {
    final file = File('${temp.path}/cfg.json')..writeAsStringSync('{}');
    final cfg = await PipelineConfig.load(file: file, env: const <String, String>{});
    final pricing = dramaPricingFromConfig(cfg);
    expect(
      () => pricing.imagePrice('no-such-model', '1K'),
      throwsA(isA<StateError>()),
    );
  });
}
