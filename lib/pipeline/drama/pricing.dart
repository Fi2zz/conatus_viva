/// 短剧定价：把 configuration / catalog 的单价解析成可注入的函数。
library;

import '../config.dart';
import '../generation_models.dart';
import '../render_plan.dart';

typedef ImageUnitPrice = double Function(String model, String tier);
typedef VideoUnitPrice = double Function(String model, String resolution);

class DramaPricing {
  const DramaPricing({
    required this.i2vYuanPerSecond,
    required this.imagePrice,
    required this.videoPrice,
  });

  /// 计划单默认 i2v 单价（元/秒）。
  final double i2vYuanPerSecond;

  /// 图片模型 + 档位（`1K` / `2K` / `4K`）→ 元/张。
  final ImageUnitPrice imagePrice;

  /// 视频模型 + 分辨率 → 元/秒。
  final VideoUnitPrice videoPrice;

  static double _imageFromCatalog(String model, String tier) {
    final found = findImageModel(model);
    if (found == null) {
      throw StateError('未知图片模型：$model');
    }
    final price = found.defaultPrices[tier];
    if (price == null) {
      throw StateError('图片目录缺少 $model / $tier 的价格');
    }
    return price;
  }

  static double _videoFromCatalog(String model, String resolution) {
    final found = findVideoModel(model);
    if (found == null) {
      throw StateError('未知视频模型：$model');
    }
    final price = found.defaultPrices[resolution];
    if (price == null) {
      throw StateError('视频目录缺少 $model / $resolution 的价格');
    }
    return price;
  }

  /// 目录默认价，供测试与无配置环境使用。
  factory DramaPricing.catalog() => DramaPricing(
    i2vYuanPerSecond: _videoFromCatalog(
      kPlanI2vModel,
      kPlanI2vResolution,
    ),
    imagePrice: _imageFromCatalog,
    videoPrice: _videoFromCatalog,
  );
}

/// 按 `pipeline_config.json` 的 pricing 覆盖解析，目录价兜底。
DramaPricing dramaPricingFromConfig(PipelineConfig cfg) {
  double imagePrice(String model, String tier) {
    final found = findImageModel(model);
    if (found == null) {
      throw StateError('未知图片模型：$model');
    }
    final prices = resolvePrices(
      defaults: found.defaultPrices,
      overrides: cfg.imagePrices,
      model: model,
    );
    final price = prices[tier];
    if (price == null) {
      throw StateError('图片目录缺少 $model / $tier 的价格');
    }
    return price;
  }

  double videoPrice(String model, String resolution) {
    final found = findVideoModel(model);
    if (found == null) {
      throw StateError('未知视频模型：$model');
    }
    final prices = resolvePrices(
      defaults: found.defaultPrices,
      overrides: cfg.videoPrices,
      model: model,
    );
    final price = prices[resolution];
    if (price == null) {
      throw StateError('视频目录缺少 $model / $resolution 的价格');
    }
    return price;
  }

  return DramaPricing(
    i2vYuanPerSecond: videoPrice(cfg.i2vModel, cfg.i2vResolution),
    imagePrice: imagePrice,
    videoPrice: videoPrice,
  );
}
