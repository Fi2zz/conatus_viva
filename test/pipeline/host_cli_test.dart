import 'package:flutter_wanxiang/pipeline/host.dart' as host;
import 'package:test/test.dart';

import '../../bin/conatus_host.dart' as cli;

void main() {
  test('--video-model passes the chosen model through', () {
    final parser = cli.buildParser();
    final results = parser.parse(<String>[
      '--photos',
      'a.jpg',
      '--dialect',
      '河南',
      '--video-model',
      'wan3.0-video',
    ]);

    final args = cli.parseArgs(results, parser);

    expect(args, isNotNull);
    expect(args!.videoModel, 'wan3.0-video');
  });

  test('omitting --video-model leaves the config default in play', () {
    final parser = cli.buildParser();
    final results = parser.parse(<String>[
      '--photos',
      'a.jpg',
      '--dialect',
      '河南',
    ]);

    final args = cli.parseArgs(results, parser);

    expect(args!.videoModel, isNull);
  });

  test('--text-to-video switches mode without photos or dialect', () {
    final parser = cli.buildParser();
    final results = parser.parse(<String>[
      '--text-to-video',
      '一只猫在草地上奔跑',
      '--video-model',
      'wan3.0-video',
      '--video-duration',
      '8',
      '--video-out',
      'out/v.mp4',
    ]);

    final args = cli.parseArgs(results, parser);

    expect(args, isNotNull);
    expect(args!.textToVideo, '一只猫在草地上奔跑');
    expect(args.videoModel, 'wan3.0-video');
    expect(args.videoDuration, 8);
    expect(args.videoOut, 'out/v.mp4');
    expect(args.videoAudio, isNull); // unset → config default
  });

  test('--no-video-audio is honoured in text-to-video mode', () {
    final parser = cli.buildParser();
    final results = parser.parse(<String>[
      '--text-to-video', 'x', '--no-video-audio',
    ]);

    expect(cli.parseArgs(results, parser)!.videoAudio, isFalse);
  });

  test('album mode still requires photos and dialect', () {
    final parser = cli.buildParser();
    final results = parser.parse(<String>['--count', '4']);
    expect(cli.parseArgs(results, parser), isNull);
  });

  test('text-to-video rejects a non-wan3 video model', () {
    final parser = cli.buildParser();
    final results = parser.parse(<String>[
      '--text-to-video', 'x', '--video-model', 'wan2.6-i2v-flash',
    ]);
    expect(cli.parseArgs(results, parser), isNull);
  });

  test('text-to-video rejects an out-of-range duration', () {
    for (final duration in <String>['1', '31', 'abc']) {
      final parser = cli.buildParser();
      final results = parser.parse(<String>[
        '--text-to-video', 'x', '--video-duration', duration,
      ]);
      expect(cli.parseArgs(results, parser), isNull, reason: duration);
    }
  });

  test('t2vModelProblem flags non-wan3 models only', () {
    expect(host.t2vModelProblem('wan3.0-video'), isNull);
    expect(host.t2vModelProblem('wan3.0-video-prime'), isNull);
    expect(host.t2vModelProblem('wan2.6-i2v-flash'), isNotNull);
  });

  test('t2vPrompt appends the dialect instruction when given', () {
    expect(host.t2vPrompt('一只猫', null), '一只猫');
    expect(host.t2vPrompt('一只猫', ''), '一只猫');
    expect(host.t2vPrompt('一只猫', '河南'), '一只猫\n请用河南话表达。');
    expect(host.t2vPrompt('一只猫', '不存在的地区'), '一只猫\n请用普通话表达。');
  });

  test('--subtitle-text parses in text-to-video mode', () {
    final parser = cli.buildParser();
    final results = parser.parse(<String>[
      '--text-to-video', 'x', '--subtitle-text', '第一行\n第二行',
    ]);

    final args = cli.parseArgs(results, parser);

    expect(args!.subtitleText, '第一行\n第二行');
    expect(args.subtitleFile, isNull);
  });

  test('--subtitle-file parses in text-to-video mode', () {
    final parser = cli.buildParser();
    final results = parser.parse(<String>[
      '--text-to-video', 'x', '--subtitle-file', 'subs.srt',
    ]);

    final args = cli.parseArgs(results, parser);

    expect(args!.subtitleFile, 'subs.srt');
    expect(args.subtitleText, isNull);
  });

  test('--subtitle-text and --subtitle-file are mutually exclusive', () {
    final parser = cli.buildParser();
    final results = parser.parse(<String>[
      '--text-to-video', 'x', '--subtitle-text', 'a', '--subtitle-file', 'b.srt',
    ]);

    expect(cli.parseArgs(results, parser), isNull);
  });

  test('--dialect is carried through in text-to-video mode', () {
    final parser = cli.buildParser();
    final results = parser.parse(<String>[
      '--text-to-video', 'x', '--dialect', '河南',
    ]);

    expect(cli.parseArgs(results, parser)!.dialect, '河南');
  });
}
