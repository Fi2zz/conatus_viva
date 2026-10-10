import 'dart:convert';

import 'package:conatus/conatus.dart';

import 'errors.dart';
import 'orchestrator.dart';

/// conatus 工具 `generate_monthly_video`：把一段参数组装成 [PipelineInput]
/// 并驱动 [VivaPipeline] 全流水线（高风险：消耗真实生成额度）。
class GenerateMonthlyVideoTool extends Tool {
  GenerateMonthlyVideoTool({required this.pipeline});

  /// The pipeline driven by [call] (injectable in tests).
  final VivaPipeline pipeline;

  @override
  String get name => 'generate_monthly_video';

  @override
  String get description =>
      '生成月度相册视频：输入照片（本地路径或 URL）与方言地区，'
      '产出带方言口播与字幕的 mp4；dry_run 只跑到配音并返回成本预估。';

  @override
  ToolRisk get riskLevel => ToolRisk.high;

  @override
  List<ParamSpec> get params => <ParamSpec>[
    ParamSpec.array(
      'photos',
      items: ParamSpec.string('photo', description: '照片路径或 URL'),
      description: '本月照片列表（本地路径或 http(s) URL）',
      required: true,
    ),
    ParamSpec.string(
      'dialect',
      description: '方言地区（如 河南、上海；未覆盖地区自动回落普通话）',
      required: true,
    ),
    ParamSpec.integer('count', description: '入选照片数上限', defaultValue: 4),
    ParamSpec.string('content_id', description: '内容 ID（缺省按时间生成）'),
    ParamSpec.boolean(
      'dry_run',
      description: '只跑到 tts，返回分段路由与成本预估，不渲染',
      defaultValue: false,
    ),
    ParamSpec.boolean(
      'mute',
      description: '跳过配音，用静音音轨出片（字幕照常）',
      defaultValue: false,
    ),
  ];

  @override
  Future<ToolResult> call(ToolContext context) async {
    try {
      final result = await pipeline.run(_inputFrom(context));
      if (result.status == PipelineResult.statusFailed) {
        final message = result.error ?? 'pipeline failed';
        return ToolResult.failure(
          message,
          error: ToolError('PIPELINE_FAILED', message),
        );
      }
      return ToolResult.success(jsonEncode(result.toJson()), value: result);
    } on PipelineError catch (e) {
      return ToolResult.failure(
        e.message,
        error: ToolError('PIPELINE_FAILED', e.message),
      );
    }
  }

  PipelineInput _inputFrom(ToolContext context) {
    return PipelineInput(
      photos: _photos(context),
      dialect: context.str('dialect'),
      count: context.integer('count') ?? 4,
      contentId: context.string('content_id') ?? _defaultContentId(),
      dryRun: context.boolean('dry_run') ?? false,
      mute: context.boolean('mute') ?? false,
    );
  }

  List<String> _photos(ToolContext context) {
    final raw = context.require<List<Object?>>('photos');
    return <String>[
      for (final item in raw)
        if (item is String)
          item
        else
          throw ToolArgumentException('photos 元素必须是字符串，实际 ${item.runtimeType}'),
    ];
  }

  /// `album-<yyyymmdd>-<hhmmss>` — 每次调用唯一，天然满足路径安全约束。
  static String _defaultContentId() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final day = '${now.year}${two(now.month)}${two(now.day)}';
    final time = '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return 'album-$day-$time';
  }
}
