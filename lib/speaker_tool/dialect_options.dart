/// 主讲人工具可选的方言类型。
///
/// 与 pipeline/dialect_map.dart 中的 21 种方言保持一致，
/// 仅暴露常用标签供下拉选择。
class DialectOption {
  const DialectOption(this.label, this.displayName);

  /// 机器可读标签，如 `henan`。
  final String label;

  /// 中文展示名，如 `河南话`。
  final String displayName;
}

/// 主讲人工具支持的方言列表（按使用频率排序）。
const List<DialectOption> kDialectOptions = <DialectOption>[
  DialectOption('mandarin', '普通话'),
  DialectOption('dongbei', '东北话'),
  DialectOption('henan', '河南话'),
  DialectOption('sichuan', '四川话'),
  DialectOption('cantonese', '广东话'),
  DialectOption('shaanxi', '陕西话'),
  DialectOption('shandong', '山东话'),
  DialectOption('chongqing', '重庆话'),
  DialectOption('shanghai', '上海话'),
  DialectOption('hunan', '湖南话'),
  DialectOption('hubei', '湖北话'),
  DialectOption('jiangxi', '江西话'),
  DialectOption('hebei', '河北话'),
  DialectOption('shanxi', '山西话'),
  DialectOption('zhejiang', '浙江话'),
  DialectOption('ningbo', '宁波话'),
  DialectOption('qingdao', '青岛话'),
  DialectOption('gansu', '甘肃话'),
  DialectOption('guizhou', '贵州话'),
  DialectOption('yunnan', '云南话'),
  DialectOption('ningxia', '宁夏话'),
];
