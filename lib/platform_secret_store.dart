/// 桌面应用的密钥存储：macOS 走原生 Keychain，其他平台回退到 0600 文件。
///
/// 这是唯一允许依赖 Flutter 的密钥入口；`lib/pipeline/**` 与 `lib/server/**`
/// 只看到 [SecretStore] 接口，不接触 MethodChannel。
library;

import 'dart:io';

import 'package:flutter/services.dart';

import 'server/settings.dart';

class PlatformSecretStore implements SecretStore {
  PlatformSecretStore({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('viva/secrets');

  static const String service = 'com.conatusviva.secrets';

  final MethodChannel _channel;

  @override
  Future<Map<String, String>> readAll() async {
    if (Platform.isMacOS) {
      final values = await _channel.invokeMapMethod<String, String>('readAll');
      return values ?? <String, String>{};
    }
    return FileSecretStore(_fallbackFile()).readAll();
  }

  @override
  Future<void> writeAll(Map<String, String> values) async {
    if (Platform.isMacOS) {
      await _channel.invokeMethod<void>('writeAll', values);
      return;
    }
    await FileSecretStore(_fallbackFile()).writeAll(values);
  }

  File _fallbackFile() {
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return File('$appData/Viva/secrets.json');
      }
    }
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return File('$home/.viva/secrets.json');
  }
}
