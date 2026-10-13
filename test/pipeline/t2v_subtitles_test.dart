import 'package:flutter_wanxiang/pipeline/srt.dart';
import 'package:flutter_wanxiang/pipeline/t2v_subtitles.dart';
import 'package:test/test.dart';

void main() {
  test('single line spans the whole duration', () {
    final entries = buildSubtitleEntries(
      text: '你好世界',
      duration: const Duration(seconds: 6),
    );

    expect(entries.length, 1);
    expect(entries.single.start, Duration.zero);
    expect(entries.single.end, const Duration(seconds: 6));
    expect(entries.single.text, '你好世界');
  });

  test('multiple lines split evenly and the last reaches the duration', () {
    final entries = buildSubtitleEntries(
      text: '一\n二\n三\n四',
      duration: const Duration(seconds: 8),
    );

    expect(entries.map((e) => e.start).toList(), <Duration>[
      Duration.zero,
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 6),
    ]);
    expect(entries.last.end, const Duration(seconds: 8));
  });

  test('blank lines are ignored', () {
    final entries = buildSubtitleEntries(
      text: '一\n\n   \n二',
      duration: const Duration(seconds: 4),
    );

    expect(entries.length, 2);
    expect(entries[0].text, '一');
    expect(entries[1].text, '二');
  });

  test('empty text yields no cues', () {
    expect(
      buildSubtitleEntries(text: '  \n ', duration: const Duration(seconds: 4)),
      isEmpty,
    );
  });

  test('renders well-formed SRT', () {
    final srt = renderSrt(
      buildSubtitleEntries(text: '一\n二', duration: const Duration(seconds: 6)),
    );

    expect(
      srt,
      '1\n00:00:00,000 --> 00:00:03,000\n一\n\n'
      '2\n00:00:03,000 --> 00:00:06,000\n二\n',
    );
  });
}
