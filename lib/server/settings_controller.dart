/// `/api/settings`：只暴露「是否已配置」，写入 Keychain/文件，不回显密钥。
library;

import 'dart:convert';
import 'dart:io';

import '../pipeline/config.dart';
import 'settings.dart';

const Map<String, String> _wireToEnv = <String, String>{
  'dashscope_api_key': 'DASHSCOPE_API_KEY',
  'workspace_id': 'DASHSCOPE_WORKSPACE_ID',
  'oss_access_key_id': 'OSS_ACCESS_KEY_ID',
  'oss_access_key_secret': 'OSS_ACCESS_KEY_SECRET',
};

const int _maxBodyBytes = 64 * 1024;

class SettingsController {
  SettingsController({required this.cfg, required this.store});

  final PipelineConfig cfg;
  final SecretStore? store;

  Future<void> handle(HttpRequest req) async {
    if (req.uri.path != '/api/settings') {
      await _error(req, HttpStatus.notFound, 'not found', 'not_found');
      return;
    }
    if (req.method == 'GET') {
      await _sendJson(req, HttpStatus.ok, _status());
      return;
    }
    if (req.method != 'PUT') {
      await _error(
        req,
        HttpStatus.methodNotAllowed,
        'method not allowed',
        'method_not_allowed',
      );
      return;
    }
    if (store == null) {
      await _error(
        req,
        HttpStatus.notImplemented,
        '该环境没有可用的密钥存储；请在桌面应用里设置',
        'secrets_unavailable',
      );
      return;
    }
    final body = await _readBody(req);
    if (body == null) return;

    final changes = <String, String?>{};
    for (final entry in _wireToEnv.entries) {
      if (!body.containsKey(entry.key)) continue;
      final raw = body[entry.key];
      if (raw is! String) {
        await _error(req, HttpStatus.badRequest, '字段类型错误：${entry.key}', 'invalid_body');
        return;
      }
      final value = raw.trim();
      changes[entry.value] = value.isEmpty ? null : value;
    }
    if (changes.isEmpty) {
      await _sendJson(req, HttpStatus.ok, _status());
      return;
    }

    final current = await store!.readAll();
    final next = <String, String>{...current};
    for (final entry in changes.entries) {
      final value = entry.value;
      if (value == null) {
        next.remove(entry.key);
      } else {
        next[entry.key] = value;
      }
    }
    await store!.writeAll(next);
    cfg.updateSecrets(changes);
    await _sendJson(req, HttpStatus.ok, _status());
  }

  Map<String, Object?> _status() => <String, Object?>{
    'dashscope_configured': cfg.hasApiKey,
    'workspace_id': cfg.workspaceId,
    'oss_configured': cfg.hasOss,
  };

  Future<Map<String, Object?>?> _readBody(HttpRequest req) async {
    if (req.contentLength > _maxBodyBytes) {
      await _error(req, HttpStatus.requestEntityTooLarge, '请求体过大', 'body_too_large');
      return null;
    }
    final bytes = await req.fold<List<int>>(<int>[], (acc, chunk) {
      acc.addAll(chunk);
      return acc;
    });
    final text = utf8.decode(bytes);
    if (text.trim().isEmpty) return <String, Object?>{};
    if (text.length > _maxBodyBytes) {
      await _error(req, HttpStatus.requestEntityTooLarge, '请求体过大', 'body_too_large');
      return null;
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      await _error(req, HttpStatus.badRequest, '请求体必须是 JSON 对象', 'invalid_body');
      return null;
    }
    return <String, Object?>{
      for (final entry in decoded.entries)
        if (entry.key is String) entry.key as String: entry.value,
    };
  }

  Future<void> _sendJson(
    HttpRequest req,
    int status,
    Map<String, Object?> body,
  ) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _error(
    HttpRequest req,
    int status,
    String message,
    String code,
  ) => _sendJson(req, status, <String, Object?>{
    'error': message,
    'code': code,
  });
}
