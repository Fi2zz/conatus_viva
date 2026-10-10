// 方言映射表：省/直辖市/主要城市名 → 方言标签 + TTS 指令句。
//
// Pure Dart — no Flutter imports, so the table can be unit-tested offline.
// Used by the TTS step to build the dialect instruction for synthesis.

/// A dialect label plus the instruction sentence sent to the TTS model.
///
/// [instruction] always ends with `。`, e.g. `请用河南话表达。`.
class DialectSpec {
  const DialectSpec(this.label, this.instruction);

  /// Machine-readable dialect tag (pinyin or conventional English),
  /// e.g. `henan`, `cantonese`, `mandarin`.
  final String label;

  /// Full instruction sentence for the TTS model, ending with `。`.
  final String instruction;

  @override
  String toString() => 'DialectSpec($label, $instruction)';
}

/// 普通话 — also the final fallback of the resolve chain.
const DialectSpec mandarinSpec = DialectSpec('mandarin', '请用普通话表达。');

const DialectSpec _cantonese = DialectSpec('cantonese', '请用广东话表达。');
const DialectSpec _chongqing = DialectSpec('chongqing', '请用重庆话表达。');
const DialectSpec _dongbei = DialectSpec('dongbei', '请用东北话表达。');
const DialectSpec _gansu = DialectSpec('gansu', '请用甘肃话表达。');
const DialectSpec _guizhou = DialectSpec('guizhou', '请用贵州话表达。');
const DialectSpec _zhejiang = DialectSpec('zhejiang', '请用浙江话表达。');
const DialectSpec _hebei = DialectSpec('hebei', '请用河北话表达。');
const DialectSpec _henan = DialectSpec('henan', '请用河南话表达。');
const DialectSpec _hubei = DialectSpec('hubei', '请用湖北话表达。');
const DialectSpec _hunan = DialectSpec('hunan', '请用湖南话表达。');
const DialectSpec _jiangxi = DialectSpec('jiangxi', '请用江西话表达。');
const DialectSpec _ningbo = DialectSpec('ningbo', '请用宁波话表达。');
const DialectSpec _ningxia = DialectSpec('ningxia', '请用宁夏话表达。');
const DialectSpec _qingdao = DialectSpec('qingdao', '请用青岛话表达。');
const DialectSpec _shaanxi = DialectSpec('shaanxi', '请用陕西话表达。');
const DialectSpec _shanxi = DialectSpec('shanxi', '请用山西话表达。');
const DialectSpec _shandong = DialectSpec('shandong', '请用山东话表达。');
const DialectSpec _shanghai = DialectSpec('shanghai', '请用上海话表达。');
const DialectSpec _sichuan = DialectSpec('sichuan', '请用四川话表达。');
const DialectSpec _yunnan = DialectSpec('yunnan', '请用云南话表达。');

/// Built-in region → dialect table covering the 21 spec dialects
/// (省名/直辖市 + 主要城市名). City keys share their province's spec, so
/// `郑州市` prefix-matches to the same entry as `河南`.
const Map<String, DialectSpec> kDialectTable = <String, DialectSpec>{
  '普通话': mandarinSpec,
  // 广东话
  '广东': _cantonese,
  '广州': _cantonese,
  '深圳': _cantonese,
  '珠海': _cantonese,
  '东莞': _cantonese,
  '佛山': _cantonese,
  // 重庆话
  '重庆': _chongqing,
  // 东北话
  '东北': _dongbei,
  '沈阳': _dongbei,
  '大连': _dongbei,
  '哈尔滨': _dongbei,
  '长春': _dongbei,
  '吉林': _dongbei,
  // 甘肃话
  '甘肃': _gansu,
  '兰州': _gansu,
  // 贵州话
  '贵州': _guizhou,
  '贵阳': _guizhou,
  '遵义': _guizhou,
  // 浙江话
  '浙江': _zhejiang,
  '杭州': _zhejiang,
  '温州': _zhejiang,
  '嘉兴': _zhejiang,
  '绍兴': _zhejiang,
  // 河北话
  '河北': _hebei,
  '石家庄': _hebei,
  '唐山': _hebei,
  '保定': _hebei,
  // 河南话
  '河南': _henan,
  '郑州': _henan,
  '洛阳': _henan,
  '开封': _henan,
  // 湖北话
  '湖北': _hubei,
  '武汉': _hubei,
  '宜昌': _hubei,
  '襄阳': _hubei,
  // 湖南话
  '湖南': _hunan,
  '长沙': _hunan,
  '株洲': _hunan,
  '湘潭': _hunan,
  // 江西话
  '江西': _jiangxi,
  '南昌': _jiangxi,
  '赣州': _jiangxi,
  // 宁波话
  '宁波': _ningbo,
  // 宁夏话
  '宁夏': _ningxia,
  '银川': _ningxia,
  // 青岛话
  '青岛': _qingdao,
  // 陕西话
  '陕西': _shaanxi,
  '西安': _shaanxi,
  '咸阳': _shaanxi,
  '宝鸡': _shaanxi,
  // 山西话
  '山西': _shanxi,
  '太原': _shanxi,
  '大同': _shanxi,
  // 山东话
  '山东': _shandong,
  '济南': _shandong,
  '烟台': _shandong,
  '潍坊': _shandong,
  // 上海话
  '上海': _shanghai,
  // 四川话
  '四川': _sichuan,
  '成都': _sichuan,
  '绵阳': _sichuan,
  // 云南话
  '云南': _yunnan,
  '昆明': _yunnan,
  '大理': _yunnan,
};

/// Resolves [region] to a dialect spec via the fallback chain:
///
/// 1. exact or prefix hit in [table] (defaults to [kDialectTable]),
/// 2. hit in [nearby] (the caller-injected "nearest dialect" map,
///    defaults to empty),
/// 3. [mandarinSpec].
///
/// Prefix matching lets `郑州市` / `河南省` resolve to the same entry as
/// `郑州` / `河南`. Regions outside the 21-dialect coverage (e.g. an
/// unknown city) fall through to [mandarinSpec].
DialectSpec resolveDialect(
  String region, {
  Map<String, DialectSpec>? table,
  Map<String, DialectSpec>? nearby,
}) {
  return _lookup(table ?? kDialectTable, region) ??
      _lookup(nearby, region) ??
      mandarinSpec;
}

/// Exact lookup first, then longest table key that [region] starts with.
DialectSpec? _lookup(Map<String, DialectSpec>? map, String region) {
  if (map == null || map.isEmpty) return null;
  final exact = map[region];
  if (exact != null) return exact;
  String? bestKey;
  for (final key in map.keys) {
    if (region.startsWith(key) &&
        (bestKey == null || key.length > bestKey.length)) {
      bestKey = key;
    }
  }
  if (bestKey == null) return null;
  return map[bestKey];
}
