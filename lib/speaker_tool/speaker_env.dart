import 'package:flutter_dotenv/flutter_dotenv.dart';

/// 主讲人工具的环境变量封装。
///
/// 所有 API Key 从 `.env` 读取，绝不硬编码。[init] 必须在 `runApp`
/// 之前调用。缺失必填项时通过 [requireDashScopeApiKey] 抛异常，
/// 调用方可据此在 UI 层提示用户。
class SpeakerEnv {
  const SpeakerEnv._();

  static bool _loaded = false;

  /// 加载 `.env` 文件。重复调用安全（仅首次生效）。
  static Future<void> init() async {
    if (_loaded) return;
    await dotenv.load(fileName: '.env', mergeWith: const {});
    _loaded = true;
  }

  /// 百炼 API Key；未配置时返回空字符串。
  static String get dashScopeApiKey => dotenv.env['DASHSCOPE_API_KEY'] ?? '';

  /// 百炼业务空间 ID；未配置时返回空字符串。
  static String get dashScopeWorkspaceId =>
      dotenv.env['DASHSCOPE_WORKSPACE_ID'] ?? '';

  /// OSS Access Key ID；未配置时返回 null。
  static String? get ossAccessKeyId {
    final v = dotenv.env['OSS_ACCESS_KEY_ID'];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// OSS Access Key Secret；未配置时返回 null。
  static String? get ossAccessKeySecret {
    final v = dotenv.env['OSS_ACCESS_KEY_SECRET'];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 百炼 API Key 是否已配置。
  static bool get dashScopeReady => dashScopeApiKey.isNotEmpty;
}
