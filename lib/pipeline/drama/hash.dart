/// 短剧领域 canonical JSON 与 SHA-256（纯 Dart，无 Flutter 依赖）。
///
/// 产物的 `source_hash` 必须与 map 插入顺序无关，所以哈希前递归排序 key；
/// list 保持顺序（镜头顺序是语义的一部分）。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 生成 key 递归排序后的 JSON 文本。
String canonicalJson(Object? value) => jsonEncode(_canonical(value));

Object? _canonical(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (value is List) {
    return <Object?>[for (final item in value) _canonical(item)];
  }
  if (value is Map) {
    final keys = <String>[];
    for (final key in value.keys) {
      if (key is! String) {
        throw ArgumentError('canonicalJson: map key 必须是 String：$key');
      }
      keys.add(key);
    }
    keys.sort();
    return <String, Object?>{
      for (final key in keys) key: _canonical(value[key]),
    };
  }
  throw ArgumentError('canonicalJson: 不支持的类型 ${value.runtimeType}');
}

/// `canonicalJson(value)` 的 SHA-256 十六进制摘要。
String dramaHash(Object? value) =>
    sha256.convert(utf8.encode(canonicalJson(value))).toString();
