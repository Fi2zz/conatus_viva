/// 手工真实 t2v smoke：仅在确认费用后运行，默认跳过。
///
/// Run: `RUN_REAL_T2V=1 dart test test/manual/drama_t2v_smoke.dart`
///
/// 1 条 2 秒 establishing 镜头，预估 ¥0.84（wan3.0-video 720P）。
library;

import 'dart:io';

import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/drama/cost.dart';
import 'package:flutter_wanxiang/pipeline/drama/episode.dart';
import 'package:flutter_wanxiang/pipeline/drama/media_gateway.dart';
import 'package:flutter_wanxiang/pipeline/drama/pricing.dart';
import 'package:flutter_wanxiang/pipeline/drama/run_target.dart';
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
const _maxEstimateYuan = 2.0;

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

Storyboard _board() => Storyboard.fromJson(<String, Object?>{
  'content_id': 'ep01',
  'shots': <Object?>[
    <String, Object?>{
      'id': 's01',
      'kind': 'establishing',
      'line': '',
      'duration_s': 2,
      'priority': 'normal',
      'visual': '雨夜的堂屋门口，一盏昏黄灯泡，镜头缓慢推进',
    },
  ],
});

void main() {
  final enabled = Platform.environment['RUN_REAL_T2V'] == '1';
  test(
    'real establishing t2v smoke',
    () async {
      final temp = Directory.systemTemp.createTempSync('drama_t2v_smoke');
      try {
        final key = await _keyFromKeychain();
        final cfg = await PipelineConfig.load(
          file: File('pipeline_config.json'),
          env: const <String, String>{},
        );
        cfg.updateSecrets(<String, String?>{'DASHSCOPE_API_KEY': key});
        final pricing = dramaPricingFromConfig(cfg);
        final store = DramaStore(rootDir: temp.path);
        final series = DramaSeries.create(seriesId: 't2v', title: 't2v smoke');
        store.createSeries(series);
        final episode = DramaEpisode.create(
          series: series,
          episodeId: 'ep01',
          title: 't2v smoke',
        );
        store.createEpisode(episode);
        final board = _board();
        store.writeStoryboard('t2v', 'ep01', board);
        final plan = buildDramaPlan(
          storyboard: board,
          episode: episode,
          priceYuanPerSecond: pricing.i2vYuanPerSecond,
          t2vPriceYuanPerSecond: pricing.videoPrice('wan3.0-video', '720P'),
        );
        store.writePlanJson('t2v', 'ep01', plan.toJson());
        expect(plan.shots.single.route.name, 't2v');

        final estimate = estimateDrama(
          series: series,
          episode: episode,
          storyboard: board,
          planJson: plan.toJson(),
          state: DramaEpisodeState.empty('t2v', 'ep01'),
          request: const DramaEstimateRequest(
            step: DramaEstimateStep.frame,
            target: DramaRunTarget.all,
          ),
          pricing: pricing,
          store: store,
        );
        stdout.writeln(
          'real t2v estimate: ¥${estimate.totalEstimatedYuan.toStringAsFixed(2)}',
        );
        expect(estimate.totalEstimatedYuan, lessThanOrEqualTo(_maxEstimateYuan));

        final gateway = DashScopeDramaMediaGateway(cfg: cfg, pricing: pricing);
        final runner = DramaRunner(store: store, gateway: gateway);
        final run = await runner.startStep(
          seriesId: 't2v',
          episodeId: 'ep01',
          step: DramaStep.frame,
          target: DramaRunTarget.all,
        );
        await run.done;
        expect(run.status, DramaRunStatus.completed);
        final state = store.readState('t2v', 'ep01');
        expect(state.shots['s01']!.frame.status, DramaStatus.pending);
        final clip = store.assetFile(
          't2v',
          'ep01',
          state.shots['s01']!.clip.path!,
        );
        expect(clip.existsSync(), isTrue);
        expect(await mediaDurationSeconds(clip), closeTo(2, 1));
        stdout.writeln('real t2v clip: ${clip.path}');
        stdout.writeln(
          'real t2v cost: ¥${state.actualYuan.toStringAsFixed(2)}',
        );
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    skip: enabled ? false : 'set RUN_REAL_T2V=1 after confirming the cost',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
