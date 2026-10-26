/// 手工真实 smoke：只在小额确认后运行，默认跳过。
///
/// Run: `RUN_REAL_DRAMA=1 dart test test/manual/drama_real_smoke.dart`
///
/// 前提：已在 app 设置页把 DASHSCOPE_API_KEY 写入系统钥匙串。
/// 预估费用约 ¥0.85（1 定妆图 + 1 首帧 + 3 秒 i2v），以实际账单为准。
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

DramaSeries _series() => DramaSeries.create(
  seriesId: 'smoke',
  title: '真实 smoke',
  cast: <String, DramaCastMember>{
    'erniu': const DramaCastMember(
      castId: 'erniu',
      name: '二舅',
      description: '五十岁，短寸，旧夹克',
    ),
  },
);

Storyboard _board() => Storyboard.fromJson(<String, Object?>{
  'content_id': 'ep01',
  'cast': <String, Object?>{'erniu': <String, Object?>{'name': '二舅'}},
  'shots': <Object?>[
    <String, Object?>{
      'id': 's01',
      'kind': 'action',
      'speaker': 'erniu',
      'line': '',
      'duration_s': 3,
      'priority': 'hook',
      'visual': '堂屋里，一张旧借条拍在桌上，暖色电影光',
      'motion': '镜头缓慢推近借条',
    },
  ],
});

void main() {
  final enabled = Platform.environment['RUN_REAL_DRAMA'] == '1';
  test(
    'real cast + frame + 3s i2v smoke',
    () async {
      final temp = Directory.systemTemp.createTempSync('drama_real_smoke');
      try {
        final key = await _keyFromKeychain();
        final configFile = File('pipeline_config.json');
        final cfg = await PipelineConfig.load(
          file: configFile,
          env: const <String, String>{},
        );
        cfg.updateSecrets(<String, String?>{'DASHSCOPE_API_KEY': key});
        final pricing = dramaPricingFromConfig(cfg);
        final store = DramaStore(rootDir: temp.path);
        final series = _series();
        store.createSeries(series);
        final episode = DramaEpisode.create(
          series: series,
          episodeId: 'ep01',
          title: '真实 smoke',
        );
        store.createEpisode(episode);
        final board = _board();
        store.writeStoryboard('smoke', 'ep01', board);
        final plan = buildDramaPlan(
          storyboard: board,
          episode: episode,
          priceYuanPerSecond: pricing.i2vYuanPerSecond,
        );
        store.writePlanJson('smoke', 'ep01', plan.toJson());

        final estimate = estimateDrama(
          series: series,
          episode: episode,
          storyboard: board,
          planJson: plan.toJson(),
          state: DramaEpisodeState.empty('smoke', 'ep01'),
          request: const DramaEstimateRequest(
            step: DramaEstimateStep.frame,
            target: DramaRunTarget.all,
          ),
          pricing: pricing,
          store: store,
        );
        // 定妆另行估价。
        final castEstimate = estimateDrama(
          series: series,
          episode: episode,
          storyboard: board,
          planJson: plan.toJson(),
          state: DramaEpisodeState.empty('smoke', 'ep01'),
          request: const DramaEstimateRequest(step: DramaEstimateStep.cast),
          pricing: pricing,
          store: store,
        );
        final total = estimate.totalEstimatedYuan + castEstimate.totalEstimatedYuan;
        // 不打印密钥；只打印价格与镜头数。
        stdout.writeln('real smoke estimate: ¥${total.toStringAsFixed(2)}');
        expect(total, lessThanOrEqualTo(_maxEstimateYuan));

        final gateway = DashScopeDramaMediaGateway(cfg: cfg, pricing: pricing);
        final runner = DramaRunner(store: store, gateway: gateway);
        final castRun = await runner.startStep(
          seriesId: 'smoke',
          episodeId: 'ep01',
          step: DramaStep.cast,
        );
        await castRun.done;
        expect(castRun.status, DramaRunStatus.completed);
        final castSeries = store.readSeries('smoke');
        final avatar = castSeries.cast['erniu']!.avatar!;
        expect(
          store.seriesAssetFile('smoke', avatar.path).existsSync(),
          isTrue,
        );
        // 采用定妆，再跑画面。
        store.writeSeries(
          castSeries.withCastMember(
            castSeries.cast['erniu']!.copyWith(
              avatar: DramaCastAvatar(
                path: avatar.path,
                sourceHash: avatar.sourceHash,
                model: avatar.model,
                costYuan: avatar.costYuan,
                approved: true,
              ),
            ),
          ),
        );

        final frameRun = await runner.startStep(
          seriesId: 'smoke',
          episodeId: 'ep01',
          step: DramaStep.frame,
        );
        await frameRun.done;
        expect(frameRun.status, DramaRunStatus.completed);
        final state = store.readState('smoke', 'ep01');
        expect(state.actualYuan, greaterThan(0));
        final clipPath = state.shots['s01']!.clip.path!;
        final clip = store.assetFile('smoke', 'ep01', clipPath);
        expect(clip.existsSync(), isTrue);
        expect(await mediaDurationSeconds(clip), closeTo(3, 1.5));
        stdout.writeln('real smoke clip: ${clip.path}');
        stdout.writeln('real smoke cost: ¥${state.actualYuan.toStringAsFixed(2)}');
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    },
    skip: enabled ? false : 'set RUN_REAL_DRAMA=1 after confirming the cost',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
