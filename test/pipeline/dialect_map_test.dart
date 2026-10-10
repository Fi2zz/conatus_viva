import 'package:flutter_wanxiang/pipeline/dialect_map.dart';
import 'package:test/test.dart';

void main() {
  test('hits henan instruction from spec list', () {
    expect(resolveDialect('河南').label, 'henan');
    expect(resolveDialect('河南').instruction, '请用河南话表达。');
  });

  test('falls back to nearby then mandarin', () {
    expect(
      resolveDialect(
        '三沙',
        nearby: {'三沙': DialectSpec('hainan-ish', '请用海南话表达。')},
      ).label,
      'hainan-ish',
    );
    expect(resolveDialect('somewhere-unknown').label, 'mandarin');
  });

  test('covers all 21 dialects from the spec list', () {
    const expected = <String, String>{
      '普通话': 'mandarin',
      '广东': 'cantonese',
      '重庆': 'chongqing',
      '东北': 'dongbei',
      '甘肃': 'gansu',
      '贵州': 'guizhou',
      '浙江': 'zhejiang',
      '河北': 'hebei',
      '河南': 'henan',
      '湖北': 'hubei',
      '湖南': 'hunan',
      '江西': 'jiangxi',
      '宁波': 'ningbo',
      '宁夏': 'ningxia',
      '青岛': 'qingdao',
      '陕西': 'shaanxi',
      '山西': 'shanxi',
      '山东': 'shandong',
      '上海': 'shanghai',
      '四川': 'sichuan',
      '云南': 'yunnan',
    };
    for (final entry in expected.entries) {
      final spec = resolveDialect(entry.key);
      expect(spec.label, entry.value, reason: 'label for ${entry.key}');
      final instruction = entry.key == '普通话'
          ? '请用普通话表达。'
          : '请用${entry.key}话表达。';
      expect(
        spec.instruction,
        instruction,
        reason: 'instruction for ${entry.key}',
      );
    }
  });

  test('prefix-matches province suffixes and major city names', () {
    expect(resolveDialect('河南省').label, 'henan');
    expect(resolveDialect('郑州市').label, 'henan');
    expect(resolveDialect('成都市').label, 'sichuan');
    expect(resolveDialect('广州市').instruction, '请用广东话表达。');
    expect(resolveDialect('青岛市').label, 'qingdao');
  });

  test('uses a caller-provided table when given', () {
    final spec = resolveDialect(
      '测试',
      table: {'测试': DialectSpec('test-dialect', '请用测试话表达。')},
    );
    expect(spec.label, 'test-dialect');
    expect(spec.instruction, '请用测试话表达。');
  });
}
