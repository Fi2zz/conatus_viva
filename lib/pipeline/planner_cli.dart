/// 计划单 CLI：解析、定价、读写与退出码（纯 Dart，无 Flutter 依赖）。
///
/// `bin/short_drama.dart` 只调用 [runCli] 并 `exit`；解析、IO 与退出码逻辑都
/// 放在这里，便于离线单测（[runCli] / [runPlan] 返回退出码而非直接 `exit`，
/// 避免测试进程被杀）。
///
/// 退出码契约：成功 0；用法 / 参数错误 64；读 / 解析 / schema 输入错误 65；
/// 写盘失败 74。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'errors.dart';
import 'generation_models.dart';
import 'render_plan.dart';
import 'storyboard.dart';

/// 退出码（sysexits.h 惯例）。
const int exitOk = 0;
const int exitUsage = 64;
const int exitInput = 65;
const int exitWrite = 74;

/// 解析后的计划单参数。
class PlannerArgs {
  const PlannerArgs({
    required this.storyboardPath,
    this.budgetYuan,
    this.maxI2vSeconds = 0,
    this.outPath,
  });

  final String storyboardPath;

  /// null → 使用 storyboard.budget_yuan。
  final double? budgetYuan;

  /// 0 = 不限。
  final int maxI2vSeconds;

  /// null → 默认路径 `${outDir ?? 'pipeline_out'}/${contentId}/07_plan.json`。
  final String? outPath;
}

/// 顶层 `-h/--help`；`plan` 子命令带 `storyboard` / `budget` /
/// `max-i2v-seconds` / `out`（不提供 `price-per-second`）。
ArgParser buildPlannerParser() {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: '打印用法');
  parser.addCommand(
    'plan',
    ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false, help: '打印用法')
      ..addOption('storyboard', help: '分镜表 JSON 路径（必填）')
      ..addOption('budget', help: '本集预算（元），缺省用 storyboard.budget_yuan')
      ..addOption('max-i2v-seconds', help: 'i2v 秒数上限，0 = 不限')
      ..addOption('out', help: '输出路径，缺省 <outDir>/<contentId>/07_plan.json'),
  );
  return parser;
}

/// 拼接完整用法文本：顶层 `parser.usage` + `子命令:` 段 + `plan` 子命令自身用法。
///
/// `ArgParser.usage` 不列出子命令，单独打印会丢失 `plan` 及其选项，故在此显式
/// 汇总，供 `--help`、无子命令与各类用法错误统一使用。
String plannerUsage(ArgParser parser) {
  final buffer = StringBuffer(parser.usage);
  buffer.write(
    '\n子命令:\n'
    '  plan --storyboard <path> [--budget <yuan>] '
    '[--max-i2v-seconds <n>] [--out <path>]\n',
  );
  final plan = parser.commands['plan'];
  if (plan != null) {
    buffer.write('\n${plan.usage}');
  }
  return buffer.toString();
}

/// 从解析结果取 `plan` 子命令参数；用法错误打印 usage 到 stderr 并返回 null。
PlannerArgs? parsePlannerArgs(ArgResults results, ArgParser parser) {
  final command = results.command;
  if (command == null) {
    stderr.writeln('缺少子命令 plan\n\n${plannerUsage(parser)}');
    return null;
  }

  final storyboard = command['storyboard'] as String?;
  if (storyboard == null || storyboard.isEmpty) {
    stderr.writeln('必须提供非空的 --storyboard 路径\n\n${plannerUsage(parser)}');
    return null;
  }

  final rawBudget = command['budget'] as String?;
  double? budgetYuan;
  if (rawBudget != null) {
    final value = double.tryParse(rawBudget);
    if (value == null || !value.isFinite || value <= 0) {
      stderr.writeln('--budget 必须是有限正数：$rawBudget\n\n${plannerUsage(parser)}');
      return null;
    }
    budgetYuan = value;
  }

  final rawMax = command['max-i2v-seconds'] as String?;
  var maxI2vSeconds = 0;
  if (rawMax != null) {
    final value = int.tryParse(rawMax);
    if (value == null || value < 0) {
      stderr.writeln(
        '--max-i2v-seconds 必须 >= 0：$rawMax\n\n${plannerUsage(parser)}',
      );
      return null;
    }
    maxI2vSeconds = value;
  }

  final rawOut = command['out'] as String?;
  final outPath = (rawOut == null || rawOut.isEmpty) ? null : rawOut;

  return PlannerArgs(
    storyboardPath: storyboard,
    budgetYuan: budgetYuan,
    maxI2vSeconds: maxI2vSeconds,
    outPath: outPath,
  );
}

/// 计划单固定使用的 i2v 目录单价（`wan2.6-i2v-flash` / 720P）。
///
/// 目录缺失直接 `throw StateError`，不静默回退到任何默认价。
double defaultI2vPriceYuanPerSecond() {
  final model = findVideoModel(kPlanI2vModel);
  if (model == null) {
    throw StateError('模型目录缺少 $kPlanI2vModel，无法定价');
  }
  final price = model.defaultPrices[kPlanI2vResolution];
  if (price == null) {
    throw StateError('$kPlanI2vModel 目录缺少 $kPlanI2vResolution 档位单价');
  }
  return price;
}

/// 序列化计划单：pretty 2 空格缩进 + 恰好一个结尾 `\n`。
String encodePlanJson(RenderPlan plan) =>
    '${const JsonEncoder.withIndent('  ').convert(plan.toJson())}\n';

/// 执行计划单生成：读分镜表 → 建计划 → 写文件 → 写 stdout，返回退出码。
///
/// [warningSink] 缺省为 stderr，测试可传 `StringBuffer` 断言 warnings。
Future<int> runPlan(
  PlannerArgs args, {
  String? outDir,
  StringSink? warningSink,
}) async {
  final String source;
  try {
    source = File(args.storyboardPath).readAsStringSync();
  } on FileSystemException catch (e) {
    stderr.writeln('读取分镜表失败：$e');
    return exitInput;
  }

  final Storyboard storyboard;
  try {
    storyboard = Storyboard.fromJsonString(source);
  } on PipelineError catch (e) {
    stderr.writeln('分镜表无效：${e.message}');
    return exitInput;
  }

  final RenderPlan plan;
  try {
    plan = buildRenderPlan(
      storyboard: storyboard,
      priceYuanPerSecond: defaultI2vPriceYuanPerSecond(),
      budgetYuan: args.budgetYuan,
      maxI2vSeconds: args.maxI2vSeconds,
    );
  } on ArgumentError catch (e) {
    stderr.writeln('${e.message}');
    return exitUsage;
  }

  final outputPath =
      args.outPath ??
      '${outDir ?? 'pipeline_out'}/${storyboard.contentId}/07_plan.json';
  final encoded = encodePlanJson(plan);

  try {
    File(outputPath).parent.createSync(recursive: true);
    File(outputPath).writeAsStringSync(encoded);
  } on FileSystemException catch (e) {
    stderr.writeln('写入计划单失败：$e');
    return exitWrite;
  }

  stdout.write(encoded);

  final sink = warningSink ?? stderr;
  for (final warning in plan.warnings) {
    sink.writeln('warn: $warning');
  }

  return exitOk;
}

/// CLI 顶层入口：解析 argv、分派 `plan` 子命令，返回退出码。
///
/// `bin/short_drama.dart` 的 `main` 只做 `exit(await runCli(argv))`。
Future<int> runCli(List<String> argv) async {
  final parser = buildPlannerParser();
  final ArgResults results;
  try {
    results = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${plannerUsage(parser)}');
    return exitUsage;
  }
  if (results.flag('help') || (results.command?.flag('help') ?? false)) {
    stdout.writeln(plannerUsage(parser));
    return exitOk;
  }
  final args = parsePlannerArgs(results, parser);
  if (args == null) return exitUsage;
  return runPlan(args);
}
