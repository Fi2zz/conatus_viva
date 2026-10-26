import 'package:flutter_wanxiang/pipeline/drama/hashes.dart';
import 'package:flutter_wanxiang/pipeline/drama/series.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:test/test.dart';

const _shot = Shot(
  id: 's01',
  kind: ShotKind.action,
  framing: '中景',
  speaker: 'erniu',
  line: '',
  durationS: 3,
  priority: ShotPriority.hook,
  motion: '缓慢推近',
  visual: '借条特写',
);

const _member = DramaCastMember(
  castId: 'erniu',
  name: '二舅',
  description: '五十岁，短寸，旧夹克',
);

void main() {
  test('cast hash is stable and changes with description/model', () {
    final base = dramaCastHash(member: _member, model: 'wan2.7-image', size: '1K');
    expect(
      base,
      dramaCastHash(member: _member, model: 'wan2.7-image', size: '1K'),
    );
    expect(
      base,
      isNot(dramaCastHash(
        member: _member.copyWith(description: '换了衣服'),
        model: 'wan2.7-image',
        size: '1K',
      )),
    );
    expect(
      base,
      isNot(dramaCastHash(member: _member, model: 'wan2.7-image-pro', size: '1K')),
    );
  });

  test('frame hash changes with visual or cast avatar', () {
    final base = dramaFrameHash(
      shot: _shot,
      castAvatarHash: 'sha256:a',
      model: 'wan2.7-image',
      size: '1K',
    );
    final newVisual = Shot(
      id: _shot.id,
      kind: _shot.kind,
      framing: _shot.framing,
      speaker: _shot.speaker,
      line: _shot.line,
      durationS: _shot.durationS,
      priority: _shot.priority,
      motion: _shot.motion,
      visual: '换一张画面',
    );
    expect(
      base,
      isNot(dramaFrameHash(
        shot: newVisual,
        castAvatarHash: 'sha256:a',
        model: 'wan2.7-image',
        size: '1K',
      )),
    );
    expect(
      base,
      isNot(dramaFrameHash(
        shot: _shot,
        castAvatarHash: 'sha256:b',
        model: 'wan2.7-image',
        size: '1K',
      )),
    );
  });

  test('clip hash changes with frame, motion and i2v seconds', () {
    final base = dramaClipHash(
      shot: _shot,
      frameHash: 'sha256:frame-a',
      route: 'i2v',
      model: 'wan2.6-i2v-flash',
      resolution: '720P',
      i2vSeconds: 3,
    );
    expect(
      base,
      isNot(dramaClipHash(
        shot: _shot,
        frameHash: 'sha256:frame-b',
        route: 'i2v',
        model: 'wan2.6-i2v-flash',
        resolution: '720P',
        i2vSeconds: 3,
      )),
    );
    expect(
      base,
      isNot(dramaClipHash(
        shot: _shot,
        frameHash: 'sha256:frame-a',
        route: 'i2v',
        model: 'wan2.6-i2v-flash',
        resolution: '720P',
        i2vSeconds: 4,
      )),
    );
  });
}
