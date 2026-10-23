import 'package:flutter_wanxiang/pipeline/drama/episode.dart';
import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/frame.dart';
import 'package:test/test.dart';

void expectFatal(void Function() fn) {
  expect(
    fn,
    throwsA(isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal)),
  );
}

DramaSeries series() => DramaSeries.fromJson(<String, Object?>{
  'series_id': 'jietiao',
  'title': '借条',
  'dialect': 'henan',
  'defaults': <String, Object?>{
    'total_budget_yuan': 88,
    'i2v_budget_yuan': 18,
    'max_i2v_seconds': 4,
  },
  'beat_template': <Object?>[
    <String, Object?>{'id': 'hook', 'label': '钩子', 'summary': '开场'},
  ],
});

void main() {
  test('create copies series defaults and beat template', () {
    final episode = DramaEpisode.create(
      series: series(),
      episodeId: 'ep07',
      title: '堂屋对峙',
      number: 7,
    );
    expect(episode.seriesId, 'jietiao');
    expect(episode.number, 7);
    expect(episode.settings.dialect, 'henan');
    expect(episode.settings.frame, FrameSize.vertical);
    expect(episode.settings.totalBudgetYuan, 88);
    expect(episode.settings.i2vBudgetYuan, 18);
    expect(episode.settings.maxI2vSeconds, 4);
    expect(episode.story.beats.single.id, 'hook');
    expect(episode.story.promptVersion, 1);
  });

  test('roundtrip is canonical idempotent', () {
    final episode = DramaEpisode.create(
      series: series(),
      episodeId: 'ep07',
      title: '堂屋对峙',
      number: 7,
    ).copyWith(
      source: const DramaSource(kind: 'story', text: '二舅闯进堂屋。'),
      story: const DramaStory(
        logline: '二舅逼债',
        synopsis: '小满翻出第二张借条',
        sourceHash: 'sha256:abc',
      ),
    );
    expect(DramaEpisode.fromJson(episode.toJson()).toJson(), episode.toJson());
    expect(DramaEpisode.fromJson(episode.toJson()).source.text, '二舅闯进堂屋。');
  });

  test('partial settings fall back to series-like defaults', () {
    final episode = DramaEpisode.fromJson(<String, Object?>{
      'series_id': 'jietiao',
      'episode_id': 'ep07',
      'title': '堂屋对峙',
      'settings': <String, Object?>{'total_budget_yuan': 30},
    });
    expect(episode.settings.dialect, 'mandarin');
    expect(episode.settings.frame, FrameSize.vertical);
    expect(episode.settings.totalBudgetYuan, 30);
    expect(episode.settings.i2vBudgetYuan, 20);
    expect(episode.settings.targetDurationS, 90);
  });

  test('rejects non-positive settings and invalid ids', () {
    expectFatal(
      () => DramaEpisode.fromJson(<String, Object?>{
        'series_id': 'jietiao',
        'episode_id': 'ep07',
        'title': 'x',
        'settings': <String, Object?>{'total_budget_yuan': -1},
      }),
    );
    expectFatal(
      () => DramaEpisode.fromJson(<String, Object?>{
        'series_id': 'jietiao',
        'episode_id': '../ep07',
        'title': 'x',
      }),
    );
    expectFatal(
      () => DramaEpisode.fromJson(<String, Object?>{
        'series_id': 'jietiao',
        'episode_id': 'ep07',
        'title': 'x',
        'settings': <String, Object?>{'target_duration_s': 0},
      }),
    );
  });

  test('copyWith keeps ids and replaces story/settings', () {
    final original = DramaEpisode.create(
      series: series(),
      episodeId: 'ep07',
      title: '堂屋对峙',
    );
    final next = original.copyWith(
      title: '堂屋对峙 · 改',
      story: const DramaStory(logline: '新 logline'),
      settings: original.settings.copyWith(totalBudgetYuan: 50),
    );
    expect(next.seriesId, 'jietiao');
    expect(next.episodeId, 'ep07');
    expect(next.title, '堂屋对峙 · 改');
    expect(next.story.logline, '新 logline');
    expect(next.settings.totalBudgetYuan, 50);
  });
}
