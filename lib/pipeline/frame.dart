/// 输出画幅值对象（纯 Dart，无 Flutter 依赖）。
///
/// 画幅只描述成片的画布比例，渲染阶段可以按目录价选择更低的生成分辨率
/// 再放大；解析失败一律由调用方转成 `PipelineError.fatal`。
library;

import 'errors.dart';

class FrameSize {
  const FrameSize(this.width, this.height);

  /// 短剧默认竖屏画布：1080×1920。
  static const FrameSize vertical = FrameSize(1080, 1920);

  final int width;
  final int height;

  /// 竖屏判定：高度严格大于宽度（正方形不算竖屏）。
  bool get isVertical => height > width;

  /// 规范化后的 `宽x高` 字符串，用于 storyboard wire 格式。
  String get label => '${width}x$height';

  Map<String, Object?> toJson() => <String, Object?>{
    'width': width,
    'height': height,
  };

  /// 解析 `1080x1920` / `1080*1920`；格式非法或宽高非正整数返回 null。
  static FrameSize? tryParse(String raw) {
    final parts = raw.trim().split(RegExp(r'[x*]'));
    if (parts.length != 2) return null;
    final width = _positiveInt(parts[0].trim());
    final height = _positiveInt(parts[1].trim());
    if (width == null || height == null) return null;
    return FrameSize(width, height);
  }

  /// 严格解析：非字符串或非法尺寸直接抛 `PipelineError.fatal`。
  static FrameSize fromJson(Object? raw) {
    if (raw is! String) {
      throw PipelineError(ErrorClass.fatal, 'frame 必须是 "宽x高" 字符串：$raw');
    }
    final parsed = tryParse(raw);
    if (parsed == null) {
      throw PipelineError(ErrorClass.fatal, 'frame 非法：$raw（应为 宽x高，宽高为正整数）');
    }
    return parsed;
  }

  static int? _positiveInt(String raw) {
    if (!RegExp(r'^\d+$').hasMatch(raw)) return null;
    final value = int.tryParse(raw);
    if (value == null || value <= 0) return null;
    return value;
  }

  @override
  String toString() => 'FrameSize($label)';
}
