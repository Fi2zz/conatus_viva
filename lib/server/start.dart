import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/server/pipeline_server.dart';
import 'package:flutter_wanxiang/server/settings.dart';

/// Loads config from the app's working directory and starts the pipeline
/// server. Returns the bound URL (e.g. `http://localhost:18080`).
///
/// The config file (`pipeline_config.json`) is expected next to the
/// executable (or in the current working directory for `flutter run`).
///
/// [staticDir] is the directory holding the built web UI. Packaged apps pass
/// the path returned by `materializeWebBuild`, since `web_build/` is not on
/// disk next to a sandboxed process.
///
/// If [port] is already in use, the next 10 ports are tried automatically.
///
/// Secrets come from [secretStore] (macOS Keychain / file fallback), never
/// from `.env` or the process environment.
Future<String> startPipelineServer({
  int port = 18080,
  String? staticDir,
  File? avatarImage,
  SecretStore? secretStore,
}) async {
  final cfg = await _loadConfig();
  final staticDirPath = Directory(staticDir ?? _resolveStaticDir());

  var actualPort = port;
  PipelineServer? server;
  for (var i = 0; i < 10; i++) {
    try {
      server = PipelineServer(
        cfg: cfg,
        staticDir: staticDirPath,
        port: actualPort,
        avatarImage: avatarImage,
        secretStore: secretStore,
      );
      await server.start();
      break;
    } on SocketException catch (_) {
      await server?.stop();
      actualPort = port + i + 1;
    }
  }

  if (server == null) {
    throw StateError('Failed to bind pipeline server to any port');
  }

  return 'http://localhost:$actualPort';
}

Future<PipelineConfig> _loadConfig() async {
  final configFile = File('pipeline_config.json');
  if (await configFile.exists()) {
    return PipelineConfig.load(
      file: configFile,
      env: const <String, String>{},
    );
  }
  // Fallback to defaults when no config file is present (development mode).
  // Secrets are supplied later by the injected SecretStore.
  return PipelineConfig(
    llmModel: 'qwen3.8-flash',
    ttsModel: 'qwen-audio-3.1-tts-flash',
    ttsFallbackModel: 'qwen3-tts-flash',
    ttsVoiceId: null,
    ttsFallbackVoice: 'Cherry',
    i2vModel: 'wan2.6-i2v-flash',
    i2vResolution: '720P',
    i2vWatermark: true,
    i2vSeed: 42,
    i2vPollSeconds: 15,
    i2vMaxWaitMinutes: 10,
    ossBucket: '',
    ossEndpoint: '',
    ossPrefix: 'pipeline-exp/',
    targetCount: 4,
    minClipS: 2,
    maxClipS: 15,
  );
}

/// Fallback static directory for running the server directly from the project
/// root (e.g. `dart run`, tests).
///
/// Packaged apps must not rely on this: a sandboxed macOS build runs with its
/// working directory set to the app container, so the relative `web_build/`
/// path resolves to nothing. `main.dart` materializes the bundled assets
/// instead and passes an absolute path.
String _resolveStaticDir() => 'web_build';
