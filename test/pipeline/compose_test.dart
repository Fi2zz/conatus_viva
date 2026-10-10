import 'dart:io';

import 'package:flutter_wanxiang/pipeline/artifacts.dart';
import 'package:flutter_wanxiang/pipeline/bailian/tts.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/ffmpeg.dart';
import 'package:flutter_wanxiang/pipeline/state.dart';
import 'package:flutter_wanxiang/pipeline/steps/compose.dart';
import 'package:flutter_wanxiang/pipeline/steps/script.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Workdir work;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_compose_test');
    work = Workdir(tmp.path, 'content');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// Real 1280x720/24fps h264 clip via lavfi (compose stream-copies video).
  Future<File> makeClip(String name, double seconds) async {
    final out = File('${tmp.path}/$name');
    await runFfmpeg([
      '-v', 'error', '-y',
      '-f', 'lavfi',
      '-i', 'testsrc=size=1280x720:rate=24,format=yuv420p',
      '-t', '$seconds',
      '-c:v', 'libx264',
      '-pix_fmt', 'yuv420p',
      out.path,
    ]);
    return out;
  }

  Future<File> makeWav(String name, double seconds) async {
    final out = File('${tmp.path}/$name');
    await runFfmpeg([
      '-v', 'error', '-y',
      '-f', 'lavfi',
      '-i', 'sine=frequency=440:sample_rate=44100',
      '-t', '$seconds',
      out.path,
    ]);
    return out;
  }

  Future<void> placeClip(int i, double seconds) async {
    final clips = work.dirOf(ArtifactPaths.clipsDir)
      ..createSync(recursive: true);
    final clip = await makeClip('clip_src_$i.mp4', seconds);
    clip.copySync('${clips.path}/seg_$i.mp4');
  }

  ContentState makeState(List<int> durations, List<double> audioSecs) {
    final state = ContentState.load(work.dir);
    state.contentId = 'content';
    for (var i = 0; i < durations.length; i++) {
      state.segments.add(
        SegmentState(i: i, audioS: audioSecs[i], durationS: durations[i]),
      );
    }
    return state;
  }

  SegmentScript script(String id, String line) =>
      SegmentScript(photoId: id, line: line, motionPrompt: null);

  group('compose step (real ffmpeg)', () {
    test('av mismatch beyond 0.2s fails compose', () async {
      // 5s clip while state claims 6s: mux pads audio to 6s but the copied
      // video stream stays 5s → |video − audio| ≈ 1s (Review Focus #5).
      await placeClip(0, 5);
      final wav = await makeWav('seg0.wav', 6);
      final state = makeState([6], [6.0]);
      await expectLater(
        runComposeStep(
          work: work,
          state: state,
          scripts: [script('p0', '第一句台词')],
          audios: [TtsAudio(wav: wav, seconds: 6.0)],
        ),
        throwsA(
          isA<PipelineError>()
              .having((e) => e.cls, 'cls', ErrorClass.fatal)
              .having((e) => e.message, 'message', contains('av_mismatch')),
        ),
      );
      // 校验失败不得发布最终工件。
      expect(work.exists(ArtifactPaths.finalVideo), isFalse);
      expect(state.step('compose').status, StepStatus.failed);
    });

    test('offline compose produces playable final.mp4 + srt', () async {
      await placeClip(0, 3);
      await placeClip(1, 3);
      final wav0 = await makeWav('a0.wav', 2);
      final wav1 = await makeWav('a1.wav', 2.5);
      final state = makeState([3, 3], [2.0, 2.5]);
      final scripts = [
        script('p0', '[very slowly]今天天气很好'),
        script('p1', '我们一起出去走走'),
      ];
      final audios = [
        TtsAudio(wav: wav0, seconds: 2.0),
        TtsAudio(wav: wav1, seconds: 2.5),
      ];

      final out = await runComposeStep(
        work: work,
        state: state,
        scripts: scripts,
        audios: audios,
      );

      expect(out.path, work.file(ArtifactPaths.finalVideo).path);
      expect(await mediaDurationSeconds(out), closeTo(6.0, 0.2));
      expect(state.step('compose').status, StepStatus.succeeded);

      final srtFile = work.file(ArtifactPaths.finalSrt);
      final bytes = await srtFile.readAsBytes();
      expect(bytes.sublist(0, 3), isNot(orderedEquals([0xEF, 0xBB, 0xBF])));
      final content = await srtFile.readAsString();
      expect(content.contains('\r'), isFalse);
      expect(content, contains('今天天气很好'));
      expect(content, isNot(contains('['))); // 控制标签不进字幕
      expect(content, contains('00:00:00,000 --> 00:00:02,000'));
      expect(content, contains('00:00:03,000 --> 00:00:05,500'));

      // concat 列表在成功后由 compose 清理（Task 5 review 遗留项）。
      final leftovers = Directory(work.dir)
          .listSync(recursive: true)
          .where((e) => e.path.endsWith('.concat.txt'));
      expect(leftovers, isEmpty);

      // 幂等重跑：删掉 06_concat 后再跑，命中 stepDone 直接跳过。
      work.dirOf(ArtifactPaths.concatDir).deleteSync(recursive: true);
      await runComposeStep(
        work: work,
        state: state,
        scripts: scripts,
        audios: audios,
      );
      expect(work.exists(ArtifactPaths.concatDir), isFalse);
      expect(state.step('compose').attempts, 1);
    });
  });
}
