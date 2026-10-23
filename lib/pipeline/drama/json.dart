/// 短剧 JSON 读取助手（纯 Dart，无 Flutter 依赖）。
///
/// 所有类型错误统一抛 `PipelineError(ErrorClass.fatal, ...)`，与
/// `storyboard.dart` 的解析契约一致；调用方负责把可恢复问题降级成 warning。
library;

import '../errors.dart';

/// 把任意 Map 复制成 `Map<String, Object?>`；非字符串 key 视为模式错误。
Map<String, Object?> asJsonMap(Object? raw, String field) {
  if (raw is! Map) {
    throw PipelineError(ErrorClass.fatal, '$field 必须是对象：$raw');
  }
  final out = <String, Object?>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) {
      throw PipelineError(ErrorClass.fatal, '$field 的 key 必须是字符串：$key');
    }
    out[key] = entry.value;
  }
  return out;
}

/// 把任意 List 复制成 `List<Object?>`；非数组视为模式错误。
List<Object?> asJsonList(Object? raw, String field) {
  if (raw is! List) {
    throw PipelineError(ErrorClass.fatal, '$field 必须是数组：$raw');
  }
  return List<Object?>.from(raw);
}

/// 必填字符串。
String requireJsonString(Object? raw, String field) {
  if (raw is! String) {
    throw PipelineError(ErrorClass.fatal, '$field 必须是字符串：$raw');
  }
  return raw;
}

/// 可选字符串；null 保持 null，其他非字符串抛错。
String? optionalJsonString(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! String) {
    throw PipelineError(ErrorClass.fatal, '$field 必须是字符串：$raw');
  }
  return raw;
}

/// 可选有限数字；NaN / Infinity / 非数字抛错。
double? optionalJsonNumber(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! num) {
    throw PipelineError(ErrorClass.fatal, '$field 必须是数字：$raw');
  }
  final value = raw.toDouble();
  if (!value.isFinite) {
    throw PipelineError(ErrorClass.fatal, '$field 必须是有限数字：$raw');
  }
  return value;
}

/// 可选整数；非 int 抛错。
int? optionalJsonInt(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! int) {
    throw PipelineError(ErrorClass.fatal, '$field 必须是整数：$raw');
  }
  return raw;
}

/// 可选布尔；null / 非 bool 使用 [fallback]。
bool optionalJsonBool(Object? raw, String field, {required bool fallback}) {
  if (raw == null) return fallback;
  if (raw is! bool) {
    throw PipelineError(ErrorClass.fatal, '$field 必须是布尔值：$raw');
  }
  return raw;
}
