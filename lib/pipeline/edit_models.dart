// 万相「视频编辑」模型目录与计费口径（纯 Dart，无 Flutter 依赖）。
//
// 单价与限制来自 `docs/万相视频生成与编辑成本核算_v1.0.md`（华北2 北京，
// 2026-10 核对）。只读数据，前端经 `GET /api/edit-models` 消费。

/// 计费口径。
enum EditBilling {
  /// 输入视频与输出视频都计费（计费时长 = 输入 + 输出）。
  inputOutput,

  /// 仅输出视频计费。
  outputOnly,
}

/// 输出时长如何由输入时长推导。
enum EditOutputMode {
  /// 输出 = 输入（不截断）。
  sameAsInput,

  /// 输出固定为 [EditModel.outputValue] 秒。
  fixed,

  /// 输出 = min(输入, [EditModel.outputValue])。
  min,
}

/// 某个分辨率档位的单价（元/秒）。
class EditResolution {
  const EditResolution({required this.label, required this.yuanPerSecond});

  final String label;
  final double yuanPerSecond;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'yuan_per_second': yuanPerSecond,
  };
}

/// 一个「视频编辑」模型的价格与能力限制。
class EditModel {
  const EditModel({
    required this.id,
    required this.name,
    required this.billing,
    required this.inputMinS,
    required this.inputMaxS,
    required this.outputMode,
    this.outputValue,
    required this.resolutions,
    required this.freeQuotaS,
    required this.note,
  });

  final String id;
  final String name;
  final EditBilling billing;

  /// 允许的输入素材时长下限（秒）。
  final int inputMinS;

  /// 允许的输入素材时长上限（秒）。
  final int inputMaxS;

  final EditOutputMode outputMode;

  /// [EditOutputMode.fixed] / [EditOutputMode.min] 的秒数；
  /// [EditOutputMode.sameAsInput] 时为 null。
  final int? outputValue;

  final List<EditResolution> resolutions;

  /// 免费额度（秒，仅华北2 北京地域有）。
  final int freeQuotaS;

  final String note;

  /// 下发给前端的线格式（字段名与 `frontend/src/editCost.ts` 的 `EditModel` 对齐）。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'billing': billing == EditBilling.inputOutput ? 'input_output' : 'output',
    'input_min_s': inputMinS,
    'input_max_s': inputMaxS,
    'output': <String, Object?>{
      'mode': switch (outputMode) {
        EditOutputMode.sameAsInput => 'same_as_input',
        EditOutputMode.fixed => 'fixed',
        EditOutputMode.min => 'min',
      },
      if (outputValue != null) 'value': outputValue,
    },
    'resolutions': [for (final r in resolutions) r.toJson()],
    'free_quota_s': freeQuotaS,
    'note': note,
  };
}

/// 三个「视频编辑」模型，顺序即 UI 展示顺序。
///
/// 数值必须与 `docs/万相视频生成与编辑成本核算_v1.0.md` 逐字一致。
const List<EditModel> kEditModels = <EditModel>[
  EditModel(
    id: 'wan2.7-videoedit',
    name: '万相2.7-视频编辑',
    billing: EditBilling.inputOutput,
    inputMinS: 2,
    inputMaxS: 10,
    outputMode: EditOutputMode.sameAsInput,
    resolutions: <EditResolution>[
      EditResolution(label: '720P', yuanPerSecond: 0.6),
      EditResolution(label: '1080P', yuanPerSecond: 1.0),
    ],
    freeQuotaS: 50,
    note: '指令编辑 + 视频迁移；输入和输出都计费',
  ),
  EditModel(
    id: 'happyhorse-1.0-video-edit',
    name: 'HappyHorse-视频编辑',
    billing: EditBilling.inputOutput,
    inputMinS: 3,
    inputMaxS: 60,
    outputMode: EditOutputMode.min,
    outputValue: 15,
    resolutions: <EditResolution>[
      EditResolution(label: '720P', yuanPerSecond: 0.9),
      EditResolution(label: '1080P', yuanPerSecond: 1.6),
    ],
    freeQuotaS: 10,
    note: '指令编辑 + 局部替换；输出超 15s 自动截断，输入和输出都计费',
  ),
  EditModel(
    id: 'wanx2.1-vace-plus',
    name: '万相-视频编辑（VACE）',
    billing: EditBilling.outputOnly,
    inputMinS: 0,
    inputMaxS: 5,
    outputMode: EditOutputMode.fixed,
    outputValue: 5,
    resolutions: <EditResolution>[
      EditResolution(label: '720P', yuanPerSecond: 0.70),
    ],
    freeQuotaS: 50,
    note: '显式 mask 局部编辑；仅输出计费，5s 定长、720P、无声',
  ),
];
