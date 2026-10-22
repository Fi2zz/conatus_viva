import 'dart:convert';
import 'dart:io';

/// Thrown when the pipeline configuration cannot be loaded or a required
/// secret is missing from the environment.
class ConfigException implements Exception {
  ConfigException(this.message);

  final String message;

  @override
  String toString() => 'ConfigException: $message';
}

/// Immutable pipeline parameters loaded from `pipeline_config.json`.
///
/// The config file is pure parameters and safe for git. Secrets never appear
/// in it — they are read from the environment only, via [requireApiKey] and
/// the OSS credential getters.
class PipelineConfig {
  const PipelineConfig({
    required this.llmModel,
    required this.ttsModel,
    required this.ttsFallbackModel,
    required this.ttsVoiceId,
    required this.ttsFallbackVoice,
    required this.i2vModel,
    required this.i2vResolution,
    required this.i2vWatermark,
    required this.i2vSeed,
    required this.i2vPollSeconds,
    required this.i2vMaxWaitMinutes,
    required this.ossBucket,
    required this.ossEndpoint,
    required this.ossPrefix,
    required this.targetCount,
    required this.minClipS,
    required this.maxClipS,
    this.t2vModel = 'wan3.0-video',
    this.t2vResolution = '720P',
    this.t2vRatio = 'adaptive',
    this.t2vDuration = 5,
    this.t2vAudio = true,
    this.t2vWatermark = false,
    this.t2vSeed,
    this.t2vPollSeconds = 15,
    this.t2vMaxWaitMinutes = 10,
    this.t2vYuanPerSecond = 0.42,
    this.imagePollSeconds = 5,
    this.imageMaxWaitMinutes = 10,
    this.imageDefaultModel = 'qwen-image-3.0-pro',
    this.imagePrices = const <String, Map<String, double>>{},
    this.videoPrices = const <String, Map<String, double>>{},
    this.workspaceId = '',
    this.baseUrl = defaultBaseUrl,
    Map<String, String>? env,
  }) : _env = env ?? const <String, String>{};

  static const String defaultBaseUrl =
      'https://dashscope.aliyuncs.com/compatible-mode/v1';

  /// The workspace-less default DashScope host.
  static const String defaultApiHost = 'https://dashscope.aliyuncs.com';

  /// Loads and parses [file] (default `pipeline_config.json`).
  ///
  /// Throws [ConfigException] if the file is missing or is not valid JSON.
  /// [env] defaults to [Platform.environment]; it is only consulted by
  /// [requireApiKey] and the OSS credential getters.
  static Future<PipelineConfig> load({
    File? file,
    Map<String, String>? env,
  }) async {
    final config = file ?? File('pipeline_config.json');
    if (!await config.exists()) {
      throw ConfigException(
        'config file not found: ${config.path}'
        '（可复制 pipeline_config.example.json 后填写）',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await config.readAsString());
    } catch (e) {
      throw ConfigException('failed to parse ${config.path}: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw ConfigException('config root must be a JSON object: ${config.path}');
    }
    final json = decoded;
    final llm = _section(json, 'llm');
    final tts = _section(json, 'tts');
    final i2v = _section(json, 'i2v');
    final t2v = _section(json, 't2v');
    final image = _section(json, 'image');
    final oss = _section(json, 'oss');
    final video = _section(json, 'video');
    final workspaceId = _string(json, 'workspace_id', '');
    final host = workspaceId.isEmpty
        ? defaultApiHost
        : 'https://$workspaceId.cn-beijing.maas.aliyuncs.com';
    return PipelineConfig(
      llmModel: _string(llm, 'model', 'qwen3.8-flash'),
      ttsModel: _string(tts, 'model', 'qwen-audio-3.1-tts-flash'),
      ttsFallbackModel: _string(tts, 'fallback_model', 'qwen3-tts-flash'),
      ttsVoiceId: _nullableString(tts, 'voice_id'),
      ttsFallbackVoice: _nullableString(
        tts,
        'fallback_voice',
        fallback: 'Cherry',
      ),
      workspaceId: workspaceId,
      i2vModel: _string(i2v, 'model', 'wan2.6-i2v-flash'),
      i2vResolution: _string(i2v, 'resolution', '720P'),
      i2vWatermark: _bool(i2v, 'watermark', true),
      i2vSeed: _int(i2v, 'seed', 42),
      i2vPollSeconds: _int(i2v, 'poll_seconds', 15),
      i2vMaxWaitMinutes: _int(i2v, 'max_wait_minutes', 10),
      t2vModel: _string(t2v, 'model', 'wan3.0-video'),
      t2vResolution: _string(t2v, 'resolution', '720P'),
      t2vRatio: _string(t2v, 'ratio', 'adaptive'),
      t2vDuration: _int(t2v, 'duration', 5),
      t2vAudio: _bool(t2v, 'audio', true),
      t2vWatermark: _bool(t2v, 'watermark', false),
      t2vSeed: _nullableInt(t2v, 'seed'),
      t2vPollSeconds: _int(t2v, 'poll_seconds', 15),
      t2vMaxWaitMinutes: _int(t2v, 'max_wait_minutes', 10),
      t2vYuanPerSecond: _double(t2v, 'yuan_per_second', 0.42),
      imagePollSeconds: _int(image, 'poll_seconds', 5),
      imageMaxWaitMinutes: _int(image, 'max_wait_minutes', 10),
      imageDefaultModel: _string(image, 'default_model', 'qwen-image-3.0-pro'),
      imagePrices: _priceTable(json, 'image'),
      videoPrices: _priceTable(json, 'video'),
      ossBucket: _string(oss, 'bucket', ''),
      ossEndpoint: _string(oss, 'endpoint', ''),
      ossPrefix: _string(oss, 'prefix', 'pipeline-exp/'),
      targetCount: _int(video, 'target_count', 4),
      minClipS: _int(video, 'min_clip_s', 2),
      maxClipS: _int(video, 'max_clip_s', 15),
      baseUrl: _string(json, 'base_url', '$host/compatible-mode/v1'),
      env: env ?? Platform.environment,
    );
  }

  final String llmModel;
  final String ttsModel;
  final String ttsFallbackModel;
  final String? ttsVoiceId;
  final String? ttsFallbackVoice;
  final String i2vModel;
  final String i2vResolution;
  final bool i2vWatermark;
  final int i2vSeed;
  final int i2vPollSeconds;
  final int i2vMaxWaitMinutes;
  final String ossBucket;
  final String ossEndpoint;
  final String ossPrefix;
  final int targetCount;
  final int minClipS;
  final int maxClipS;

  /// 文生视频（万相 3.0）参数：模型、分辨率、宽高比、时长、是否保留原生音频、
  /// 水印、种子（null = 服务端随机）、轮询与超时。CLI `--text-to-video` 会按
  /// 这些默认值出片，可被命令行参数覆盖。
  final String t2vModel;
  final String t2vResolution;
  final String t2vRatio;
  final int t2vDuration;
  final bool t2vAudio;
  final bool t2vWatermark;
  final int? t2vSeed;
  final int t2vPollSeconds;
  final int t2vMaxWaitMinutes;

  /// 文生视频每秒计价（元），用于前端生成前费用预估；
  /// 由配置 `t2v.yuan_per_second` 提供。默认 0.42 = wan3.0-video 720P
  /// 限时 7 折实价（原价 0.6）；单价与计费口径见
  /// `docs/万相视频生成与编辑成本核算_v1.0.md`。
  final double t2vYuanPerSecond;

  /// 图片合成任务参数：轮询间隔、超时与默认模型。
  final int imagePollSeconds;
  final int imageMaxWaitMinutes;
  final String imageDefaultModel;

  /// `pricing.image.<model>.<tier> = 元/张`（空 = 全部用目录默认价）。
  final Map<String, Map<String, double>> imagePrices;

  /// `pricing.video.<model>.<分辨率> = 元/秒`（空 = 全部用目录默认价）。
  final Map<String, Map<String, double>> videoPrices;

  final String baseUrl;

  /// 百炼业务空间 ID（空 = 默认空间，走 [defaultApiHost]）。配置后所有
  /// DashScope 系端点（LLM/TTS/i2v/上传）都切换到工作空间主机。
  final String workspaceId;

  /// 所有 DashScope 系 API 的主机：配置了 [workspaceId] 时为
  /// `https://<id>.cn-beijing.maas.aliyuncs.com`，否则 [defaultApiHost]。
  String get apiHost => workspaceId.isEmpty
      ? defaultApiHost
      : 'https://$workspaceId.cn-beijing.maas.aliyuncs.com';

  final Map<String, String> _env;

  /// Returns `DASHSCOPE_API_KEY` from the environment, or throws
  /// [ConfigException] when it is absent or empty.
  String requireApiKey() {
    final key = _env['DASHSCOPE_API_KEY'];
    if (key == null || key.isEmpty) {
      throw ConfigException('DASHSCOPE_API_KEY is not set');
    }
    return key;
  }

  /// OSS credentials for the fallback upload path; null when not provided.
  String? get ossAccessKeyId => _env['OSS_ACCESS_KEY_ID'];

  String? get ossAccessKeySecret => _env['OSS_ACCESS_KEY_SECRET'];

  static Map<String, dynamic> _section(Map<String, dynamic> json, String key) {
    final value = json[key];
    return value is Map<String, dynamic> ? value : const <String, dynamic>{};
  }

  /// `pricing.<section>.<model>.<tier> = 元`；非数字或非对象条目跳过。
  static Map<String, Map<String, double>> _priceTable(
    Map<String, dynamic> json,
    String section,
  ) {
    final root = _section(json, 'pricing');
    final table = _section(root, section);
    final out = <String, Map<String, double>>{};
    for (final entry in table.entries) {
      final tiers = entry.value;
      if (tiers is! Map<String, dynamic>) continue;
      final prices = <String, double>{
        for (final t in tiers.entries)
          if (t.value is num) t.key: (t.value as num).toDouble(),
      };
      if (prices.isNotEmpty) out[entry.key] = prices;
    }
    return out;
  }

  static String _string(Map<String, dynamic> map, String key, String fallback) {
    final value = map[key];
    return value is String ? value : fallback;
  }

  static String? _nullableString(
    Map<String, dynamic> map,
    String key, {
    String? fallback,
  }) {
    final value = map[key];
    if (value is String) return value;
    return fallback;
  }

  static int _int(Map<String, dynamic> map, String key, int fallback) {
    final value = map[key];
    return value is int ? value : fallback;
  }

  static int? _nullableInt(Map<String, dynamic> map, String key) {
    final value = map[key];
    return value is int ? value : null;
  }

  static bool _bool(Map<String, dynamic> map, String key, bool fallback) {
    final value = map[key];
    return value is bool ? value : fallback;
  }

  static double _double(
    Map<String, dynamic> map,
    String key,
    double fallback,
  ) {
    final value = map[key];
    return value is num ? value.toDouble() : fallback;
  }
}
