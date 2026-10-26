/// 设置页密钥的持久化抽象（纯 Dart）。
///
/// macOS 由 `PlatformSecretStore` 走 Keychain；其他平台用它提供的 0600 文件。
/// 这里只定义读写契约与两个可直接测试的实现，不接触 Flutter。
library;

import 'dart:convert';
import 'dart:io';

/// 密钥读写；返回值是扁平的环境变量名 → 值。
abstract interface class SecretStore {
  Future<Map<String, String>> readAll();

  Future<void> writeAll(Map<String, String> values);
}

/// 测试与临时使用：只存在内存里。
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initial])
    : _values = <String, String>{...?initial};

  final Map<String, String> _values;

  @override
  Future<Map<String, String>> readAll() async =>
      Map<String, String>.of(_values);

  @override
  Future<void> writeAll(Map<String, String> values) async {
    _values
      ..clear()
      ..addAll(values);
  }
}

/// 无原生 Keychain 的平台回退：用户目录下的 0600 JSON 文件。
class FileSecretStore implements SecretStore {
  FileSecretStore(this.file);

  final File file;

  @override
  Future<Map<String, String>> readAll() async {
    if (!await file.exists()) return <String, String>{};
    final text = await file.readAsString();
    if (text.trim().isEmpty) return <String, String>{};
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const FormatException('secrets file must be a JSON object');
    }
    return <String, String>{
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  @override
  Future<void> writeAll(Map<String, String> values) async {
    await file.parent.create(recursive: true);
    final text = '${const JsonEncoder.withIndent('  ').convert(values)}\n';
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(file.path);
    if (!Platform.isWindows) {
      // Best effort on POSIX; the file is already user-private under $HOME.
      await Process.run('chmod', <String>['600', file.path]);
    }
  }
}
