import 'dart:io';

import 'package:flutter_wanxiang/pipeline/artifacts.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_artifacts_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('workdir paths follow spec layout', () {
    // nested base that does not exist yet: the constructor creates it
    final base = '${tmp.path}/nested/pipeline_out';
    final work = Workdir(base, 'demo-202610');

    // dir == base/content_id, created recursively on construction
    expect(work.dir, '$base/demo-202610');
    expect(Directory(work.dir).existsSync(), isTrue);

    // spec §4 artifact layout constants
    expect(ArtifactPaths.state, 'state.json');
    expect(ArtifactPaths.meta, 'meta.json');
    expect(ArtifactPaths.inputsDir, '00_inputs');
    expect(ArtifactPaths.classify, '01_classify.json');
    expect(ArtifactPaths.select, '02_select.json');
    expect(ArtifactPaths.script, '03_script.json');
    expect(ArtifactPaths.audioDir, '04_audio');
    expect(ArtifactPaths.durations, '04_audio/durations.json');
    expect(ArtifactPaths.clipsDir, '05_clips');
    expect(ArtifactPaths.renderStatus, '05_clips/status.json');
    expect(ArtifactPaths.finalVideo, '06_final.mp4');
    expect(ArtifactPaths.finalSrt, '06_final.srt');

    // file/dir resolve under the workdir root
    expect(
      work.file(ArtifactPaths.finalVideo).path,
      '${work.dir}/06_final.mp4',
    );
    expect(work.dirOf(ArtifactPaths.audioDir).path, '${work.dir}/04_audio');

    // exists: false before anything is written, true after
    expect(work.exists(ArtifactPaths.state), isFalse);
    File('${work.dir}/${ArtifactPaths.state}').writeAsStringSync('{}');
    expect(work.exists(ArtifactPaths.state), isTrue);
    Directory('${work.dir}/${ArtifactPaths.inputsDir}').createSync();
    expect(work.exists(ArtifactPaths.inputsDir), isTrue);
  });

  test('stepDone false for missing and empty file, true for content', () {
    final work = Workdir(tmp.path, 'demo-202610');

    // missing artifact → step not done (fresh run)
    expect(stepDone(work, ArtifactPaths.classify), isFalse);

    // empty file → step not done (interrupted write, must rerun)
    File(work.file(ArtifactPaths.classify).path).writeAsStringSync('');
    expect(stepDone(work, ArtifactPaths.classify), isFalse);

    // non-empty file → step done (skip)
    File(
      work.file(ArtifactPaths.classify).path,
    ).writeAsStringSync('{"scores":[]}');
    expect(stepDone(work, ArtifactPaths.classify), isTrue);

    // a directory at the artifact path never counts as done
    Directory(work.file(ArtifactPaths.inputsDir).path).createSync();
    expect(stepDone(work, ArtifactPaths.inputsDir), isFalse);
  });
}
