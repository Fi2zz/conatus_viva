/// 短剧领域 ID 校验（纯 Dart，无 Flutter 依赖）。
///
/// 所有会落盘的 id（剧 / 集 / 角色 / 镜头）都只允许 `[A-Za-z0-9_-]`，
/// 长度 1..64；路径只能由这些 id 派生，避免 `..` / `/` 逃逸。
library;

final RegExp _dramaIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// 是否是合法的短剧领域 ID。
bool isDramaId(String value) => _dramaIdPattern.hasMatch(value);

/// 校验并原样返回 [value]；非法时抛 [ArgumentError]。
String requireDramaId(String value, String field) {
  if (!isDramaId(value)) {
    throw ArgumentError.value(
      value,
      field,
      'must match [A-Za-z0-9_-]{1,64}',
    );
  }
  return value;
}
