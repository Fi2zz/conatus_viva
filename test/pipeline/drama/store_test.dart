import 'dart:io';

import 'package:flutter_wanxiang/pipeline/drama/episode.dart';
import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/drama/state.dart';
import 'package:flutter_wanxiang/pipeline/drama/store.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:test/test.dart';

DramaSeries series() => DramaSeries.create(seriesId: 'jietiao', title: '借条');

DramaEpisode episode(DramaSeries s) => DramaEpisode.create(
  series: s,
  episodeId: 'ep07',
  title: '堂屋对峙',
  number: 7,
);

void main() {
  late Directory tmp;
  late DramaStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('drama_store');
    store = DramaStore(rootDir: '${tmp.path}/drama');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('create/list/read/delete series and episodes', () {
    final s = series();
    store.createSeries(s);
    expect(store.listSeries().single.title, '借条');
    expect(store.readSeries('jietiao').seriesId, 'jietiao');

    store.createEpisode(episode(s));
    expect(store.listEpisodes('jietiao').single.title, '堂屋对峙');
    expect(store.readEpisode('jietiao', 'ep07').number, 7);

    store.deleteEpisode('jietiao', 'ep07');
    expect(store.listEpisodes('jietiao'), isEmpty);

    store.deleteSeries('jietiao');
    expect(store.listSeries(), isEmpty);
  });

  test('duplicate create is a conflict and leaves no tmp file', () {
    final s = series();
    store.createSeries(s);
    expect(() => store.createSeries(s), throwsStateError);
    expect(
      File('${store.seriesDir('jietiao')}/series.json.tmp').existsSync(),
      isFalse,
    );

    store.createEpisode(episode(s));
    expect(() => store.createEpisode(episode(s)), throwsStateError);
  });

  test('chinese text roundtrips and missing state is empty', () {
    final s = series();
    store.createSeries(s);
    final e = episode(s).copyWith(
      source: const DramaSource(kind: 'story', text: '二舅说：「还钱。」'),
    );
    store.createEpisode(e);
    expect(store.readEpisode('jietiao', 'ep07').source.text, '二舅说：「还钱。」');

    final state = store.readState('jietiao', 'ep07');
    expect(state.episodeId, 'ep07');
    expect(state.steps.keys, kDramaStepKeys);
  });

  test('storyboard, plan and state roundtrip', () {
    final s = series();
    store.createSeries(s);
    store.createEpisode(episode(s));

    final board = Storyboard.fromJson(<String, Object?>{
      'content_id': 'ep07',
      'shots': <Object?>[
        <String, Object?>{'id': 's01', 'kind': 'insert', 'visual': '借条特写'},
      ],
    });
    store.writeStoryboard('jietiao', 'ep07', board);
    expect(store.readStoryboard('jietiao', 'ep07')!.shots.single.visual, '借条特写');

    store.writePlanJson('jietiao', 'ep07', <String, Object?>{'total': 1});
    expect(store.readPlanJson('jietiao', 'ep07'), {'total': 1});

    final state = DramaEpisodeState.empty('jietiao', 'ep07').withPlanHash('sha256:x');
    store.writeState('jietiao', 'ep07', state);
    expect(store.readState('jietiao', 'ep07').planHash, 'sha256:x');
  });

  test('asset path cannot escape the episode dir', () {
    expect(
      () => store.assetFile('jietiao', 'ep07', '../secret.png'),
      throwsArgumentError,
    );
    expect(
      () => store.assetFile('jietiao', 'ep07', '/etc/passwd'),
      throwsArgumentError,
    );
    expect(
      () => store.assetFile('jietiao', 'ep07', ''),
      throwsArgumentError,
    );
  });

  test('series asset path cannot escape the series dir', () {
    expect(
      () => store.seriesAssetFile('jietiao', '../secret.png'),
      throwsArgumentError,
    );
    expect(
      () => store.seriesAssetFile('jietiao', '/etc/passwd'),
      throwsArgumentError,
    );
    expect(
      store.seriesAssetFile('jietiao', 'cast/erniu/hash/image-01.png'),
      isA<File>(),
    );
  });

  test('corrupt series is skipped by listSeries', () {
    Directory('${store.rootDir}/series/bad').createSync(recursive: true);
    File('${store.rootDir}/series/bad/series.json').writeAsStringSync('{');
    expect(store.listSeries(), isEmpty);
  });

  test('missing series/episode throws FileSystemException', () {
    expect(() => store.readSeries('nope'), throwsA(isA<FileSystemException>()));
    expect(
      () => store.readEpisode('jietiao', 'ep07'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
