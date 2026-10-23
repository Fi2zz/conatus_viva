import 'package:flutter_wanxiang/pipeline/drama/episode.dart';
import 'package:flutter_wanxiang/pipeline/drama/hash.dart';
import 'package:flutter_wanxiang/pipeline/drama/llm.dart';
import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:test/test.dart';

class _FakeLlm implements DramaLlm {
  _FakeLlm(this.responses);

  final List<Map<String, dynamic> Function()> responses;
  int calls = 0;
  final List<String> users = <String>[];

  @override
  Future<Map<String, dynamic>> chatJson({
    required String system,
    required String user,
  }) async {
    users.add(user);
    final response = responses[calls++];
    return response();
  }
}

DramaSeries series() => DramaSeries.fromJson(<String, Object?>{
  'series_id': 'jietiao',
  'title': '借条',
  'cast': <String, Object?>{
    'erniu': <String, Object?>{'name': '二舅'},
  },
});

DramaEpisode episode() => DramaEpisode.create(
  series: series(),
  episodeId: 'ep07',
  title: '堂屋对峙',
).copyWith(
  source: const DramaSource(kind: 'story', text: '二舅闯进堂屋'),
);

void main() {
  test('extract parses beats, cast and source hash without writing', () async {
    final fake = _FakeLlm(<Map<String, dynamic> Function()>[
      () => <String, dynamic>{
        'logline': '二舅逼债',
        'synopsis': '小满翻出第二张借条',
        'beats': <Object?>[
          <String, Object?>{'id': 'hook', 'label': '钩子', 'summary': '借条拍桌'},
        ],
        'cast_new': <String, Object?>{
          'xiaoman': <String, Object?>{'name': '小满'},
        },
        'cast_updates': <String, Object?>{},
      },
    ]);
    final result = await DramaDraftService(llm: fake).extract(
      series: series(),
      episode: episode(),
    );
    expect(result.logline, '二舅逼债');
    expect(result.synopsis, '小满翻出第二张借条');
    expect(result.beats.single.label, '钩子');
    expect(result.castNew['xiaoman']!.name, '小满');
    expect(result.sourceHash, dramaHash(<String, Object?>{'text': '二舅闯进堂屋'}));
    expect(fake.calls, 1);
  });

  test('extract retries once on schema error', () async {
    final fake = _FakeLlm(<Map<String, dynamic> Function()>[
      () => <String, dynamic>{'logline': 42},
      () => <String, dynamic>{
        'logline': '二舅逼债',
        'synopsis': '小满翻出第二张借条',
        'beats': <Object?>[
          <String, Object?>{'id': 'hook', 'label': '钩子', 'summary': ''},
        ],
      },
    ]);
    final result = await DramaDraftService(llm: fake).extract(
      series: series(),
      episode: episode(),
    );
    expect(result.logline, '二舅逼债');
    expect(fake.calls, 2);
    expect(fake.users.last, contains('修正'));
  });

  test('draft retries once and injects content_id/cast/id defaults', () async {
    final fake = _FakeLlm(<Map<String, dynamic> Function()>[
      () => <String, dynamic>{'shots': 'not-a-list'},
      () => <String, dynamic>{
        'title': '堂屋对峙',
        'shots': <Object?>[
          <String, Object?>{
            'kind': 'action',
            'visual': '借条特写',
            'duration_s': 3.0,
          },
        ],
      },
    ]);
    final draft = await DramaDraftService(llm: fake).draftStoryboard(
      series: series(),
      episode: episode(),
    );
    expect(fake.calls, 2);
    expect(draft.storyboard.contentId, 'ep07');
    expect(draft.storyboard.cast['erniu']!.name, '二舅');
    expect(draft.storyboard.shots.single.id, 's01');
    expect(draft.storyboard.shots.single.visual, '借条特写');
    expect(draft.warnings, contains('shot_id_generated:s01'));
  });

  test('unfixable draft is a fatal draft_schema error', () async {
    final fake = _FakeLlm(<Map<String, dynamic> Function()>[
      () => <String, dynamic>{'shots': 'bad'},
      () => <String, dynamic>{'shots': 'still-bad'},
    ]);
    await expectLater(
      DramaDraftService(llm: fake).draftStoryboard(
        series: series(),
        episode: episode(),
      ),
      throwsA(
        isA<PipelineError>()
            .having((e) => e.cls, 'cls', ErrorClass.fatal)
            .having((e) => e.message, 'message', startsWith('draft_schema:')),
      ),
    );
  });

  test('draft rejects empty shots after retry', () async {
    final fake = _FakeLlm(<Map<String, dynamic> Function()>[
      () => <String, dynamic>{'shots': <Object?>[]},
      () => <String, dynamic>{'shots': <Object?>[]},
    ]);
    await expectLater(
      DramaDraftService(llm: fake).draftStoryboard(
        series: series(),
        episode: episode(),
      ),
      throwsA(isA<PipelineError>()),
    );
  });
}
