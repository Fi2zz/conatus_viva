import 'dart:io';

import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/state.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('conatus_state_test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('step status transitions and atomic save/load roundtrip', () {
    final state = ContentState.load(dir.path);

    // fresh state: every step pending, zero attempts, empty timeline
    expect(state.step('classify').status, StepStatus.pending);
    expect(state.step('classify').attempts, 0);
    expect(state.step('classify').t, isEmpty);

    // pending → running → succeeded
    state.step('classify').status = StepStatus.running;
    state.step('classify').attempts = 1;
    state.step('classify').t.add('start');
    state.step('classify').status = StepStatus.succeeded;
    state.step('classify').t.add('end');

    // a failed step keeps its error for the rerun decision table
    state.step('render').status = StepStatus.failed;
    state.step('render').attempts = 2;
    state.step('render').error = const PipelineError(
      ErrorClass.transient,
      'rate limited',
      remoteCode: '429',
    );

    // cost math: estimatedYuan = i2vSecondsTotal * 0.15
    state.cost.recordI2vSeconds(15);
    expect(state.cost.estimatedYuan, closeTo(2.25, 1e-9));

    state.contentId = 'demo-202610';
    state.params['dialect'] = 'henan';
    state.save();

    // atomic publish: state.json exists, the temp file is gone
    expect(File('${dir.path}/state.json').existsSync(), isTrue);
    expect(File('${dir.path}/state.json.tmp').existsSync(), isFalse);

    final reloaded = ContentState.load(dir.path);
    expect(reloaded.contentId, 'demo-202610');
    expect(reloaded.params['dialect'], 'henan');
    expect(reloaded.step('classify').status, StepStatus.succeeded);
    expect(reloaded.step('classify').attempts, 1);
    expect(reloaded.step('classify').t, ['start', 'end']);
    expect(reloaded.step('compose').status, StepStatus.pending);
    expect(reloaded.step('render').status, StepStatus.failed);
    expect(reloaded.step('render').error?.cls, ErrorClass.transient);
    expect(reloaded.step('render').error?.remoteCode, '429');
    expect(reloaded.cost.i2vSecondsTotal, 15);
    expect(reloaded.cost.estimatedYuan, closeTo(2.25, 1e-9));
  });

  test('audit reject marks segment degraded with zero cost', () {
    final state = ContentState.load(dir.path);
    final seg = SegmentState(i: 0, route: 'i2v', audioS: 4.6, durationS: 5);
    state.segments.add(seg);

    seg.markSubmitted('task-abc', now: DateTime(2026, 10, 10, 12));
    expect(seg.status, SegmentStatus.submitted);
    expect(seg.costSeconds, 5); // i2v 提交即按段时长计费

    seg.markDegraded('DataInspectionFailed');

    expect(seg.status, SegmentStatus.degraded);
    expect(seg.route, 'kenburns');
    expect(seg.costSeconds, 0);
    expect(seg.error?.cls, ErrorClass.auditReject);

    state.save();
    final reloaded = ContentState.load(dir.path);
    final persisted = reloaded.segments.single;
    expect(persisted.status, SegmentStatus.degraded);
    expect(persisted.route, 'kenburns');
    expect(persisted.costSeconds, 0);
  });

  test('resumableTask returns id within 24h and null after', () {
    final now = DateTime(2026, 10, 10, 12);
    final seg = SegmentState(i: 0, route: 'i2v', audioS: 4.6, durationS: 5);

    // never submitted → no task to resume
    expect(seg.resumableTask(now: now), isNull);

    // submitted 23h59m ago → resume polling, never resubmit
    seg.markSubmitted(
      'task-abc',
      now: now.subtract(const Duration(minutes: 1439)),
    );
    expect(seg.resumableTask(now: now), 'task-abc');

    // submitted 24h01m ago → task id expired, treat as absent
    seg.markSubmitted(
      'task-abc',
      now: now.subtract(const Duration(hours: 24, minutes: 1)),
    );
    expect(seg.resumableTask(now: now), isNull);
  });

  test('corrupt state.json throws PipelineError fatal', () {
    File('${dir.path}/state.json').writeAsStringSync('{"steps": [not json');

    expect(
      () => ContentState.load(dir.path),
      throwsA(
        isA<PipelineError>()
            .having((e) => e.cls, 'cls', ErrorClass.fatal)
            .having((e) => e.message, 'message', isNotEmpty),
      ),
    );

    // valid JSON with the wrong shape is corrupt too
    File('${dir.path}/state.json').writeAsStringSync('"just a string"');

    expect(
      () => ContentState.load(dir.path),
      throwsA(
        isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal),
      ),
    );
  });
}
