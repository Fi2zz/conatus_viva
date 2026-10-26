import 'package:flutter_wanxiang/pipeline/drama/state.dart';
import 'package:test/test.dart';

void main() {
  test('withShot / withActualYuan / withActiveRun / withWarnings preserve fields', () {
    final base = DramaEpisodeState.empty('s', 'e')
        .withStoryboardHash('sha256:board')
        .withPlanHash('sha256:plan');
    final shot = DramaShotState(
      frame: const DramaArtifact(
        status: DramaStatus.succeeded,
        path: 'assets/frames/s01/a/image-01.png',
        sourceHash: 'sha256:frame',
        model: 'wan2.7-image',
        costYuan: 0.35,
      ),
    );
    final next = base
        .withShot('s01', shot)
        .withActualYuan(0.35)
        .withActiveRun('run-1')
        .withWarnings(<String>['w1']);
    expect(next.storyboardHash, 'sha256:board');
    expect(next.planHash, 'sha256:plan');
    expect(next.shots['s01']!.frame.path, 'assets/frames/s01/a/image-01.png');
    expect(next.actualYuan, 0.35);
    expect(next.activeRunId, 'run-1');
    expect(next.warnings, <String>['w1']);
    expect(next.steps.keys, kDramaStepKeys);
  });

  test('state roundtrip keeps shot artifacts and cost', () {
    final state = DramaEpisodeState.empty('s', 'e')
        .withShot(
          's01',
          DramaShotState(
            clip: const DramaArtifact(
              status: DramaStatus.succeeded,
              path: 'assets/clips/s01/h.mp4',
              sourceHash: 'sha256:clip',
              durationS: 3,
              costYuan: 0.45,
            ),
          ),
        )
        .withActualYuan(0.45);
    final decoded = DramaEpisodeState.fromJson(state.toJson());
    expect(decoded.shots['s01']!.clip.path, 'assets/clips/s01/h.mp4');
    expect(decoded.shots['s01']!.clip.durationS, 3);
    expect(decoded.actualYuan, 0.45);
  });

  test('withActiveRun(null) clears the active run', () {
    final state = DramaEpisodeState.empty('s', 'e').withActiveRun('run-1');
    expect(state.withActiveRun(null).activeRunId, isNull);
  });
}
