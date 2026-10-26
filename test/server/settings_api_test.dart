import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/server/pipeline_server.dart';
import 'package:flutter_wanxiang/server/settings.dart';
import 'package:test/test.dart';

Future<File> _writeCfg(Directory dir) async {
  final file = File('${dir.path}/cfg.json');
  await file.writeAsString('{}');
  return file;
}

Future<({int status, String body})> _send(
  int port,
  String method,
  String path, [
  Map<String, Object?>? body,
]) async {
  final client = HttpClient();
  try {
    final req = await client.open(method, '127.0.0.1', port, path);
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return (status: res.statusCode, body: text);
  } finally {
    client.close(force: true);
  }
}

void main() {
  late Directory tempDir;
  late Directory staticDir;
  late PipelineServer server;
  late PipelineConfig cfg;
  late int port;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('conatus_settings_test');
    staticDir = Directory.systemTemp.createTempSync('conatus_settings_static');
    File('${staticDir.path}/index.html').writeAsStringSync('<html></html>');
    cfg = await PipelineConfig.load(
      file: await _writeCfg(tempDir),
      env: const <String, String>{},
    );
    server = PipelineServer(
      cfg: cfg,
      staticDir: staticDir,
      port: 0,
      dramaRoot: '${tempDir.path}/drama',
      secretStore: MemorySecretStore(),
    );
    await server.start();
    port = server.boundPort!;
  });

  tearDown(() async {
    await server.stop();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    if (staticDir.existsSync()) staticDir.deleteSync(recursive: true);
  });

  test('PUT saves secrets, GET never echoes them, and config is live', () async {
    final initial = await _send(port, 'GET', '/api/settings');
    expect(initial.status, 200);
    expect(
      (jsonDecode(initial.body) as Map<String, dynamic>)['dashscope_configured'],
      isFalse,
    );

    final put = await _send(port, 'PUT', '/api/settings', <String, Object?>{
      'dashscope_api_key': 'sk-live',
      'workspace_id': 'ws-1',
      'oss_access_key_id': 'oss-id',
      'oss_access_key_secret': 'oss-secret',
    });
    expect(put.status, 200);
    expect(put.body, isNot(contains('sk-live')));
    expect(put.body, isNot(contains('oss-secret')));
    expect(cfg.requireApiKey(), 'sk-live');
    expect(cfg.apiHost, contains('ws-1'));
    expect(cfg.hasOss, isTrue);

    final get = await _send(port, 'GET', '/api/settings');
    expect(get.status, 200);
    expect(get.body, isNot(contains('sk-live')));
    final status = jsonDecode(get.body) as Map<String, dynamic>;
    expect(status['dashscope_configured'], isTrue);
    expect(status['workspace_id'], 'ws-1');
    expect(status['oss_configured'], isTrue);
  });

  test('empty value clears and malformed body is 400', () async {
    expect(
      (await _send(port, 'PUT', '/api/settings', <String, Object?>{
        'dashscope_api_key': 'sk-live',
      })).status,
      200,
    );
    expect(
      (await _send(port, 'PUT', '/api/settings', <String, Object?>{
        'dashscope_api_key': '',
      })).status,
      200,
    );
    expect(cfg.hasApiKey, isFalse);
    expect(
      (await _send(port, 'PUT', '/api/settings', <String, Object?>{
        'workspace_id': 42,
      })).status,
      400,
    );
  });

  test('startup loads stored secrets into the running config', () async {
    final store = MemorySecretStore(<String, String>{
      'DASHSCOPE_API_KEY': 'sk-stored',
      'DASHSCOPE_WORKSPACE_ID': 'ws-stored',
    });
    final otherCfg = await PipelineConfig.load(
      file: await _writeCfg(tempDir),
      env: const <String, String>{},
    );
    final other = PipelineServer(
      cfg: otherCfg,
      staticDir: staticDir,
      port: 0,
      dramaRoot: '${tempDir.path}/drama2',
      secretStore: store,
    );
    await other.start();
    try {
      expect(otherCfg.requireApiKey(), 'sk-stored');
      expect(otherCfg.workspaceId, 'ws-stored');
    } finally {
      await other.stop();
    }
  });

  test('PUT is 501 when no secret store is injected', () async {
    final noStoreCfg = await PipelineConfig.load(
      file: await _writeCfg(tempDir),
      env: const <String, String>{},
    );
    final noStore = PipelineServer(
      cfg: noStoreCfg,
      staticDir: staticDir,
      port: 0,
      dramaRoot: '${tempDir.path}/drama3',
    );
    await noStore.start();
    try {
      final res = await _send(
        noStore.boundPort!,
        'PUT',
        '/api/settings',
        <String, Object?>{'dashscope_api_key': 'sk-x'},
      );
      expect(res.status, 501);
      expect((jsonDecode(res.body) as Map<String, dynamic>)['code'],
          'secrets_unavailable');
    } finally {
      await noStore.stop();
    }
  });

  test('FileSecretStore round-trips and tolerates a missing file', () async {
    final file = File('${tempDir.path}/secrets.json');
    final store = FileSecretStore(file);
    expect(await store.readAll(), isEmpty);
    await store.writeAll(<String, String>{'DASHSCOPE_API_KEY': 'sk-file'});
    expect(await store.readAll(), <String, String>{
      'DASHSCOPE_API_KEY': 'sk-file',
    });
  });
}
