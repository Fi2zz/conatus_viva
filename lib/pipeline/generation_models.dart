// 图片 / 视频生成模型目录（纯 Dart，无 Flutter 依赖）。
//
// 能力边界与单价是前端、server 与管线共用的唯一事实来源：UI 从
// `GET /api/models` 读，Dart 侧从本文件读，任何地方都不再按模型名硬编码分支。
// 单价默认值取自 `docs/万相视频生成与编辑成本核算_v1.0.md` 与百炼控制台
// （2026-10 核对），配置 `pricing.*` 可逐档覆盖。

/// 一次生成产出的类型。
enum GenerationKind { image, video }

/// 图片模型的接口族——决定提交端点、请求体结构与响应解析方式。
enum ImageFamily { qwen3, wan27, zImage }

/// 图片合成的子模式。
enum ImageMode { t2i, i2i, series }

/// 一个图片模型的能力边界与默认单价。
class ImageModel {
  const ImageModel({
    required this.id,
    required this.label,
    required this.family,
    required this.modes,
    required this.maxImages,
    required this.maxRefImages,
    required this.supportsNegativePrompt,
    required this.sizes,
    required this.defaultPrices,
  });

  final String id;
  final String label;
  final ImageFamily family;
  final Set<ImageMode> modes;

  /// 关闭组图时的最大输出张数。
  final int maxImages;

  /// 图生图可传入的参考图上限（0 = 不支持图生图）。
  final int maxRefImages;

  final bool supportsNegativePrompt;

  /// 下发给 UI 的尺寸候选；`'1K'`/`'2K'`/`'4K'` 表示档位，`宽*高` 表示像素。
  final List<String> sizes;

  /// 价格档位 → 元/张。
  final Map<String, double> defaultPrices;

  Map<String, Object?> toJson(Map<String, double> prices) => <String, Object?>{
    'id': id,
    'label': label,
    'family': family.name,
    'modes': [for (final m in modes) m.name],
    'max_images': maxImages,
    'max_ref_images': maxRefImages,
    'supports_negative_prompt': supportsNegativePrompt,
    'sizes': sizes,
    'prices': prices,
  };
}

/// 一个文生视频模型的分辨率档、时长区间与默认单价。
class VideoModel {
  const VideoModel({
    required this.id,
    required this.label,
    required this.resolutions,
    required this.durationMin,
    required this.durationMax,
    required this.supportsAudio,
    required this.defaultPrices,
  });

  final String id;
  final String label;
  final List<String> resolutions;
  final int durationMin;
  final int durationMax;
  final bool supportsAudio;

  /// 分辨率档 → 元/秒。
  final Map<String, double> defaultPrices;

  Map<String, Object?> toJson(Map<String, double> prices) => <String, Object?>{
    'id': id,
    'label': label,
    'kind': GenerationKind.video.name,
    'resolutions': resolutions,
    'duration_min': durationMin,
    'duration_max': durationMax,
    'supports_audio': supportsAudio,
    'prices': prices,
  };
}

/// 顺序即 UI 展示顺序。
const List<ImageModel> kImageModels = <ImageModel>[
  ImageModel(
    id: 'qwen-image-3.0-pro',
    label: '千问图像 3.0 Pro',
    family: ImageFamily.qwen3,
    modes: <ImageMode>{ImageMode.t2i, ImageMode.i2i},
    maxImages: 6,
    maxRefImages: 3,
    supportsNegativePrompt: true,
    sizes: <String>['1024*1024', '1536*2688', '2688*1536', '2048*2048'],
    defaultPrices: <String, double>{'1K': 0.35, '2K': 0.5},
  ),
  ImageModel(
    id: 'qwen-image-3.0',
    label: '千问图像 3.0',
    family: ImageFamily.qwen3,
    modes: <ImageMode>{ImageMode.t2i, ImageMode.i2i},
    maxImages: 6,
    maxRefImages: 3,
    supportsNegativePrompt: true,
    sizes: <String>['1024*1024', '1536*2688', '2688*1536', '2048*2048'],
    defaultPrices: <String, double>{'1K': 0.2, '2K': 0.3},
  ),
  ImageModel(
    id: 'wan2.7-image-pro',
    label: '万相图像 2.7 Pro',
    family: ImageFamily.wan27,
    modes: <ImageMode>{ImageMode.t2i, ImageMode.i2i, ImageMode.series},
    maxImages: 4,
    maxRefImages: 9,
    supportsNegativePrompt: false,
    sizes: <String>['1K', '2K', '4K'],
    defaultPrices: <String, double>{'1K': 0.35, '2K': 0.5, '4K': 1.0},
  ),
  ImageModel(
    id: 'wan2.7-image',
    label: '万相图像 2.7',
    family: ImageFamily.wan27,
    modes: <ImageMode>{ImageMode.t2i, ImageMode.i2i, ImageMode.series},
    maxImages: 4,
    maxRefImages: 9,
    supportsNegativePrompt: false,
    sizes: <String>['1K', '2K'],
    defaultPrices: <String, double>{'1K': 0.2, '2K': 0.3},
  ),
  ImageModel(
    id: 'z-image-turbo',
    label: 'Z-Image Turbo',
    family: ImageFamily.zImage,
    modes: <ImageMode>{ImageMode.t2i},
    maxImages: 1,
    maxRefImages: 0,
    supportsNegativePrompt: false,
    sizes: <String>['1024*1024', '2048*2048'],
    defaultPrices: <String, double>{'2K': 0.1},
  ),
];

/// 通用文生视频页可选的模型（不含需要首帧图片的 i2v）。
const List<VideoModel> kTextToVideoModels = <VideoModel>[
  VideoModel(
    id: 'wan3.0-video',
    label: '万相 3.0',
    resolutions: <String>['480P', '720P', '1080P'],
    durationMin: 2,
    durationMax: 30,
    supportsAudio: true,
    defaultPrices: <String, double>{
      '480P': 0.21,
      '720P': 0.42,
      '1080P': 0.84,
    },
  ),
  VideoModel(
    id: 'wan3.0-video-prime',
    label: '万相 3.0 Prime',
    resolutions: <String>['480P', '720P', '1080P'],
    durationMin: 2,
    durationMax: 30,
    supportsAudio: true,
    defaultPrices: <String, double>{
      '480P': 0.45,
      '720P': 0.9,
      '1080P': 1.8,
    },
  ),
];

/// The image model named [id], or null when the catalog does not know it.
ImageModel? findImageModel(String id) {
  for (final model in kImageModels) {
    if (model.id == id) return model;
  }
  return null;
}

/// The text-to-video model named [id], or null when it is not generatable.
VideoModel? findTextToVideoModel(String id) {
  for (final model in kTextToVideoModels) {
    if (model.id == id) return model;
  }
  return null;
}

/// 尺寸 → 价格档位。像素尺寸按面积判定（与百炼 `qima_*_1k/2k` 口径一致），
/// 无法解析时保守按 `2K` 估算。
String priceTierFor(String? size) {
  if (size == null || size.isEmpty) return '2K';
  const tiers = <String>{'1K', '2K', '4K'};
  if (tiers.contains(size)) return size;

  final parts = size.split('*');
  if (parts.length != 2) return '2K';
  final width = int.tryParse(parts[0]);
  final height = int.tryParse(parts[1]);
  if (width == null || height == null || width <= 0 || height <= 0) return '2K';

  final area = width * height;
  if (area <= 2250000) return '1K';
  if (area <= 4194304) return '2K';
  return '4K';
}

/// 目录默认价 + 配置覆盖（配置逐档生效，未覆盖的档位保留默认值）。
Map<String, double> resolvePrices({
  required Map<String, double> defaults,
  required Map<String, Map<String, double>> overrides,
  required String model,
}) {
  final override = overrides[model];
  if (override == null || override.isEmpty) return defaults;
  return <String, double>{...defaults, ...override};
}

/// 指定档位的单价；档位缺失时回落到最便宜档，空表返回 0。
double unitPrice({required Map<String, double> prices, required String tier}) {
  final exact = prices[tier];
  if (exact != null) return exact;
  if (prices.isEmpty) return 0;
  return prices.values.reduce((a, b) => a < b ? a : b);
}
