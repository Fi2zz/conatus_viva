import 'package:flutter_wanxiang/pipeline/drama/episode.dart';
import 'package:flutter_wanxiang/pipeline/drama/hash.dart';
import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/drama/state.dart';
import 'package:flutter_wanxiang/pipeline/drama/steps.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:test/test.dart';

DramaSeries series() => DramaSeries.fromJson(<String, Object?>{
  'series_id': 'jietiao',
  'title': '借条',
  'cast': <String, Object?>{
    'erniu': <String, Object?>{
      'name': '二舅',
      'avatar': <String, Object?>{
        'path': 'cast/erniu/9f2c.png',
        'source_hash': 'sha256:abc',
        'model': 'wan2.7-image',
        'cost_yuan': 0.5,
        'approved': true,
      },
    },
  },
});

Storyboard board() => Storyboard.fromJson(<String, Object?>{
  'content_id': 'ep07',
  'cast': <String, Object?>{
    'erniu': <String, Object?>{'name': '二舅'},
  },
  'shots': <Object?>[
    <String, Object?>{'id': 's01', 'kind': 'speak_off', 'speaker': 'erniu', 'line': '还钱。'},
  ],
});

DramaStepView find(List<DramaStepView> steps, DramaStep key) =>
    steps.firstWhere((s) => s.key == key);

void main() {
  test('empty episode: all steps pending, unwired false', () {
    final s = series();
    final episode = DramaEpisode.create(series: s, episodeId: 'ep07', title: '堂屋对峙', number: 7);
    final steps = deriveDramaSteps(
      series: s,
      episode: episode,
      storyboard: null,
      planJson: null,
      state: DramaEpisodeState.empty('jietiao', 'ep07'),
      wired: kP1WiredSteps,
    );
    expect(steps.map((s) => s.key), kDramaStepOrder);
    expect(steps.every((s) => s.status == DramaStatus.pending), isTrue);
    expect(find(steps, DramaStep.cast).wired, isFalse);
    expect(find(steps, DramaStep.split).wired, isTrue);
  });

  test('split/story/board complete from source, story and plan hash', () {
    final s = series();
    final episode = DramaEpisode.create(
      series: s,
      episodeId: 'ep07',
      title: '堂屋对峙',
      number: 7,
    ).copyWith(
      source: const DramaSource(kind: 'story', text: '二舅闯进堂屋'),
      story: DramaStory(
        logline: '二舅逼债',
        synopsis: '小满翻出第二张借条',
        beats: const <DramaBeat>[DramaBeat(id: 'hook', label: '钩子', summary: '拍桌')],
        sourceHash: dramaHash(<String, Object?>{'text': '二舅闯进堂屋'}),
      ),
    );
    final b = board();
    final state = DramaEpisodeState.empty('jietiao', 'ep07')
        .withPlanHash(dramaPlanHash(storyboard: b, episode: episode));
    final steps = deriveDramaSteps(
      series: s,
      episode: episode,
      storyboard: b,
      planJson: <String, Object?>{'shots': <Object?>[]},
      state: state,
      wired: kP1WiredSteps,
    );
    expect(find(steps, DramaStep.split).status, DramaStatus.succeeded);
    expect(find(steps, DramaStep.story).status, DramaStatus.succeeded);
    expect(find(steps, DramaStep.board).status, DramaStatus.succeeded);
    expect(find(steps, DramaStep.frame).status, DramaStatus.pending);
    expect(find(steps, DramaStep.voice).status, DramaStatus.pending);
  });

  test('split fails again when source text changes', () {
    final s = series();
    final episode = DramaEpisode.create(series: s, episodeId: 'ep07', title: 'x').copyWith(
      source: const DramaSource(kind: 'story', text: '新文本'),
      story: DramaStory(
        logline: 'l',
        synopsis: 's',
        beats: const <DramaBeat>[DramaBeat(id: 'hook', label: '钩子', summary: '')],
        sourceHash: dramaHash(<String, Object?>{'text': '旧文本'}),
      ),
    );
    final steps = deriveDramaSteps(
      series: s,
      episode: episode,
      storyboard: null,
      planJson: null,
      state: DramaEpisodeState.empty('jietiao', 'ep07'),
      wired: kP1WiredSteps,
    );
    expect(find(steps, DramaStep.split).status, DramaStatus.pending);
  });

  test('failed state overrides derived success', () {
    final s = series();
    final episode = DramaEpisode.create(series: s, episodeId: 'ep07', title: 'x').copyWith(
      source: const DramaSource(kind: 'story', text: '文本'),
      story: DramaStory(
        logline: 'l',
        synopsis: 's',
        beats: const <DramaBeat>[DramaBeat(id: 'hook', label: '钩子', summary: '')],
        sourceHash: dramaHash(<String, Object?>{'text': '文本'}),
      ),
    );
    final state = DramaEpisodeState.empty('jietiao', 'ep07').withStep(
      'split',
      DramaStepRun(status: DramaStatus.failed, error: 'boom'),
    );
    final steps = deriveDramaSteps(
      series: s,
      episode: episode,
      storyboard: null,
      planJson: null,
      state: state,
      wired: kP1WiredSteps,
    );
    expect(find(steps, DramaStep.split).status, DramaStatus.failed);
  });

  test('state roundtrips and caps logs at 200', () {
    final state = DramaEpisodeState.empty('jietiao', 'ep07').withPlanHash('sha256:x');
    final again = DramaEpisodeState.fromJson(state.toJson());
    expect(again.planHash, 'sha256:x');
    expect(again.steps.keys, kDramaStepOrder.map(dramaStepKey));
    final run = DramaStepRun(
      logs: List<String>.generate(250, (i) => 'line $i'),
    );
    expect(run.logs, hasLength(200));
    expect(run.logs.first, 'line 50');
  });
}
