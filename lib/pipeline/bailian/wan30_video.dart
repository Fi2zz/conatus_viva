import 'package:http/http.dart' as http;

import 'dashscope_video.dart';

/// DashScope async-task client for the 万相 3.0 all-in-one video endpoint.
///
/// The shared submit/poll/download mechanics live in [DashScopeVideoClient];
/// this class describes the wan3.0 request bodies for two usages:
/// - first-frame i2v ([submit]): the image travels as
///   `input.media[type=first_frame]`, and the wan2.6-only `shot_type` is gone;
/// - text-to-video ([submitTextToVideo]): `prompt` only, no `media`.
///
/// `ratio` is pinned to `adaptive` so the model matches the input photo (i2v)
/// or picks a sensible frame for the prompt (t2v).
class Wan30VideoClient extends DashScopeVideoClient {
  Wan30VideoClient({
    required this._apiKey,
    http.Client? client,
    String? host,
    this._model = 'wan3.0-video',
    this._resolution = '720P',
    this._ratio = 'adaptive',
    this._watermark = true,
    this._seed = 42,
    this._audio = false,
  }) : _client = client ?? http.Client(),
       _host = host ?? DashScopeVideoClient.defaultHost;

  /// Default workspace-less DashScope host.
  static const String defaultHost = DashScopeVideoClient.defaultHost;

  final String _apiKey;
  final http.Client _client;
  final String _host;
  final String _model;
  final String _resolution;
  final String _ratio;
  final bool _watermark;
  final int? _seed;
  final bool _audio;

  @override
  String get apiKey => _apiKey;

  @override
  String get host => _host;

  @override
  http.Client get httpClient => _client;

  @override
  String get label => 'wan3.0';

  @override
  Map<String, dynamic> buildSubmitBody({
    required String imgUrl,
    required String prompt,
    required int durationS,
  }) {
    return <String, dynamic>{
      'model': _model,
      'input': <String, dynamic>{
        if (prompt.isNotEmpty) 'prompt': prompt,
        'media': <dynamic>[
          <String, dynamic>{'type': 'first_frame', 'url': imgUrl},
        ],
      },
      'parameters': _parameters(durationS),
    };
  }

  /// wan3.0 text-to-video: the all-in-one model's t2v trigger is "prompt and
  /// no `media`" (使用指南「文生视频」), so this body carries `prompt` alone.
  Future<I2vTask> submitTextToVideo({
    required String prompt,
    required int durationS,
  }) {
    return postTask(<String, dynamic>{
      'model': _model,
      'input': <String, dynamic>{'prompt': prompt},
      'parameters': _parameters(durationS),
    }, what: 'submit');
  }

  /// The parameters shared by both wan3.0 usages; every value is pinned so a
  /// service-side default change cannot silently alter spec or cost.
  Map<String, dynamic> _parameters(int durationS) => <String, dynamic>{
    'resolution': _resolution,
    'duration': durationS,
    'ratio': _ratio,
    'audio': _audio,
    'prompt_extend': true,
    'watermark': _watermark,
    if (_seed != null) 'seed': _seed,
  };
}
