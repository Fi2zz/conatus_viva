import 'package:flutter_wanxiang/pipeline/drama/cost.dart';
import 'package:flutter_wanxiang/pipeline/drama/episode.dart';
import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/drama/state.dart';
import 'package:flutter_wanxiang/pipeline/render_plan.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:test/test.dart';

DramaSeries series() => DramaSeries.create(seriesId: 'jietiao', title: '借条');

DramaEpisode episode() =>
    DramaEpisode.create(series: series(), episodeId: 'ep07', title: '堂屋对峙');

void main() {
  test('i2v price comes from the catalog', () {
    expect(defaultDramaI2vPriceYuanPerSecond(), 0.15);
  });

  test('P1 estimate marks LLM unpriced and keeps budget snapshot', () {
    final state = DramaEpisodeState.empty('jietiao', 'ep07');
    final estimate = estimateDrama(
      series: series(),
      episode: episode(),
      state: state,
      targets: <String>{'story', 'storyboard'},
    );
    expect(estimate.totalEstimatedYuan, 0);
    expect(estimate.items, isEmpty);
    expect(estimate.unpriced.map((u) => u.id), <String>['story', 'storyboard']);
    expect(estimate.unpriced.every((u) => u.kind == 'llm'), isTrue);
    expect(estimate.unpriced.every((u) => u.reason == 'llm_pricing_unavailable'), isTrue);
    expect(estimate.budget.totalYuan, 120);
    expect(estimate.budget.actualYuan, 0);
    expect(estimate.budget.remainingYuan, 120);
  });

  test('budget remaining never goes negative', () {
    final state = DramaEpisodeState.empty('jietiao', 'ep07');
    final estimate = estimateDrama(
      series: series(),
      episode: episode().copyWith(
        settings: episode().settings.copyWith(totalBudgetYuan: 1),
      ),
      state: state,
      targets: <String>{'story'},
    );
    expect(estimate.budget.remainingYuan, 1);
  });

  test('buildDramaPlan uses episode i2v budget', () {
    final board = Storyboard.fromJson(<String, Object?>{
      'content_id': 'ep07',
      'budget_yuan': 20,
      'shots': <Object?>[
        <String, Object?>{'id': 's01', 'kind': 'action', 'duration_s': 3},
      ],
    });
    final plan = buildDramaPlan(storyboard: board, episode: episode());
    expect(plan.priceYuanPerSecond, 0.15);
    expect(plan.budgetYuan, 20);
    expect(plan.shots.single.route, ShotRoute.i2v);
    expect(plan.totals.i2vSeconds, 3);
    expect(plan.totals.estimatedYuan, 0.45);
  });

  test('estimate rejects unknown targets', () {
    expect(
      () => estimateDrama(
        series: series(),
        episode: episode(),
        state: DramaEpisodeState.empty('jietiao', 'ep07'),
        targets: <String>{'nope'},
      ),
      throwsArgumentError,
    );
  });
}
