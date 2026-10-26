import 'dart:async';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/drama/episode.dart';
import 'package:flutter_wanxiang/pipeline/drama/runner.dart';
import 'package:flutter_wanxiang/pipeline/drama/run_target.dart';
import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/drama/state.dart';
import 'package:flutter_wanxiang/pipeline/drama/steps.dart';
import 'package:flutter_wanxiang/pipeline/drama/store.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:test/test.dart';

import 'fake_gateway.dart';

DramaSeries seriesWithCast() => DramaSeries.create(
  seriesId: 'jietiao',
  title: '借条',
  cast: <String, DramaCastMember>{
    'erniu': const DramaCastMember(
      castId: 'erniu',
      name: '二舅',
      description: '五十岁，短寸，旧夹克',
    ),
  },
);

Storyboard board() => Storyboard.fromJson(<String, Object?>{
  'content_id': 'ep07',
  'cast': <String, Object?>{'erniu': <String, Object?>{'name': '二舅'}},
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

Storyboard multiBoard({String s02Visual = '院门口'}) =>
    Storyboard.fromJson(<String, Object?>{
      'content_id': 'ep07',
      'cast': <String, Object?>{'erniu': <String, Object?>{'name': '二舅'}},
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
        <String, Object?>{
          'id': 's02',
          'kind': 'establishing',
          'line': '',
          'duration_s': 2,
          'priority': 'normal',
          'visual': s02Visual,
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
    <String, Object?>{
      'shot_id': 's02',
      'route': 'kenburns',
      'i2v_seconds': 0,
      'duration_s': 2,
    },
  ],
};

void main() {
  late Directory temp;
  late DramaStore store;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('conatus_runner_test');
    store = DramaStore(rootDir: temp.path);
    store.createSeries(seriesWithCast());
    store.createEpisode(
      DramaEpisode.create(
        series: seriesWithCast(),
        episodeId: 'ep07',
        title: '堂屋对峙',
      ),
    );
    store.writeStoryboard('jietiao', 'ep07', board());
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  DramaRunner runner(FakeDramaMediaGateway gateway) =>
      DramaRunner(store: store, gateway: gateway);

  test('cast run persists avatar, cost, and skips on second run', () async {
    final gateway = FakeDramaMediaGateway(imageCost: 0.2);
    final r = runner(gateway);
    final run = await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.cast,
    );
    await run.done;
    expect(run.status, DramaRunStatus.completed);
    final series = store.readSeries('jietiao');
    final avatar = series.cast['erniu']!.avatar!;
    expect(avatar.approved, isFalse);
    expect(avatar.path, startsWith('cast/erniu/'));
    expect(store.seriesAssetFile('jietiao', avatar.path).existsSync(), isTrue);
    expect(store.readState('jietiao', 'ep07').actualYuan, 0.2);
    expect(store.readState('jietiao', 'ep07').activeRunId, isNull);
    expect(store.readState('jietiao', 'ep07').steps['cast']!.status,
        DramaStatus.succeeded);

    final second = await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.cast,
    );
    await second.done;
    expect(gateway.imageCalls, 1);
  });

  test('force regenerates even when cache matches', () async {
    final gateway = FakeDramaMediaGateway();
    final r = runner(gateway);
    await (await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.cast,
    )).done;
    await (await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.cast,
      force: true,
    )).done;
    expect(gateway.imageCalls, 2);
  });

  test('missing key fails the run before further items', () async {
    final gateway = FakeDramaMediaGateway()..missingKey = true;
    final r = runner(gateway);
    final run = await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.cast,
    );
    await run.done;
    expect(run.status, DramaRunStatus.failed);
    expect(store.readState('jietiao', 'ep07').activeRunId, isNull);
    expect(store.readState('jietiao', 'ep07').steps['cast']!.status,
        DramaStatus.failed);
  });

  test('second concurrent run is rejected', () async {
    final gate = Completer<void>();
    final gateway = FakeDramaMediaGateway(imageGate: gate.future);
    final r = runner(gateway);
    final first = await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.cast,
    );
    await Future<void>.delayed(Duration.zero);
    expect(
      () => r.startStep(
        seriesId: 'jietiao',
        episodeId: 'ep07',
        step: DramaStep.cast,
      ),
      throwsA(isA<StateError>()),
    );
    gate.complete();
    await first.done;
  });

  test('cancel stops after the in-flight item', () async {
    final gate = Completer<void>();
    final gateway = FakeDramaMediaGateway(imageGate: gate.future);
    final r = runner(gateway);
    final run = await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.cast,
    );
    await Future<void>.delayed(Duration.zero);
    await r.cancel(run.id);
    gate.complete();
    await run.done;
    expect(run.status, DramaRunStatus.cancelled);
    expect(store.readState('jietiao', 'ep07').activeRunId, isNull);
  });

  test('recoverOrphan marks a stale active run interrupted', () {
    final state = DramaEpisodeState.empty('jietiao', 'ep07')
        .withActiveRun('ghost-run')
        .withStep(
          'cast',
          DramaStepRun(status: DramaStatus.running),
        );
    store.writeState('jietiao', 'ep07', state);
    runner(FakeDramaMediaGateway()).recoverOrphan('jietiao', 'ep07');
    final after = store.readState('jietiao', 'ep07');
    expect(after.activeRunId, isNull);
    expect(after.steps['cast']!.status, DramaStatus.interrupted);
  });

  test('frame-only run works without a plan', () async {
    store.writeStoryboard('jietiao', 'ep07', multiBoard());
    final gateway = FakeDramaMediaGateway();
    final r = runner(gateway);
    final run = await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.frame,
      target: DramaRunTarget.frame,
    );
    await run.done;
    expect(run.status, DramaRunStatus.completed);
    expect(gateway.imageCalls, 2);
    expect(store.readPlanJson('jietiao', 'ep07'), isNull);
  });

  test('frame run generates frames then i2v/local clips with costs', () async {
    store.writeStoryboard('jietiao', 'ep07', multiBoard());
    store.writePlanJson('jietiao', 'ep07', planJson());
    final gateway = FakeDramaMediaGateway(imageCost: 0.2, clipCost: 0.45);
    final r = runner(gateway);
    final run = await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.frame,
    );
    await run.done;
    expect(run.status, DramaRunStatus.completed);
    expect(gateway.imageCalls, 2);
    expect(gateway.clipCalls, 1);
    expect(gateway.localCalls, 1);
    final state = store.readState('jietiao', 'ep07');
    expect(state.actualYuan, closeTo(0.85, 0.001));
    expect(state.shots['s01']!.frame.status, DramaStatus.succeeded);
    expect(state.shots['s01']!.clip.status, DramaStatus.succeeded);
    expect(state.shots['s02']!.clip.status, DramaStatus.succeeded);
    expect(
      store.assetFile('jietiao', 'ep07', state.shots['s01']!.clip.path!)
          .existsSync(),
      isTrue,
    );
  });

  test('changed storyboard re-runs only the affected shot', () async {
    store.writeStoryboard('jietiao', 'ep07', multiBoard());
    store.writePlanJson('jietiao', 'ep07', planJson());
    final gateway = FakeDramaMediaGateway();
    final r = runner(gateway);
    await (await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.frame,
    )).done;
    expect(gateway.imageCalls, 2);
    store.writeStoryboard('jietiao', 'ep07', multiBoard(s02Visual: '院门口，雨'));
    await (await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.frame,
    )).done;
    expect(gateway.imageCalls, 3);
    expect(gateway.localCalls, 2);
  });

  test('one failing shot does not stop the batch', () async {
    store.writeStoryboard('jietiao', 'ep07', multiBoard());
    store.writePlanJson('jietiao', 'ep07', planJson());
    final gateway = FakeDramaMediaGateway()..failImageCall = 2;
    final r = runner(gateway);
    final run = await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.frame,
    );
    await run.done;
    expect(run.status, DramaRunStatus.failed);
    final state = store.readState('jietiao', 'ep07');
    expect(state.shots['s01']!.clip.status, DramaStatus.succeeded);
    expect(state.shots['s02']!.frame.status, DramaStatus.failed);
    expect(state.shots['s02']!.clip.status, DramaStatus.pending);
  });

  test('degrade forces a local clip for an i2v shot', () async {
    store.writeStoryboard('jietiao', 'ep07', multiBoard());
    store.writePlanJson('jietiao', 'ep07', planJson());
    final gateway = FakeDramaMediaGateway();
    final r = runner(gateway);
    await (await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.frame,
      target: DramaRunTarget.frame,
    )).done;
    final run = await r.startShot(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      shotId: 's01',
      target: DramaRunTarget.clip,
      degrade: true,
    );
    await run.done;
    expect(gateway.clipCalls, 0);
    expect(gateway.localCalls, 1);
  });

  test('t2v plan skips the frame and calls t2v', () async {
    store.writeStoryboard('jietiao', 'ep07', multiBoard());
    store.writePlanJson('jietiao', 'ep07', <String, Object?>{
      'shots': <Object?>[
        <String, Object?>{
          'shot_id': 's01',
          'route': 'i2v',
          'i2v_seconds': 3,
          'duration_s': 3.2,
        },
        <String, Object?>{
          'shot_id': 's02',
          'route': 't2v',
          'i2v_seconds': 0,
          'duration_s': 2,
        },
      ],
    });
    final gateway = FakeDramaMediaGateway();
    final r = runner(gateway);
    final run = await r.startStep(
      seriesId: 'jietiao',
      episodeId: 'ep07',
      step: DramaStep.frame,
    );
    await run.done;
    expect(run.status, DramaRunStatus.completed);
    expect(gateway.imageCalls, 1);
    expect(gateway.t2vCalls, 1);
    expect(gateway.clipCalls, 1);
    final state = store.readState('jietiao', 'ep07');
    expect(state.shots['s02']!.frame.status, DramaStatus.pending);
    expect(state.shots['s02']!.clip.status, DramaStatus.succeeded);
  });
}
