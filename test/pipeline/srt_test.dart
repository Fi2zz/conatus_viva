import 'dart:convert';

import 'package:flutter_wanxiang/pipeline/srt.dart';
import 'package:test/test.dart';

void main() {
  group('stripControlTags', () {
    test('stripControlTags removes [very slowly] keeps sentence', () {
      expect(stripControlTags('[very slowly]今天天气很好'), '今天天气很好');
      expect(stripControlTags('我们[pause]一起走吧'), '我们一起走吧');
      expect(stripControlTags('没有标签的句子'), '没有标签的句子');
    });
  });

  group('buildSrt', () {
    test('entry end uses audio length capped by video length', () {
      final shortAudio = buildSrt(
        segs: [
          SegmentInput(
            line: '台词',
            startVideoS: 5.0,
            videoDurationS: 5.0,
            audioS: 4.6,
          ),
        ],
      );
      expect(shortAudio.single.start, const Duration(seconds: 5));
      expect(shortAudio.single.end, const Duration(milliseconds: 9600));

      final longAudio = buildSrt(
        segs: [
          SegmentInput(
            line: '台词',
            startVideoS: 5.0,
            videoDurationS: 5.0,
            audioS: 5.4,
          ),
        ],
      );
      expect(longAudio.single.end, const Duration(seconds: 10));
    });

    test('long line splits into two entries proportional to chars', () {
      final line = ('一' * 24) + ('二' * 24); // 48 chars > 40
      final entries = buildSrt(
        segs: [
          SegmentInput(
            line: line,
            startVideoS: 0,
            videoDurationS: 8,
            audioS: 8,
          ),
        ],
      );
      expect(entries, hasLength(2));
      expect(entries[0].index, 1);
      expect(entries[1].index, 2);
      expect(entries[0].text, '一' * 24);
      expect(entries[1].text, '二' * 24);
      expect(entries[0].start, Duration.zero);
      // 时长比 ≈ 字数比（24/24 → 一半）
      expect(entries[0].end, const Duration(seconds: 4));
      // 每条 end ≤ 下一条 start
      expect(entries[1].start, entries[0].end);
      expect(entries[1].end, const Duration(seconds: 8));
    });

    test('overlapping entries are rejected', () {
      expect(
        () => buildSrt(
          segs: [
            SegmentInput(
              line: '第一句',
              startVideoS: 0,
              videoDurationS: 5,
              audioS: 5,
            ),
            SegmentInput(
              line: '第二句',
              startVideoS: 4,
              videoDurationS: 5,
              audioS: 5,
            ),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('renderSrt', () {
    test('render output has no BOM and LF endings', () {
      final srt = renderSrt([
        SrtEntry(
          index: 1,
          start: Duration.zero,
          end: const Duration(milliseconds: 4600),
          text: '今天天气很好',
        ),
        SrtEntry(
          index: 2,
          start: const Duration(seconds: 5),
          end: const Duration(seconds: 10),
          text: '我们一起出去走走',
        ),
      ]);
      final bytes = utf8.encode(srt);
      expect(bytes.length, greaterThan(3));
      expect(bytes.sublist(0, 3), isNot(orderedEquals([0xEF, 0xBB, 0xBF])));
      expect(srt.contains('\r'), isFalse);
      expect(srt.endsWith('\n'), isTrue);
      expect(srt.endsWith('\n\n'), isFalse);
      expect(srt, contains('1\n00:00:00,000 --> 00:00:04,600\n今天天气很好'));
      expect(srt, contains('2\n00:00:05,000 --> 00:00:10,000\n我们一起出去走走'));
    });
  });
}
