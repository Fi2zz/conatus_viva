import 'dart:io';

import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/frame.dart';
import 'package:flutter_wanxiang/pipeline/storyboard.dart';
import 'package:test/test.dart';

/// 断言 fn 抛出 `PipelineError(ErrorClass.fatal)`。
void expectFatal(void Function() fn) {
  expect(
    fn,
    throwsA(isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.fatal)),
  );
}

Map<String, Object?> minimalJson() => <String, Object?>{
  'content_id': 'ep01',
  'shots': <Object?>[
    <String, Object?>{'id': 's01', 'kind': 'speak_off'},
  ],
};

void main() {
  group('FrameSize', () {
    test('parses "x" and "*" separators', () {
      final x = FrameSize.tryParse('1080x1920')!;
      expect([x.width, x.height], [1080, 1920]);
      final star = FrameSize.tryParse('720*1280')!;
      expect([star.width, star.height], [720, 1280]);
    });

    test('rejects malformed or non-positive sizes', () {
      for (final raw in <String>[
        '',
        '1080',
        'x1920',
        '1080x',
        '1080X1920',
        '0x1920',
        '1080x0',
        '-1080x1920',
        '1080x-1920',
        '1080x1920x2',
        'abxcd',
        '1080.5x1920',
      ]) {
        expect(FrameSize.tryParse(raw), isNull, reason: raw);
      }
    });

    test('reports orientation, label and json shape', () {
      expect(FrameSize.vertical.isVertical, isTrue);
      expect(const FrameSize(1920, 1080).isVertical, isFalse);
      expect(FrameSize.vertical.label, '1080x1920');
      expect(FrameSize.vertical.toJson(), {'width': 1080, 'height': 1920});
    });
  });

  group('wire mapping', () {
    test('kind roundtrips through snake_case', () {
      for (final kind in ShotKind.values) {
        expect(shotKindFromWire(shotKindToWire(kind)), kind);
      }
      expect(shotKindToWire(ShotKind.speakOff), 'speak_off');
      expect(shotKindToWire(ShotKind.listenFace), 'listen_face');
      expect(shotKindFromWire('nope'), isNull);
    });

    test('priority roundtrips through snake_case', () {
      for (final priority in ShotPriority.values) {
        expect(shotPriorityFromWire(shotPriorityToWire(priority)), priority);
      }
      expect(shotPriorityToWire(ShotPriority.normal), 'normal');
      expect(shotPriorityFromWire('urgent'), isNull);
    });
  });

  group('Storyboard defaults', () {
    test('minimal input fills every optional field', () {
      final board = Storyboard.fromJson(minimalJson());
      expect(board.contentId, 'ep01');
      expect(board.title, 'ep01');
      expect(board.dialect, isNull);
      expect(board.frame.label, '1080x1920');
      expect(board.budgetYuan, 120.0);
      expect(board.cast, isEmpty);
      expect(board.warnings, isEmpty);

      final shot = board.shots.single;
      expect(shot.id, 's01');
      expect(shot.kind, ShotKind.speakOff);
      expect(shot.priority, ShotPriority.normal);
      expect(shot.line, '');
      expect(shot.framing, 'unknown');
      expect(shot.speaker, isNull);
      expect(shot.durationS, isNull);
      expect(shot.prop, isNull);
      expect(shot.motion, isNull);
    });
  });

  group('Storyboard full input', () {
    test('parses the ep07 fixture field by field', () {
      final source = File(
        'test/fixtures/ep07.storyboard.json',
      ).readAsStringSync();
      final board = Storyboard.fromJsonString(source);

      expect(board.contentId, 'ep07');
      expect(board.title, '堂屋对峙');
      expect(board.dialect, '河南');
      expect(board.frame.label, '1080x1920');
      expect(board.budgetYuan, 20.0);
      expect(board.shots, hasLength(12));
      expect(board.warnings, isEmpty);

      expect(board.cast.keys, ['erniu', 'xiaoman']);
      final erniu = board.cast['erniu']!;
      expect(
        [erniu.id, erniu.name, erniu.voiceId, erniu.dialect],
        ['erniu', '二舅', null, '河南'],
      );
      final xiaoman = board.cast['xiaoman']!;
      expect(
        [xiaoman.name, xiaoman.voiceId, xiaoman.dialect],
        ['小满', null, null],
      );

      final s01 = board.shots.first;
      expect(s01.id, 's01');
      expect(s01.kind, ShotKind.speakOff);
      expect(s01.framing, 'over_shoulder');
      expect(s01.speaker, 'erniu');
      expect(s01.line, '你欠我的，今天该还了。');
      expect(s01.durationS, 3.0);
      expect(s01.priority, ShotPriority.hook);

      final s03 = board.shots[2];
      expect(s03.kind, ShotKind.insert);
      expect(s03.speaker, isNull);
      expect(s03.prop, '借条');
      expect(s03.durationS, 1.6);
      expect(s03.priority, ShotPriority.normal);

      final s08 = board.shots[7];
      expect(s08.kind, ShotKind.action);
      expect(s08.priority, ShotPriority.payoff);
    });

    test('toJson emits the canonical wire shape without warnings', () {
      final board = Storyboard.fromJsonString(
        File('test/fixtures/ep07.storyboard.json').readAsStringSync(),
      );
      final json = board.toJson();

      expect(json['content_id'], 'ep07');
      expect(json['title'], '堂屋对峙');
      expect(json['dialect'], '河南');
      expect(json['frame'], '1080x1920');
      expect(json['budget_yuan'], 20.0);
      expect(json.containsKey('warnings'), isFalse);

      final cast = json['cast']! as Map<String, Object?>;
      expect((cast['erniu']! as Map<String, Object?>)['name'], '二舅');
      expect((cast['erniu']! as Map<String, Object?>)['voice_id'], isNull);
      expect((cast['xiaoman']! as Map<String, Object?>)['dialect'], isNull);

      final s01 =
          (json['shots']! as List<Object?>).first as Map<String, Object?>;
      expect(s01['kind'], 'speak_off');
      expect(s01['priority'], 'hook');
      expect(s01['duration_s'], 3.0);

      final s03 = (json['shots']! as List<Object?>)[2] as Map<String, Object?>;
      expect(s03['kind'], 'insert');
      expect(s03['prop'], '借条');
      expect(s03['priority'], 'normal');
    });

    test('roundtrip is canonical idempotent', () {
      final board = Storyboard.fromJsonString(
        File('test/fixtures/ep07.storyboard.json').readAsStringSync(),
      );
      final once = board.toJson();
      final twice = Storyboard.fromJson(once).toJson();
      expect(twice, once);
    });

    test('roundtrip is canonical for minimal and unknown values', () {
      final board = Storyboard.fromJson(<String, Object?>{
        'content_id': 'ep02',
        'shots': <Object?>[
          <String, Object?>{'id': 's01', 'kind': 'dance', 'priority': 'urgent'},
        ],
      });
      final once = board.toJson();
      expect(Storyboard.fromJson(once).toJson(), once);
      expect(board.shots.single.kind, ShotKind.speakOff);
      expect(board.shots.single.priority, ShotPriority.normal);
    });
  });

  group('Storyboard warnings', () {
    test('unknown kind degrades to speakOff and warns', () {
      final board = Storyboard.fromJson(<String, Object?>{
        'content_id': 'ep01',
        'shots': <Object?>[
          <String, Object?>{'id': 's01', 'kind': 'dance'},
        ],
      });
      expect(board.shots.single.kind, ShotKind.speakOff);
      expect(board.warnings, ['unknown_kind:s01:dance']);
    });

    test('unknown priority degrades to normal and warns', () {
      final board = Storyboard.fromJson(<String, Object?>{
        'content_id': 'ep01',
        'shots': <Object?>[
          <String, Object?>{
            'id': 's01',
            'kind': 'action',
            'priority': 'urgent',
          },
        ],
      });
      expect(board.shots.single.priority, ShotPriority.normal);
      expect(board.warnings, ['unknown_priority:s01:urgent']);
    });

    test('speaker outside cast warns but does not throw', () {
      final board = Storyboard.fromJson(<String, Object?>{
        'content_id': 'ep01',
        'cast': <String, Object?>{
          'erniu': <String, Object?>{'name': '二舅'},
        },
        'shots': <Object?>[
          <String, Object?>{
            'id': 's01',
            'kind': 'speak_off',
            'speaker': 'ghost',
          },
          <String, Object?>{
            'id': 's02',
            'kind': 'speak_off',
            'speaker': 'erniu',
          },
        ],
      });
      expect(board.warnings, ['speaker_not_in_cast:s01:ghost']);
    });

    test('non-vertical frame only warns', () {
      final board = Storyboard.fromJson(<String, Object?>{
        'content_id': 'ep01',
        'frame': '1920x1080',
        'shots': <Object?>[
          <String, Object?>{'id': 's01', 'kind': 'insert'},
        ],
      });
      expect(board.frame.label, '1920x1080');
      expect(board.warnings, ['frame_not_vertical']);
    });

    test('square frame is not vertical', () {
      final board = Storyboard.fromJson(<String, Object?>{
        'content_id': 'ep01',
        'frame': '1080*1080',
        'shots': <Object?>[
          <String, Object?>{'id': 's01', 'kind': 'insert'},
        ],
      });
      expect(board.frame.label, '1080x1080');
      expect(board.warnings, ['frame_not_vertical']);
    });
  });

  group('Storyboard fatal schema errors', () {
    test('invalid content_id', () {
      for (final id in <String>[
        '',
        'ep 07',
        'ep/07',
        '../ep07',
        'ep.07',
        '集07',
      ]) {
        expectFatal(
          () => Storyboard.fromJson(<String, Object?>{
            'content_id': id,
            'shots': <Object?>[
              <String, Object?>{'id': 's01', 'kind': 'insert'},
            ],
          }),
        );
      }
    });

    test('missing or non-string content_id', () {
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'shots': <Object?>[
            <String, Object?>{'id': 's01', 'kind': 'insert'},
          ],
        }),
      );
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'content_id': 7,
          'shots': <Object?>[
            <String, Object?>{'id': 's01', 'kind': 'insert'},
          ],
        }),
      );
    });

    test('empty shots', () {
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'content_id': 'ep01',
          'shots': <Object?>[],
        }),
      );
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{'content_id': 'ep01'}),
      );
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'content_id': 'ep01',
          'shots': 'nope',
        }),
      );
    });

    test('duplicate or empty shot ids', () {
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'content_id': 'ep01',
          'shots': <Object?>[
            <String, Object?>{'id': 's01', 'kind': 'insert'},
            <String, Object?>{'id': 's01', 'kind': 'insert'},
          ],
        }),
      );
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'content_id': 'ep01',
          'shots': <Object?>[
            <String, Object?>{'id': '', 'kind': 'insert'},
          ],
        }),
      );
    });

    test('missing or non-string kind', () {
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'content_id': 'ep01',
          'shots': <Object?>[
            <String, Object?>{'id': 's01'},
          ],
        }),
      );
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'content_id': 'ep01',
          'shots': <Object?>[
            <String, Object?>{'id': 's01', 'kind': 5},
          ],
        }),
      );
    });

    test('budget must be finite and positive', () {
      for (final budget in <num>[0, -1, double.nan, double.infinity]) {
        expectFatal(
          () => Storyboard.fromJson(<String, Object?>{
            'content_id': 'ep01',
            'budget_yuan': budget,
            'shots': <Object?>[
              <String, Object?>{'id': 's01', 'kind': 'insert'},
            ],
          }),
        );
      }
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'content_id': 'ep01',
          'budget_yuan': '20',
          'shots': <Object?>[
            <String, Object?>{'id': 's01', 'kind': 'insert'},
          ],
        }),
      );
    });

    test('duration must be finite and positive', () {
      for (final duration in <num>[0, -1, double.nan, double.infinity]) {
        expectFatal(
          () => Storyboard.fromJson(<String, Object?>{
            'content_id': 'ep01',
            'shots': <Object?>[
              <String, Object?>{
                'id': 's01',
                'kind': 'insert',
                'duration_s': duration,
              },
            ],
          }),
        );
      }
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'content_id': 'ep01',
          'shots': <Object?>[
            <String, Object?>{'id': 's01', 'kind': 'insert', 'duration_s': '3'},
          ],
        }),
      );
    });

    test('invalid frame is fatal', () {
      for (final frame in <Object>['', '1080', '0x1920', 'wide']) {
        expectFatal(
          () => Storyboard.fromJson(<String, Object?>{
            'content_id': 'ep01',
            'frame': frame,
            'shots': <Object?>[
              <String, Object?>{'id': 's01', 'kind': 'insert'},
            ],
          }),
        );
      }
    });

    test('non-object shot entries are fatal', () {
      expectFatal(
        () => Storyboard.fromJson(<String, Object?>{
          'content_id': 'ep01',
          'shots': <Object?>['s01'],
        }),
      );
    });
  });

  group('fromJsonString', () {
    test('wraps JSON syntax failures as fatal PipelineError', () {
      expectFatal(() => Storyboard.fromJsonString('{"content_id":'));
      expectFatal(() => Storyboard.fromJsonString('[]'));
      expectFatal(() => Storyboard.fromJsonString('null'));
    });

    test('wraps schema type failures as fatal PipelineError', () {
      expectFatal(
        () => Storyboard.fromJsonString(
          '{"content_id":"ep01","shots":[{"id":"s01","kind":"insert","line":5}]}',
        ),
      );
    });
  });
}
