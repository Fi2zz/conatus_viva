import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/frame.dart';
import 'package:flutter_wanxiang/pipeline/render_plan.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:test/test.dart';

/// 读取预置分镜表 fixture（每次调用重新解析，避免共享可变状态）。
Storyboard ep07() => Storyboard.fromJsonString(
  File('test/fixtures/ep07.storyboard.json').readAsStringSync(),
);

/// 返回各镜头 id → route 的映射。
Map<String, ShotRoute> routes(RenderPlan plan) =>
    {for (final s in plan.shots) s.shotId: s.route};

/// 返回 route 为 i2v 的镜头 id，保持输出顺序。
List<String> i2vIds(RenderPlan plan) =>
    [for (final s in plan.shots) if (s.route == ShotRoute.i2v) s.shotId];

void main() {
  group('priorityRank', () {
    test('orders hook < payoff < turn < normal', () {
      expect(priorityRank(ShotPriority.hook), 0);
      expect(priorityRank(ShotPriority.payoff), 1);
      expect(priorityRank(ShotPriority.turn), 2);
      expect(priorityRank(ShotPriority.normal), 3);
      expect(
        priorityRank(ShotPriority.payoff),
        lessThan(priorityRank(ShotPriority.turn)),
      );
    });
  });

  group('resolveDuration', () {
    Shot shot({
      String id = 's01',
      ShotKind kind = ShotKind.insert,
      String line = '',
      double? durationS,
      ShotPriority priority = ShotPriority.normal,
    }) =>
        Shot(
          id: id,
          kind: kind,
          framing: 'unknown',
          line: line,
          durationS: durationS,
          priority: priority,
        );

    test('explicit duration passes through unchanged', () {
      final warnings = <String>[];
      expect(resolveDuration(shot(durationS: 3.0), warnings), 3.0);
      expect(warnings, isEmpty);
    });

    test('dialogue estimate: 11 runes → 2.5', () {
      final warnings = <String>[];
      expect(
        resolveDuration(
          shot(kind: ShotKind.speakOff, line: '一二三四五六七八九十一'),
          warnings,
        ),
        2.5,
      );
      expect(warnings, isEmpty);
    });

    test('dialogue estimate exact: 9 runes → 2.0', () {
      expect(
        resolveDuration(
          shot(kind: ShotKind.speakOff, line: '一二三四五六七八九'),
          <String>[],
        ),
        2.0,
      );
    });

    test('empty line → 2.0', () {
      expect(
        resolveDuration(shot(kind: ShotKind.speakOff, line: ''), <String>[]),
        2.0,
      );
    });

    test('short dialogue hits the 1.2 floor', () {
      expect(
        resolveDuration(shot(kind: ShotKind.speakOff, line: '你好'), <String>[]),
        1.2,
      );
    });

    test('duration below 0.8 is raised to 0.8 + duration_raised', () {
      final warnings = <String>[];
      expect(resolveDuration(shot(durationS: 0.5), warnings), 0.8);
      expect(warnings, ['duration_raised:s01']);
    });

    test('duration above 30 is clamped to 30 + duration_clamped', () {
      final warnings = <String>[];
      expect(resolveDuration(shot(durationS: 30.1), warnings), 30.0);
      expect(warnings, ['duration_clamped:s01']);
    });
  });

  group('default routes and avatar', () {
    RenderPlan plan(List<Map<String, Object?>> shots) => buildRenderPlan(
      storyboard: Storyboard.fromJson({
        'content_id': 'ep01',
        'shots': shots,
      }),
      priceYuanPerSecond: 0.15,
      budgetYuan: 0.05,
    );

    test('five kinds map to their default route/avatar', () {
      final p = plan([
        {'id': 's01', 'kind': 'speak_off', 'line': '你好'},
        {'id': 's02', 'kind': 'insert'},
        {'id': 's03', 'kind': 'establishing'},
        {'id': 's04', 'kind': 'listen_face'},
        {'id': 's05', 'kind': 'action'},
      ]);
      expect(routes(p), {
        's01': ShotRoute.kenburns,
        's02': ShotRoute.kenburns,
        's03': ShotRoute.kenburns,
        's04': ShotRoute.micro,
        's05': ShotRoute.micro,
      });
      final avatars = {for (final s in p.shots) s.shotId: s.avatar};
      expect(avatars['s01'], isTrue);
      expect(avatars['s02'], isFalse);
      expect(avatars['s03'], isFalse);
      expect(avatars['s04'], isFalse);
      expect(avatars['s05'], isFalse);
    });

    test('speak_off with whitespace-only line has avatar=false', () {
      final p = plan([
        {'id': 's01', 'kind': 'speak_off', 'line': '   '},
      ]);
      expect(p.shots.single.avatar, isFalse);
      expect(p.shots.single.route, ShotRoute.kenburns);
    });
  });

  group('i2v duration caps', () {
    RenderPlan single(Map<String, Object?> shot, {double budget = 100}) =>
        buildRenderPlan(
          storyboard: Storyboard.fromJson({
            'content_id': 'ep01',
            'shots': [shot],
          }),
          priceYuanPerSecond: 0.15,
          budgetYuan: budget,
        );

    test('0.8s action → 2 i2v seconds + i2v_min_duration_raised', () {
      final p = single({'id': 's01', 'kind': 'action', 'duration_s': 0.8});
      expect(p.shots.single.route, ShotRoute.i2v);
      expect(p.shots.single.i2vSeconds, 2);
      expect(p.warnings, ['i2v_min_duration_raised:s01']);
    });

    test('15s action → 10 i2v seconds + i2v_capped', () {
      final p = single({'id': 's01', 'kind': 'action', 'duration_s': 15.0});
      expect(p.shots.single.route, ShotRoute.i2v);
      expect(p.shots.single.i2vSeconds, 10);
      expect(p.warnings, ['i2v_capped:s01']);
    });

    test('15s action downgraded to micro emits no i2v_capped', () {
      final p = single(
        {'id': 's01', 'kind': 'action', 'duration_s': 15.0},
        budget: 0.5,
      );
      expect(p.shots.single.route, ShotRoute.micro);
      expect(p.shots.single.downgradeReason, 'budget_insufficient');
      expect(p.warnings, isNot(contains('i2v_capped:s01')));
    });

    test('0.8s action downgraded to micro emits no i2v_min_duration_raised', () {
      final p = single(
        {'id': 's01', 'kind': 'action', 'duration_s': 0.8},
        budget: 0.1,
      );
      expect(p.shots.single.route, ShotRoute.micro);
      expect(p.shots.single.downgradeReason, 'budget_insufficient');
      expect(p.warnings, isNot(contains('i2v_min_duration_raised:s01')));
    });
  });

  group('budget allocation', () {
    test('20 yuan (fixture default) → 13s / 1.95 / 18.05 / counts 6-1-5', () {
      final p = buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15);
      expect(p.budgetYuan, 20.0);
      expect(p.totals.i2vSeconds, 13);
      expect(p.totals.estimatedYuan, 1.95);
      expect(p.totals.remainingYuan, 18.05);
      expect(p.counts, {'kenburns': 6, 'micro': 1, 'i2v': 5});
      // 输出按故事板顺序；这里只断言分配到的镜头集合（排序只用于分配）。
      expect(
        i2vIds(p),
        unorderedEquals(['s07', 's08', 's12', 's04', 's10']),
      );
    });

    test('1.5 yuan (cap=10) → s07,s08,s12,s10 i2v, s04 downgraded', () {
      final p = buildRenderPlan(
        storyboard: ep07(),
        priceYuanPerSecond: 0.15,
        budgetYuan: 1.5,
      );
      expect(i2vIds(p), unorderedEquals(['s07', 's08', 's12', 's10']));
      expect(p.totals.i2vSeconds, 10);
      expect(p.totals.estimatedYuan, 1.50);
      expect(p.totals.remainingYuan, 0.0);
      expect(p.counts, {'kenburns': 6, 'micro': 2, 'i2v': 4});
      final s04 = p.shots.firstWhere((s) => s.shotId == 's04');
      expect(s04.route, ShotRoute.micro);
      expect(s04.downgradeReason, 'budget_insufficient');
    });

    test('1 yuan (cap=6) → i2v only s07,s08', () {
      final p = buildRenderPlan(
        storyboard: ep07(),
        priceYuanPerSecond: 0.15,
        budgetYuan: 1.0,
      );
      // 关键：payoff(s08) 排在 turn(s04) 之前，1 元只够 s07+s08。
      expect(i2vIds(p), unorderedEquals(['s07', 's08']));
    });

    test('0.2 yuan (cap=1) → 0 i2v + no_i2v_budget, counts 6-6-0', () {
      final p = buildRenderPlan(
        storyboard: ep07(),
        priceYuanPerSecond: 0.15,
        budgetYuan: 0.2,
      );
      expect(p.totals.i2vSeconds, 0);
      expect(p.counts, {'kenburns': 6, 'micro': 6, 'i2v': 0});
      expect(p.warnings, contains('no_i2v_budget'));
    });

    test('0.1 yuan → cap 0, remaining 0.1, never negative', () {
      final p = buildRenderPlan(
        storyboard: ep07(),
        priceYuanPerSecond: 0.15,
        budgetYuan: 0.1,
      );
      expect(p.totals.i2vSeconds, 0);
      expect(p.totals.remainingYuan, 0.1);
      expect(p.totals.remainingYuan, greaterThanOrEqualTo(0));
    });

    test('maxI2vSeconds=4 → only s07=3s, cost 0.45, counts 6-5-1', () {
      final p = buildRenderPlan(
        storyboard: ep07(),
        priceYuanPerSecond: 0.15,
        maxI2vSeconds: 4,
      );
      expect(i2vIds(p), ['s07']);
      expect(p.totals.i2vSeconds, 3);
      expect(p.totals.estimatedYuan, 0.45);
      expect(p.counts, {'kenburns': 6, 'micro': 5, 'i2v': 1});
    });
  });

  group('output shape', () {
    test('12 shots output in s01..s12 order', () {
      final p = buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15);
      expect(
        p.shots.map((s) => s.shotId).toList(),
        [
          's01', 's02', 's03', 's04', 's05', 's06',
          's07', 's08', 's09', 's10', 's11', 's12',
        ],
      );
    });

    test('counts always has all three keys in order', () {
      final p = buildRenderPlan(
        storyboard: ep07(),
        priceYuanPerSecond: 0.15,
        budgetYuan: 0.1,
      );
      final counts = p.toJson()['counts'] as Map<String, Object?>;
      expect(counts.keys.toList(), ['kenburns', 'micro', 'i2v']);
      expect(counts, {'kenburns': 6, 'micro': 6, 'i2v': 0});
    });

    test('PlannedShot.toJson emits snake_case kind and all fields', () {
      final p = buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15);
      final s04 = p.shots[3];
      expect(s04.toJson(), {
        'shot_id': 's04',
        'kind': 'action',
        'route': 'i2v',
        'avatar': false,
        'duration_s': 3.0,
        'i2v_seconds': 3,
        'cost_yuan': 0.45,
        'downgrade_reason': null,
        'framing': 'medium',
        'speaker': 'erniu',
        'line': '',
        'priority': 'turn',
      });
    });

    test('i2v_generation uses the plan constants', () {
      final p = buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15);
      expect(p.toJson()['i2v_generation'], {
        'model': 'wan2.6-i2v-flash',
        'resolution': '720P',
        'width': 720,
        'height': 1280,
      });
    });

    test('top-level toJson shape', () {
      final json = buildRenderPlan(
        storyboard: ep07(),
        priceYuanPerSecond: 0.15,
      ).toJson();
      expect(json['content_id'], 'ep07');
      expect(json['title'], '堂屋对峙');
      expect(json['frame'], {'width': 1080, 'height': 1920});
      expect(json['budget_yuan'], 20.0);
      expect(json['price_yuan_per_second'], 0.15);
      expect(json['max_i2v_seconds'], 0);
      expect(json['totals'], {
        'duration_s': 30.2,
        'i2v_seconds': 13,
        'estimated_yuan': 1.95,
        'remaining_yuan': 18.05,
      });
      expect(json['counts'], {'kenburns': 6, 'micro': 1, 'i2v': 5});
      expect(json['warnings'], <String>[]);
    });
  });

  group('UI display fields passthrough', () {
    RenderPlan plan() =>
        buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15);
    PlannedShot shot(RenderPlan p, String id) =>
        p.shots.firstWhere((s) => s.shotId == id);

    test('12 shots in s01..s12 order', () {
      final p = plan();
      expect(p.shots.length, 12);
      expect(p.shots.map((s) => s.shotId).toList(), [
        's01', 's02', 's03', 's04', 's05', 's06',
        's07', 's08', 's09', 's10', 's11', 's12',
      ]);
    });

    test('s01 speak_off passes framing/speaker/line/priority through', () {
      final s01 = shot(plan(), 's01');
      expect(s01.kind, ShotKind.speakOff);
      expect(s01.framing, 'over_shoulder');
      expect(s01.speaker, 'erniu');
      expect(s01.line, '你欠我的，今天该还了。');
      expect(s01.priority, ShotPriority.hook);
    });

    test('s04 action keeps empty line and turn priority', () {
      final s04 = shot(plan(), 's04');
      expect(s04.kind, ShotKind.action);
      expect(s04.framing, 'medium');
      expect(s04.speaker, 'erniu');
      expect(s04.line, '');
      expect(s04.priority, ShotPriority.turn);
    });

    test('s12 listen_face keeps payoff priority', () {
      final s12 = shot(plan(), 's12');
      expect(s12.kind, ShotKind.listenFace);
      expect(s12.framing, 'close');
      expect(s12.speaker, 'xiaoman');
      expect(s12.line, '');
      expect(s12.priority, ShotPriority.payoff);
    });

    test('s02 defaults to normal priority', () {
      final s02 = shot(plan(), 's02');
      expect(s02.speaker, 'xiaoman');
      expect(s02.priority, ShotPriority.normal);
    });

    test('toJson key order and wire values', () {
      final json = shot(plan(), 's01').toJson();
      expect(json.keys.toList(), [
        'shot_id',
        'kind',
        'route',
        'avatar',
        'duration_s',
        'i2v_seconds',
        'cost_yuan',
        'downgrade_reason',
        'framing',
        'speaker',
        'line',
        'priority',
      ]);
      expect(json['framing'], 'over_shoulder');
      expect(json['speaker'], 'erniu');
      expect(json['line'], '你欠我的，今天该还了。');
      expect(json['priority'], 'hook');
    });

    test('toJson keeps speaker null when the shot has none', () {
      final json = shot(plan(), 's03').toJson();
      expect(json['framing'], 'close_up');
      expect(json.containsKey('speaker'), isTrue);
      expect(json['speaker'], isNull);
      expect(json['line'], '');
      expect(json['priority'], 'normal');
    });
  });

  group('precision & determinism', () {
    test('totals.duration_s == 30.2', () {
      final p = buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15);
      expect(p.totals.durationS, 30.2);
    });

    test('jsonEncode has no long floating-point strings', () {
      final encoded = jsonEncode(
        buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15).toJson(),
      );
      expect(encoded, isNot(contains('30.199999999999996')));
      expect(RegExp(r'\d\.\d{10}').hasMatch(encoded), isFalse);
    });

    test('same input twice encodes identically', () {
      final once = jsonEncode(
        buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15).toJson(),
      );
      final twice = jsonEncode(
        buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15).toJson(),
      );
      expect(twice, once);
    });

    test('doubling price doubles cost and estimated', () {
      final cheap = buildRenderPlan(storyboard: ep07(), priceYuanPerSecond: 0.15);
      final expensive = buildRenderPlan(
        storyboard: ep07(),
        priceYuanPerSecond: 0.30,
      );
      expect(
        expensive.totals.estimatedYuan,
        closeTo(cheap.totals.estimatedYuan * 2, 1e-9),
      );
      final s07Cheap = cheap.shots.firstWhere((s) => s.shotId == 's07');
      final s07Exp = expensive.shots.firstWhere((s) => s.shotId == 's07');
      expect(s07Exp.costYuan, closeTo(s07Cheap.costYuan * 2, 1e-9));
    });
  });

  group('warnings merge', () {
    test('storyboard warnings first, then plan warnings, stable order', () {
      final p = buildRenderPlan(
        storyboard: Storyboard.fromJson({
          'content_id': 'ep01',
          'shots': [
            {'id': 's01', 'kind': 'dance'},
            {'id': 's02', 'kind': 'action', 'duration_s': 3.0},
          ],
        }),
        priceYuanPerSecond: 0.15,
        budgetYuan: 0.1,
      );
      expect(p.warnings, ['unknown_kind:s01:dance', 'no_i2v_budget']);
    });

    test('duplicate warnings collapse to one', () {
      final p = buildRenderPlan(
        storyboard: Storyboard(
          contentId: 'ep01',
          title: 'ep01',
          frame: FrameSize.vertical,
          budgetYuan: 100,
          cast: const {},
          shots: [
            Shot(
              id: 's01',
              kind: ShotKind.action,
              framing: 'x',
              line: '',
              durationS: 3.0,
              priority: ShotPriority.normal,
            ),
          ],
          warnings: ['no_i2v_budget'],
        ),
        priceYuanPerSecond: 0.15,
        budgetYuan: 0.1,
      );
      expect(p.warnings, ['no_i2v_budget']);
    });
  });

  group('parameter validation', () {
    test('invalid price/budget/maxI2vSeconds throw ArgumentError', () {
      final board = ep07();
      for (final price in <double>[0, -1, double.nan, double.infinity]) {
        expect(
          () => buildRenderPlan(storyboard: board, priceYuanPerSecond: price),
          throwsA(isA<ArgumentError>()),
        );
      }
      for (final budget in <double>[0, -1, double.nan, double.infinity]) {
        expect(
          () => buildRenderPlan(
            storyboard: board,
            priceYuanPerSecond: 0.15,
            budgetYuan: budget,
          ),
          throwsA(isA<ArgumentError>()),
        );
      }
      expect(
        () => buildRenderPlan(
          storyboard: board,
          priceYuanPerSecond: 0.15,
          maxI2vSeconds: -1,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
