import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/planner_cli.dart';
import 'package:flutter_wanxiang/pipeline/render_plan.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:test/test.dart';

/// 读取预置分镜表 fixture（每次调用重新解析，避免共享可变状态）。
Storyboard ep07() => Storyboard.fromJsonString(
  File('test/fixtures/ep07.storyboard.json').readAsStringSync(),
);

void main() {
  group('parsePlannerArgs', () {
    final parser = buildPlannerParser();

    test('无子命令 → null', () {
      expect(parsePlannerArgs(parser.parse(<String>[]), parser), isNull);
    });

    test('缺 --storyboard → null', () {
      expect(parsePlannerArgs(parser.parse(<String>['plan']), parser), isNull);
    });

    test('空 --storyboard → null', () {
      expect(
        parsePlannerArgs(
          parser.parse(<String>['plan', '--storyboard', '']),
          parser,
        ),
        isNull,
      );
    });

    test('--budget 非法 → null', () {
      for (final budget in <String>['0', '-1', 'NaN', 'Infinity', 'abc']) {
        expect(
          parsePlannerArgs(
            parser.parse(<String>[
              'plan', '--storyboard', 'a.json', '--budget', budget,
            ]),
            parser,
          ),
          isNull,
          reason: budget,
        );
      }
    });

    test('--max-i2v-seconds 非法 → null', () {
      for (final seconds in <String>['-1', 'abc']) {
        expect(
          parsePlannerArgs(
            parser.parse(<String>[
              'plan', '--storyboard', 'a.json', '--max-i2v-seconds', seconds,
            ]),
            parser,
          ),
          isNull,
          reason: seconds,
        );
      }
    });

    test('--out 空串 → outPath 为 null', () {
      final args = parsePlannerArgs(
        parser.parse(<String>['plan', '--storyboard', 'a.json', '--out', '']),
        parser,
      );
      expect(args, isNotNull);
      expect(args!.outPath, isNull);
    });

    test('合法参数 → 字段正确', () {
      final args = parsePlannerArgs(
        parser.parse(<String>[
          'plan', '--storyboard', 'a.json', '--budget', '12.5',
          '--max-i2v-seconds', '20', '--out', 'out/p.json',
        ]),
        parser,
      );
      expect(args, isNotNull);
      expect(args!.storyboardPath, 'a.json');
      expect(args.budgetYuan, 12.5);
      expect(args.maxI2vSeconds, 20);
      expect(args.outPath, 'out/p.json');
    });

    test('缺省参数 → budget/max/out 使用默认', () {
      final args = parsePlannerArgs(
        parser.parse(<String>['plan', '--storyboard', 'a.json']),
        parser,
      );
      expect(args, isNotNull);
      expect(args!.budgetYuan, isNull);
      expect(args.maxI2vSeconds, 0);
      expect(args.outPath, isNull);
    });
  });

  group('runCli', () {
    test('--help → 0', () async {
      expect(await runCli(<String>['--help']), 0);
    });

    test('无子命令 → 64', () async {
      expect(await runCli(<String>[]), 64);
    });

    test('未知子命令 → 64', () async {
      expect(await runCli(<String>['bogus']), 64);
    });
  });

  test('defaultI2vPriceYuanPerSecond == 0.15', () {
    expect(defaultI2vPriceYuanPerSecond(), 0.15);
  });

  group('encodePlanJson', () {
    test('以单个 \\n 结尾且可被 jsonDecode 还原', () {
      final plan = buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15);
      final encoded = encodePlanJson(plan);
      expect(encoded.endsWith('\n'), isTrue);
      expect(encoded, isNot(endsWith('\n\n')));
      expect(jsonDecode(encoded), plan.toJson());
    });
  });

  group('runPlan', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('planner_cli_test');
    });

    tearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });

    PlannerArgs planArgs({String? out, double? budget}) => PlannerArgs(
      storyboardPath: 'test/fixtures/ep07.storyboard.json',
      budgetYuan: budget,
      maxI2vSeconds: 0,
      outPath: out,
    );

    test('fixture → 0，文件在 <outDir>/ep07/07_plan.json，内容等于 encodePlanJson', () async {
      final code = await runPlan(planArgs(), outDir: temp.path);
      expect(code, 0);
      final file = File('${temp.path}/ep07/07_plan.json');
      expect(file.existsSync(), isTrue);
      final expected = encodePlanJson(
        buildRenderPlan(
          storyboard: ep07(),
          priceYuanPerSecond: defaultI2vPriceYuanPerSecond(),
        ),
      );
      expect(file.readAsStringSync(), expected);
    });

    test('--out 显式路径优先生效', () async {
      final out = '${temp.path}/custom/plan.json';
      final code = await runPlan(planArgs(out: out), outDir: temp.path);
      expect(code, 0);
      expect(File(out).existsSync(), isTrue);
      expect(File('${temp.path}/ep07/07_plan.json').existsSync(), isFalse);
    });

    test('文件不存在 → 65', () async {
      final code = await runPlan(
        PlannerArgs(storyboardPath: '${temp.path}/nope.json'),
        outDir: temp.path,
      );
      expect(code, 65);
    });

    test('JSON 语法错误 → 65', () async {
      final bad = File('${temp.path}/bad.json')..writeAsStringSync('{ not json');
      final code = await runPlan(
        PlannerArgs(storyboardPath: bad.path),
        outDir: temp.path,
      );
      expect(code, 65);
    });

    test('非法 schema → 65', () async {
      final bad = File('${temp.path}/bad.json')
        ..writeAsStringSync(jsonEncode(<String, Object?>{
          'content_id': 'ep01',
          'shots': <Object?>[],
        }));
      final code = await runPlan(
        PlannerArgs(storyboardPath: bad.path),
        outDir: temp.path,
      );
      expect(code, 65);
    });

    test('输出路径是已存在目录 → 74', () async {
      final dir = Directory('${temp.path}/isdir')..createSync(recursive: true);
      final code = await runPlan(planArgs(out: dir.path), outDir: temp.path);
      expect(code, 74);
    });

    test('低预算 warnings 写入 warningSink', () async {
      final sink = StringBuffer();
      final code = await runPlan(
        planArgs(budget: 0.2),
        outDir: temp.path,
        warningSink: sink,
      );
      expect(code, 0);
      expect(sink.toString(), contains('warn: no_i2v_budget'));
    });
  });
}
