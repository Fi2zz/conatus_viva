import 'package:http/http.dart' as http;

import 'dashscope_video.dart';

// Task types and the shared contract stay importable from this library so
// existing callers (`render.dart`, the render tests) keep their import.
export 'dashscope_video.dart' show I2vStatus, I2vTask;

/// DashScope async-task client for the 万相 i2v generation endpoint
/// (wan2.6 family, spec §4「05 render」).
///
/// The shared submit/poll/download mechanics live in [DashScopeVideoClient];
/// this class pins only the wan2.6 request body (`input.img_url` +
/// `shot_type: multi`).
class I2vClient extends DashScopeVideoClient {
  I2vClient({
    required this._apiKey,
    http.Client? client,
    String? host,
    this._model = 'wan2.6-i2v-flash',
    this._resolution = '720P',
    this._watermark = true,
    this._seed = 42,
  }) : _client = client ?? http.Client(),
       _host = host ?? DashScopeVideoClient.defaultHost;

  /// Default workspace-less DashScope host.
  static const String defaultHost = DashScopeVideoClient.defaultHost;

  final String _apiKey;
  final http.Client _client;
  final String _host;
  final String _model;
  final String _resolution;
  final bool _watermark;
  final int _seed;

  @override
  String get apiKey => _apiKey;

  @override
  String get host => _host;

  @override
  http.Client get httpClient => _client;

  @override
  String get label => 'i2v';

  @override
  Map<String, dynamic> buildSubmitBody({
    required String imgUrl,
    required String prompt,
    required int durationS,
  }) {
    return <String, dynamic>{
      'model': _model,
      'input': <String, dynamic>{'img_url': imgUrl, 'prompt': prompt},
      'parameters': <String, dynamic>{
        'resolution': _resolution,
        'duration': durationS,
        'audio': false,
        'prompt_extend': true,
        'shot_type': 'multi',
        'watermark': _watermark,
        'seed': _seed,
      },
    };
  }
}
