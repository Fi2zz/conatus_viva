import 'dart:io';

import 'package:flutter_wanxiang/pipeline/drama/cost.dart';
import 'package:flutter_wanxiang/pipeline/drama/episode.dart';
import 'package:flutter_wanxiang/pipeline/drama/hashes.dart';
import 'package:flutter_wanxiang/pipeline/drama/pricing.dart';
import 'package:flutter_wanxiang/pipeline/drama/run_target.dart';
import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/drama/state.dart';
import 'package:flutter_wanxiang/pipeline/drama/store.dart';
import 'package:flutter_wanxiang/pipeline/render_plan.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:test/test.dart';

DramaSeries series({DramaCastMember? member}) {
  final cast = <String, DramaCastMember>{};
  if (member != null) cast[member.castId] = member;
  return DramaSeries.create(
    seriesId: 'jietiao',
    title: '借条',
    cast: cast,
  );
}

DramaEpisode episode({DramaSeries? s}) =>
    DramaEpisode.create(series: s ?? series(), episodeId: 'ep07', title: '堂屋对峙');

Storyboard board() => Storyboard.fromJson(<String, Object?>{
  'content_id': 'ep07',
  'shots': <Object?>[
    <String, Object?>{
      'id': 's01',
      'kind': 'action',
      'speaker': 'erniu',
      'line': '',
      'duration_s': 3,
      'priority': 'hook',
      'visual': '借条特写',
    },
  ],
});

Map<String, Object?> planJson() => <String, Object?>{
  'shots': <Object?>[
    <String, Object?>{
      'shot_id': 's01',
      'route': 'i2v',
      'i2v_seconds': 3,
      'duration_s': 3.2,
    },
  ],
};

DramaPricing pricing() => DramaPricing(
  i2vYuanPerSecond: 0.15,
  imagePrice: (_, _) => 0.35,
  videoPrice: (_, _) => 0.15,
);

void main() {
  late Directory temp;
  late DramaStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('conatus_cost_test');
    store = DramaStore(rootDir: temp.path);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('i2v price comes from the catalog', () {
    expect(defaultDramaI2vPriceYuanPerSecond(), 0.15);
  });

  test('story estimate marks LLM unpriced and keeps budget snapshot', () {
    final estimate = estimateDrama(
      series: series(),
      episode: episode(),
      state: DramaEpisodeState.empty('jietiao', 'ep07'),
      storyboard: null,
      planJson: null,
      request: const DramaEstimateRequest(step: DramaEstimateStep.story),
      pricing: pricing(),
      store: store,
    );
    expect(estimate.totalEstimatedYuan, 0);
    expect(estimate.items, isEmpty);
    expect(estimate.unpriced.single.id, 'story');
    expect(estimate.unpriced.single.reason, 'llm_pricing_unavailable');
    expect(estimate.budget.totalYuan, 120);
    expect(estimate.budget.actualYuan, 0);
    expect(estimate.budget.remainingYuan, 120);
  });

  test('budget remaining never goes negative', () {
    final ep = episode();
    final estimate = estimateDrama(
      series: series(),
      episode: ep.copyWith(
        settings: ep.settings.copyWith(totalBudgetYuan: 1),
      ),
      state: DramaEpisodeState.empty('jietiao', 'ep07')
          .withActualYuan(5),
      storyboard: null,
      planJson: null,
      request: const DramaEstimateRequest(step: DramaEstimateStep.story),
      pricing: pricing(),
      store: store,
    );
    expect(estimate.budget.remainingYuan, 0);
  });

  test('cast estimate prices unreferenced missing avatars', () {
    final s = series(
      member: const DramaCastMember(
        castId: 'erniu',
        name: '二舅',
        description: '五十岁',
      ),
    );
    final estimate = estimateDrama(
      series: s,
      episode: episode(s: s),
      state: DramaEpisodeState.empty('jietiao', 'ep07'),
      storyboard: board(),
      planJson: planJson(),
      request: const DramaEstimateRequest(step: DramaEstimateStep.cast),
      pricing: pricing(),
      store: store,
    );
    expect(estimate.items.single.kind, 'image');
    expect(estimate.items.single.id, 'erniu');
    expect(estimate.items.single.priceYuan, 0.35);
    expect(estimate.totalEstimatedYuan, 0.35);
  });

  test('frame estimate prices frames and i2v clips separately', () {
    final s = series(
      member: const DramaCastMember(
        castId: 'erniu',
        name: '二舅',
        description: '五十岁',
      ),
    );
    final estimate = estimateDrama(
      series: s,
      episode: episode(s: s),
      state: DramaEpisodeState.empty('jietiao', 'ep07'),
      storyboard: board(),
      planJson: planJson(),
      request: const DramaEstimateRequest(
        step: DramaEstimateStep.frame,
        target: DramaRunTarget.all,
      ),
      pricing: pricing(),
      store: store,
    );
    expect(
      estimate.items.map((i) => i.kind).toList(),
      <String>['image', 'clip'],
    );
    expect(estimate.totalEstimatedYuan, closeTo(0.8, 0.001));
    expect(estimate.i2vEstimatedYuan, closeTo(0.45, 0.001));
    expect(estimate.budget.i2vTotalYuan, 20);
    expect(estimate.budget.i2vRemainingYuan, 20);
  });

  test('cached frame and clip are skipped unless forced', () {
    final s = series();
    final b = board();
    final shot = b.shots.single;
    final frameHash = dramaFrameHash(
      shot: shot,
      castAvatarHash: null,
      model: 'wan2.7-image',
      size: '1K',
    );
    final clipHash = dramaClipHash(
      shot: shot,
      frameHash: frameHash,
      route: 'i2v',
      model: 'wan2.6-i2v-flash',
      resolution: '720P',
      i2vSeconds: 3,
    );
    final framePath = 'assets/frames/s01/$frameHash/image-01.png';
    final clipPath = 'assets/clips/s01/$clipHash.mp4';
    store.assetFile('jietiao', 'ep07', framePath)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    store.assetFile('jietiao', 'ep07', clipPath)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[1]);
    final state = DramaEpisodeState.empty('jietiao', 'ep07').withShot(
      's01',
      DramaShotState(
        frame: DramaArtifact(
          status: DramaStatus.succeeded,
          path: framePath,
          sourceHash: frameHash,
        ),
        clip: DramaArtifact(
          status: DramaStatus.succeeded,
          path: clipPath,
          sourceHash: clipHash,
          durationS: 3,
        ),
      ),
    );
    final cached = estimateDrama(
      series: s,
      episode: episode(s: s),
      state: state,
      storyboard: b,
      planJson: planJson(),
      request: const DramaEstimateRequest(step: DramaEstimateStep.frame),
      pricing: pricing(),
      store: store,
    );
    expect(cached.items, isEmpty);
    final forced = estimateDrama(
      series: s,
      episode: episode(s: s),
      state: state,
      storyboard: b,
      planJson: planJson(),
      request: const DramaEstimateRequest(
        step: DramaEstimateStep.frame,
        force: true,
      ),
      pricing: pricing(),
      store: store,
    );
    expect(forced.items, hasLength(2));
  });

  test('buildDramaPlan uses episode i2v budget', () {
    final plan = buildDramaPlan(storyboard: board(), episode: episode());
    expect(plan.priceYuanPerSecond, 0.15);
    expect(plan.budgetYuan, 20);
    expect(plan.shots.single.route, ShotRoute.i2v);
    expect(plan.totals.i2vSeconds, 3);
    expect(plan.totals.estimatedYuan, 0.45);
  });

  test('new estimate request rejects unknown steps and bad target', () {
    expect(
      () => parseDramaEstimateRequest(<String, Object?>{'step': 'voice'}),
      throwsArgumentError,
    );
    expect(
      () => parseDramaEstimateRequest(<String, Object?>{
        'step': 'frame',
        'target': 'audio',
      }),
      throwsArgumentError,
    );
  });
}
