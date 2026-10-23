import 'dart:io';

import 'package:flutter_wanxiang/pipeline/planner_cli.dart';

/// 短剧计划单 CLI 入口（薄入口，解析 / IO / 退出码逻辑都在 planner_cli.dart）。
Future<void> main(List<String> argv) async {
  exit(await runCli(argv));
}
