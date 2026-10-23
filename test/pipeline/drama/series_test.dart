import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/frame.dart';
import 'package:test/test.dart';

/// 断言 fn 抛出 PipelineError(ErrorClass.fatal)。
void expectFatal(void Function() fn) {
  expect(
    fn,
    throwsA(isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal)),
  );
}

Map<String, Object?> fullSeriesJson() => <String, Object?>{
  'series_id': 'jietiao',
  'title': '借条',
  'logline': '一张旧借条把两个家庭重新拖回堂屋。',
  'dialect': 'henan',
  'frame': '1080x1920',
  'content_type': 'manju',
  'planned_episodes': 80,
  'defaults': <String, Object?>{
    'total_budget_yuan': 120,
    'i2v_budget_yuan': 20,
    'max_i2v_seconds': 6,
    'cast_image_model': 'wan2.7-image',
    'frame_image_model': 'wan2.7-image',
    'clip_video_model': 'wan2.6-i2v-flash',
    't2v_model': 'wan3.0-video',
    'resolution': '720P',
  },
  'beat_template': <Object?>[
    <String, Object?>{
      'id': 'hook',
      'label': '钩子',
      'summary': '借条拍桌',
      'target_s': 3.0,
      'weight': 3,
    },
  ],
  'cast': <String, Object?>{
    'erniu': <String, Object?>{
      'name': '二舅',
      'description': '五十岁，旧夹克',
      'voice_id': 'voice-1',
      'dialect': 'henan',
      'avatar': <String, Object?>{
        'path': 'cast/erniu/9f2c.png',
        'source_hash': 'sha256:abc',
        'model': 'wan2.7-image',
        'cost_yuan': 0.5,
        'approved': true,
      },
    },
  },
};

void main() {
  test('parses defaults, cast and beat template', () {
    final series = DramaSeries.fromJson(fullSeriesJson());
    expect(series.seriesId, 'jietiao');
    expect(series.title, '借条');
    expect(series.frame.label, '1080x1920');
    expect(series.defaults.totalBudgetYuan, 120);
    expect(series.defaults.i2vBudgetYuan, 20);
    expect(series.defaults.maxI2vSeconds, 6);
    expect(series.defaults.clipVideoModel, 'wan2.6-i2v-flash');
    expect(series.beatTemplate.single.label, '钩子');
    expect(series.beatTemplate.single.targetS, 3.0);
    expect(series.cast['erniu']!.name, '二舅');
    expect(series.cast['erniu']!.voiceId, 'voice-1');
    expect(series.cast['erniu']!.avatar!.approved, isTrue);
    expect(series.storyboardCast()['erniu']!.name, '二舅');
  });

  test('minimal input fills defaults', () {
    final series = DramaSeries.fromJson(<String, Object?>{
      'series_id': 'solo',
      'title': '独幕',
    });
    expect(series.dialect, 'mandarin');
    expect(series.frame, FrameSize.vertical);
    expect(series.plannedEpisodes, 1);
    expect(series.defaults.totalBudgetYuan, 120);
    expect(series.beatTemplate, isEmpty);
    expect(series.cast, isEmpty);
  });

  test('roundtrip is canonical idempotent', () {
    final series = DramaSeries.fromJson(fullSeriesJson());
    expect(DramaSeries.fromJson(series.toJson()).toJson(), series.toJson());
  });

  test('create copies defaults and can be copied', () {
    final series = DramaSeries.create(
      seriesId: 'jietiao',
      title: '借条',
      totalBudgetYuan: 88,
      i2vBudgetYuan: 18,
      cast: <String, DramaCastMember>{
        'erniu': const DramaCastMember(castId: 'erniu', name: '二舅'),
      },
    );
    expect(series.defaults.totalBudgetYuan, 88);
    expect(series.storyboardCast()['erniu']!.name, '二舅');
    final renamed = series.copyWith(title: '借条 · 改');
    expect(renamed.title, '借条 · 改');
    expect(renamed.seriesId, 'jietiao');
  });

  test('rejects invalid id, frame and non-positive budgets', () {
    expectFatal(
      () => DramaSeries.fromJson(<String, Object?>{
        'series_id': '../x',
        'title': 'x',
      }),
    );
    expectFatal(
      () => DramaSeries.fromJson(<String, Object?>{
        'series_id': 'ok',
        'title': 'x',
        'frame': 'wide',
      }),
    );
    expectFatal(
      () => DramaSeries.fromJson(<String, Object?>{
        'series_id': 'ok',
        'title': 'x',
        'defaults': <String, Object?>{'total_budget_yuan': 0},
      }),
    );
    expectFatal(
      () => DramaSeries.fromJson(<String, Object?>{
        'series_id': 'ok',
        'title': '',
      }),
    );
  });

  test('chinese text survives roundtrip', () {
    final series = DramaSeries.fromJson(fullSeriesJson());
    final json = series.toJson();
    final again = DramaSeries.fromJson(json);
    expect(again.cast['erniu']!.description, '五十岁，旧夹克');
  });
}
