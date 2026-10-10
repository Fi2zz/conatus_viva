import 'dart:io';

import 'package:conatus/conatus.dart';

import 'config.dart';
import 'monthly_video_tool.dart';
import 'orchestrator.dart';

/// Exit code when startup validation fails (missing `DASHSCOPE_API_KEY`).
const int exitCodeMissingEnv = 2;

/// Agent-mode session log root (`<sessionId>.jsonl`, one file per run).
const String sessionLogDir = 'pipeline_out/host-session';

/// Parsed CLI arguments, shared by the direct and `--agent` paths.
class HostArgs {
  const HostArgs({
    required this.photos,
    required this.dialect,
    required this.count,
    required this.dryRun,
    required this.preferProvider,
    this.mute = false,
    this.contentId,
    this.agentTask,
  });

  /// Already expanded via [expandPhotos] (local paths or http(s) URLs).
  final List<String> photos;
  final String dialect;
  final int count;
  final bool dryRun;

  /// `--mute`: skip TTS, silent narration tracks (subtitles still render).
  final bool mute;

  /// `'dashscope'` (default) or `'oss'`; forwarded to [VivaPipeline].
  final String preferProvider;

  /// Null → the tool generates `album-<yyyymmdd>-<hhmmss>`.
  final String? contentId;

  /// Natural-language task for the agent loop; null → direct tool call.
  final String? agentTask;
}

/// Startup validation: returns the stderr guidance when the required secret
/// is missing, null when the environment is runnable.
String? validateEnv(Map<String, String> env) {
  final key = env['DASHSCOPE_API_KEY'];
  if (key != null && key.isNotEmpty) return null;
  return 'DASHSCOPE_API_KEY is not set.\n'
      'Create a key in the DashScope console, then:\n'
      '  export DASHSCOPE_API_KEY=sk-...\n'
      'Optional OSS fallback (--prefer-provider oss) also needs '
      'OSS_ACCESS_KEY_ID / OSS_ACCESS_KEY_SECRET.';
}

/// `--photos` expansion: a comma-separated list passes through (trimmed),
/// a directory expands to its image files sorted by path.
List<String> expandPhotos(String spec) {
  final photos = <String>[];
  for (final part in spec.split(',')) {
    final path = part.trim();
    if (path.isEmpty) continue;
    final dir = Directory(path);
    photos.addAll(dir.existsSync() ? _imagesIn(dir) : <String>[path]);
  }
  return photos;
}

List<String> _imagesIn(Directory dir) {
  const extensions = <String>{'.jpg', '.jpeg', '.png', '.webp', '.bmp'};
  final files = <String>[
    for (final entity in dir.listSync())
      if (entity is File && extensions.contains(_extension(entity.path)))
        entity.path,
  ];
  return files..sort();
}

String _extension(String path) {
  final dot = path.lastIndexOf('.');
  return dot < 0 ? '' : path.substring(dot).toLowerCase();
}

/// Assembles the host context: tool registry + `generate_monthly_video`.
///
/// Offline-safe (the pipeline's clients are lazy), so tests can assert the
/// registration without keys or network. The agent loop is a separate seam
/// ([attachAgentLoop]) because it needs the API key.
Future<Context> createHost({
  required PipelineConfig cfg,
  String preferProvider = 'dashscope',
  void Function(String message)? onProgress,
}) async {
  final ctx = Context.root(name: 'conatus-host');
  final tools = provideTools(ctx);
  final pipeline = VivaPipeline(
    cfg: cfg,
    preferProvider: preferProvider,
    onProgress: onProgress,
  );
  ctx.track(tools.register(GenerateMonthlyVideoTool(pipeline: pipeline)));
  return ctx;
}

/// Direct path: invoke the tool once and return its result.
Future<ToolResult> runPipelineTool(Context ctx, HostArgs args) {
  return ctx.tools.call(
    ToolCall(
      name: 'generate_monthly_video',
      arguments: <String, Object?>{
        'photos': args.photos,
        'dialect': args.dialect,
        'count': args.count,
        if (args.contentId != null) 'content_id': args.contentId,
        'dry_run': args.dryRun,
        'mute': args.mute,
      },
    ),
  );
}

/// Agent path: attach an AgentLoop (DashScope OpenAI-compatible provider,
/// auto-approved high-risk calls, JSONL session log under [sessionDir]).
/// Returns the loop; `loop.session?.id` names the log file.
AgentLoop attachAgentLoop(
  Context ctx, {
  required PipelineConfig cfg,
  String sessionDir = sessionLogDir,
}) {
  provideLlm(ctx, llm: FallbackLlm(<LlmProvider>[_dashscopeProvider(cfg)]));
  provideSystemPrompt(ctx).add(
    '你是月度相册视频流水线的操作助手。把用户的自然语言任务转成一次 '
    'generate_monthly_video 工具调用；参数不全时先向用户追问，'
    '不要编造照片路径。完成后用中文简要汇报结果。',
    name: 'viva-pipeline',
  );
  final persistence = JsonlSessionPersistence(dir: sessionDir);
  provideSessionLog(ctx, persistence: persistence);
  provideSessionLogRecorder(ctx);
  final session = provideSessions(ctx, persistence: persistence).create();
  provideApproval(ctx, approval: AutoApproval(true), tools: ctx.tools);
  return provideAgentLoop(ctx, session: session);
}

LlmProvider _dashscopeProvider(PipelineConfig cfg) {
  return OpenAiCompatibleProvider(
    name: 'dashscope',
    baseUrl: cfg.baseUrl,
    model: cfg.llmModel,
    apiKey: cfg.requireApiKey(),
  );
}

/// The agent's user turn: explicit `--agent` text wins; otherwise the CLI
/// args are restated as one natural-language task.
String agentTask(HostArgs args) {
  final explicit = args.agentTask;
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final id = args.contentId == null ? '' : '，content_id 用 ${args.contentId}';
  final mode = args.dryRun ? '，只 dry_run 估成本' : '';
  return '用这些照片生成月度视频：${args.photos.join(', ')}；'
      '方言地区 ${args.dialect}，最多 ${args.count} 张$id$mode。';
}
