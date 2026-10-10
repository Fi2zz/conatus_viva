import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/llm.dart';
import 'package:flutter_wanxiang/pipeline/steps/classify.dart';
import 'package:flutter_wanxiang/pipeline/steps/ingest.dart';
import 'package:flutter_wanxiang/pipeline/steps/select.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('conatus_classify_test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  /// An ingest result backed by a real file on disk (sha1 reads its bytes).
  IngestedPhoto photo(String id, List<int> bytes, {DateTime? capturedAt}) {
    final file = File('${tmp.path}/$id.jpg')..writeAsBytesSync(bytes);
    return IngestedPhoto(
      id: id,
      file: file,
      capturedAt: capturedAt,
      source: IngestedPhoto.sourceLocal,
    );
  }

  PhotoInfo info(
    String id, {
    int quality = 3,
    bool hasPerson = false,
    bool personUnknown = false,
  }) => PhotoInfo(
    id: id,
    hasPerson: hasPerson,
    quality: quality,
    motionHint: '',
    caption: '',
    personUnknown: personUnknown,
  );

  /// A well-formed `chat/completions` reply carrying [content].
  http.Response chatOk(String content) => http.Response(
    jsonEncode(<String, dynamic>{
      'choices': <dynamic>[
        <String, dynamic>{
          'message': <String, dynamic>{'role': 'assistant', 'content': content},
        },
      ],
    }),
    200,
    headers: <String, String>{'content-type': 'application/json'},
  );

  QwenClient makeClient(http.Client transport) => QwenClient(
    apiKey: 'test-key',
    baseUrl: 'https://example.test/v1',
    client: transport,
  );

  test('classify parses fields and folds unknown into person route', () async {
    var calls = 0;
    http.Request? firstRequest;
    final llm = makeClient(
      MockClient((request) async {
        calls++;
        firstRequest ??= request;
        if (calls == 1) {
          return chatOk(
            '{"has_person":false,"quality":4,'
            '"motion_hint":"镜头缓慢左移","caption":"海边落日下的剪影"}',
          );
        }
        // 第二张照片：每次请求都撞限流 → chatJson 重试 1 次后仍抛错。
        return http.Response(
          '{"error":{"message":"rate limited"}}',
          429,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }),
    );
    llm.sleep = (_) async {}; // 测试里不等真实退避

    final infos = await runClassify(
      photos: <IngestedPhoto>[
        photo('001_a', const <int>[0xFF, 0xD8, 0x01]),
        photo('002_b', const <int>[0xFF, 0xD8, 0x02]),
      ],
      llm: llm,
    );

    // 正常回答：字段按固定 JSON 形状解析。
    expect(infos, hasLength(2));
    final ok = infos[0];
    expect(ok.id, '001_a');
    expect(ok.hasPerson, isFalse);
    expect(ok.personUnknown, isFalse);
    expect(ok.quality, 4);
    expect(ok.motionHint, '镜头缓慢左移');
    expect(ok.caption, '海边落日下的剪影');

    // 抛错 2 次（初始 + 重试）→ 保守降级：按人物处理。
    final degraded = infos[1];
    expect(degraded.id, '002_b');
    expect(degraded.hasPerson, isTrue, reason: 'unknown 折叠进人物路线');
    expect(degraded.personUnknown, isTrue);
    expect(calls, 3, reason: '成功 1 次 + 失败照片 2 次请求（1 次重试）');

    // system prompt 固定要求的四个字段。
    final body = jsonDecode(firstRequest!.body) as Map<String, dynamic>;
    final system =
        (body['messages'] as List<dynamic>).first as Map<String, dynamic>;
    final prompt = system['content'] as String;
    expect(prompt, contains('has_person'));
    expect(prompt, contains('quality'));
    expect(prompt, contains('motion_hint'));
    expect(prompt, contains('caption'));
  });

  test('select dedupes identical content and takes top N by quality', () {
    final shared = <int>[0x0A, 0x0B, 0x0C];
    final order = <IngestedPhoto>[
      photo('001_p1', shared),
      photo('002_p2', const <int>[0x01]),
      photo('003_p3', const <int>[0x02]),
      photo('004_p4', const <int>[0x03]),
      photo('005_p5', shared), // 与 001_p1 内容相同（sha1 相同）
    ];
    final all = <PhotoInfo>[
      info('001_p1', quality: 5),
      info('002_p2', quality: 3),
      info('003_p3', quality: 4),
      info('004_p4', quality: 2),
      info('005_p5', quality: 5),
    ];

    final selected = selectPhotos(all: all, order: order, count: 4);

    expect(selected, hasLength(4));
    expect(
      selected.map((p) => p.id).toList(),
      <String>['001_p1', '003_p3', '002_p2', '004_p4'],
      reason: '内容重复的 005_p5 被剔除，其余按 quality 降序取前 4',
    );
    expect(selected.map((p) => p.id), isNot(contains('005_p5')));
  });

  test('userPicked bypasses ranking', () {
    final all = <PhotoInfo>[
      info('001_low', quality: 1),
      info('002_high', quality: 5),
      info('003_mid', quality: 3),
    ];
    final order = <IngestedPhoto>[
      photo('001_low', const <int>[0x01]),
      photo('002_high', const <int>[0x02]),
      photo('003_mid', const <int>[0x03]),
    ];

    // count=2 也不裁剪：手选透传顺序与数量都原样保留。
    final selected = selectPhotos(
      all: all,
      order: order,
      count: 2,
      userPicked: true,
    );

    expect(selected, hasLength(3));
    expect(selected.map((p) => p.id).toList(), <String>[
      '001_low',
      '002_high',
      '003_mid',
    ], reason: '手选顺序原样透传，不排序不裁剪');
  });

  test('fewer photos than count uses what exists', () {
    final order = <IngestedPhoto>[
      photo('001_a', const <int>[0x01]),
      photo('002_b', const <int>[0x02]),
    ];
    final all = <PhotoInfo>[
      info('001_a', quality: 5),
      info('002_b', quality: 2),
    ];

    final selected = selectPhotos(all: all, order: order, count: 4);

    expect(selected, hasLength(2));
    expect(selected.map((p) => p.id).toList(), <String>[
      '001_a',
      '002_b',
    ], reason: '不足 N 有几张用几张，按质量降序');
  });

  test('capturedAt spreads picks across the timeline', () {
    final start = DateTime.utc(2026, 9, 1);
    final qualities = <int>[5, 5, 4, 3, 2, 1];
    final order = <IngestedPhoto>[];
    final all = <PhotoInfo>[];
    for (var i = 0; i < qualities.length; i++) {
      final id = '${'${i + 1}'.padLeft(3, '0')}_d${i + 1}';
      order.add(photo(id, <int>[i], capturedAt: start.add(Duration(days: i))));
      all.add(info(id, quality: qualities[i]));
    }

    final selected = selectPhotos(all: all, order: order, count: 3);

    expect(
      selected.map((p) => p.id).toList(),
      <String>['001_d1', '003_d3', '005_d5'],
      reason: '时间三分取各段最高分：首、中、尾各一张；纯质量取前 3 会全部落在前半段',
    );
  });
}
