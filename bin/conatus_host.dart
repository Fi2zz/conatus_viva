import 'dart:io';

import 'package:args/args.dart';
import 'package:conatus/conatus.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/host.dart';

/// 实验宿主：手跑月度相册视频流水线的 CLI 入口。
///
/// 默认路径直接调 `generate_monthly_video` 工具并把 PipelineResult JSON
/// 打到 stdout；`--agent` 把参数包成自然语言任务交给 AgentLoop。
Future<void> main(List<String> argv) async {
  final parser = buildParser();
  final ArgResults results;
  try {
    results = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    exit(64);
  }
  if (results.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }
  final envError = validateEnv(Platform.environment);
  if (envError != null) {
    stderr.writeln(envError);
    exit(exitCodeMissingEnv);
  }
  exit(await run(results, parser));
}

ArgParser buildParser() {
  return ArgParser()
    ..addOption('photos', help: '逗号分隔的照片路径/URL，或一个目录')
    ..addOption('dialect', help: '方言地区（如 河南、上海）')
    ..addOption('count', abbr: 'n', defaultsTo: '4', help: '入选照片数上限')
    ..addOption('content-id', help: '内容 ID（缺省按时间生成）')
    ..addFlag('dry-run', help: '只跑到配音，返回成本预估，不渲染')
    ..addOption('agent', help: '自然语言任务，交给 agent loop 执行')
    ..addOption(
      'prefer-provider',
      defaultsTo: 'dashscope',
      allowed: <String>['dashscope', 'oss'],
      help: '图片 URL 提供方（oss 走签名上传回退）',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: '打印用法');
}

Future<int> run(ArgResults results, ArgParser parser) async {
  final args = parseArgs(results, parser);
  if (args == null) return 64;
  final PipelineConfig cfg;
  try {
    cfg = await PipelineConfig.load();
  } on ConfigException catch (e) {
    stderr.writeln(e.message);
    return exitCodeMissingEnv;
  }
  final ctx = await createHost(cfg: cfg, preferProvider: args.preferProvider);
  try {
    return args.agentTask == null
        ? await runDirect(ctx, args)
        : await runAgent(ctx, cfg, args);
  } finally {
    ctx.dispose();
  }
}

/// 缺必填参数返回 null（用法错误已由 stderr 说明）。
HostArgs? parseArgs(ArgResults results, ArgParser parser) {
  final photos = results['photos'] as String?;
  final dialect = results['dialect'] as String?;
  final count = int.tryParse(results['count'] as String);
  if (photos == null || dialect == null || count == null) {
    stderr.writeln('必须提供 --photos 与 --dialect（--count 需为整数）\n\n'
        '${parser.usage}');
    return null;
  }
  return HostArgs(
    photos: expandPhotos(photos),
    dialect: dialect,
    count: count,
    contentId: results['content-id'] as String?,
    dryRun: results.flag('dry-run'),
    agentTask: results['agent'] as String?,
    preferProvider: results['prefer-provider'] as String,
  );
}

Future<int> runDirect(Context ctx, HostArgs args) async {
  final result = await runPipelineTool(ctx, args);
  if (result.isError) {
    stderr.writeln('pipeline failed: ${result.content}');
    return 1;
  }
  stdout.writeln(result.content);
  return 0;
}

Future<int> runAgent(Context ctx, PipelineConfig cfg, HostArgs args) async {
  final loop = attachAgentLoop(ctx, cfg: cfg);
  stderr.writeln('session log: $sessionLogDir/${loop.session?.id}.jsonl');
  try {
    final turn = await loop.run(agentTask(args));
    stdout.writeln(turn.reply);
    return 0;
  } on LlmException catch (e) {
    stderr.writeln('agent failed: $e');
    return 1;
  }
}
