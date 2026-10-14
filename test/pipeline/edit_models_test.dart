import 'package:flutter_wanxiang/pipeline/edit_models.dart';
import 'package:test/test.dart';

void main() {
  test('catalog lists the three edit models with spec prices', () {
    expect(kEditModels.map((m) => m.id).toList(), [
      'wan2.7-videoedit',
      'happyhorse-1.0-video-edit',
      'wanx2.1-vace-plus',
    ]);

    final wan = kEditModels[0];
    expect(wan.billing, EditBilling.inputOutput);
    expect([wan.inputMinS, wan.inputMaxS], [2, 10]);
    expect(wan.outputMode, EditOutputMode.sameAsInput);
    expect(wan.freeQuotaS, 50);
    expect(wan.resolutions.map((r) => r.yuanPerSecond).toList(), [0.6, 1.0]);

    final hh = kEditModels[1];
    expect(hh.billing, EditBilling.inputOutput);
    expect([hh.inputMinS, hh.inputMaxS], [3, 60]);
    expect(hh.outputMode, EditOutputMode.min);
    expect(hh.outputValue, 15);
    expect(hh.resolutions.map((r) => r.yuanPerSecond).toList(), [0.9, 1.6]);

    final vace = kEditModels[2];
    expect(vace.billing, EditBilling.outputOnly);
    expect([vace.inputMinS, vace.inputMaxS], [0, 5]);
    expect(vace.outputMode, EditOutputMode.fixed);
    expect(vace.outputValue, 5);
    expect(vace.resolutions.map((r) => r.label).toList(), ['720P']);
    expect(vace.resolutions.single.yuanPerSecond, 0.70);
  });

  test('toJson emits the wire shape the frontend reads', () {
    final wan = kEditModels[0].toJson();
    expect(wan['billing'], 'input_output');
    expect(wan['input_min_s'], 2);
    expect((wan['output'] as Map)['mode'], 'same_as_input');
    expect((wan['output'] as Map).containsKey('value'), isFalse);
    expect((wan['resolutions'] as List).first,
        {'label': '720P', 'yuan_per_second': 0.6});

    expect(kEditModels[2].toJson()['billing'], 'output');
  });
}
