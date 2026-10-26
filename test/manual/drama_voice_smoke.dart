/// 手工真实配音 smoke：仅在确认后运行，默认跳过。
///
/// Run: `RUN_REAL_VOICE=1 dart test test/manual/drama_voice_smoke.dart`
///
/// 1 句台词；TTS 价格未进目录，按实际账单计费。
library;

import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/drama/cost.dart';
import 'package:flutter_wanxiang/pipeline/drama/episode.dart';
import 'package:flutter_wanxiang/pipeline/drama/media_gateway.dart';
import 'package:flutter_wanxiang/pipeline/drama/pricing.dart';
import 'package:flutter_wanxiang/pipeline/drama/runner.dart';
import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/drama/state.dart';
import 'package:flutter_wanxiang/pipeline/drama/steps.dart';
import 'package:flutter_wanxiang/pipeline/drama/store.dart';
import 'package:flutter_wanxiang/pipeline/ffmpeg.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:test/test.dart';

const _service = 'com.conatusviva.secrets';
const _account = 'DASHSCOPE_API_KEY';

Future<String> _keyFromKeychain() async {
  final result = await Process.run('security', <String>[
    'find-generic-password',
    '-s',
    _service,
    '-a',
    _account,
    '-w',
  ]);
  if (result.exitCode != 0) {
    throw StateError('未在钥匙串找到 DASHSCOPE_API_KEY，请先在 app 设置页配置');
  }
  final key = (result.stdout as String).trim();
  if (key.isEmpty) throw StateError('钥匙串里的 DASHSCOPE_API_KEY 为空');
  return key;
}

void main() {
  final enabled = Platform.environment['RUN_REAL_VOICE'] == '1';
  test(
    'real one-line voice smoke',
    () async {
      final temp = Directory.systemTemp.createTempSync('drama_voice_smoke');
      try {
        final key = await _keyFromKeychain();
        final cfg = await PipelineConfig.load(
          file: File('pipeline_config.json'),
          env: const <String, String>{},
        );
        cfg.updateSecrets(<String, String?>{'DASHSCOPE_API_KEY': key});
        final pricing = dramaPricingFromConfig(cfg);
        final store = DramaStore(rootDir: temp.path);
        final series = DramaSeries.create(
          seriesId: 'voice',
          title: 'voice smoke',
          dialect: '河南',
          cast: <String, DramaCastMember>{
            'erniu': const DramaCastMember(
              castId: 'erniu',
              name: '二舅',
              description: '五十岁',
            ),
          },
        );
        store.createSeries(series);
        final episode = DramaEpisode.create(
          series: series,
          episodeId: 'ep01',
          title: 'voice smoke',
        );
        store.createEpisode(episode);
        store.writeStoryboard(
          'voice',
          'ep01',
          Storyboard.fromJson(<String, Object?>{
            'content_id': 'ep01',
            'cast': <String, Object?>{
              'erniu': <String, Object?>{'name': '二舅'},
            },
            'shots': <Object?>[
              <String, Object?>{
                'id': 's01',
                'kind': 'speak_off',
                'speaker': 'erniu',
                'line': '你欠我的，今天该还了。',
                'duration_s': 3,
                'priority': 'hook',
              },
            ],
          }),
        );

        final estimate = estimateDrama(
          series: series,
          episode: episode,
          storyboard: store.readStoryboard('voice', 'ep01'),
          planJson: null,
          state: DramaEpisodeState.empty('voice', 'ep01'),
          request: const DramaEstimateRequest(step: DramaEstimateStep.voice),
          pricing: pricing,
          store: store,
        );
        stdout.writeln(
          'real voice estimate: unpriced ${estimate.unpriced.length} 句（TTS 按实际账单）',
        );
        expect(estimate.unpriced, isNotEmpty);

        final gateway = DashScopeDramaMediaGateway(cfg: cfg, pricing: pricing);
        final runner = DramaRunner(store: store, gateway: gateway);
        final run = await runner.startStep(
          seriesId: 'voice',
          episodeId: 'ep01',
          step: DramaStep.voice,
        );
        await run.done;
        expect(run.status, DramaRunStatus.completed);
        final state = store.readState('voice', 'ep01');
        final audio = state.shots['s01']!.audio;
        expect(audio.status, DramaStatus.succeeded);
        expect(audio.durationS, greaterThan(0));
        final file = store.assetFile('voice', 'ep01', audio.path!);
        expect(file.existsSync(), isTrue);
        expect(
          await mediaDurationSeconds(file),
          closeTo(audio.durationS!, 0.2),
        );
        stdout.writeln('real voice wav: ${file.path}');
        stdout.writeln(
          'real voice duration: ${audio.durationS!.toStringAsFixed(2)}s',
        );
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    skip: enabled ? false : 'set RUN_REAL_VOICE=1 after confirming the cost',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
