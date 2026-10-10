import 'dart:convert';

import 'package:flutter_wanxiang/pipeline/bailian/llm.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/steps/classify.dart';
import 'package:flutter_wanxiang/pipeline/steps/script.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  PhotoInfo info(
    String id, {
    bool hasPerson = false,
    bool personUnknown = false,
    String motionHint = '',
    String caption = '',
  }) => PhotoInfo(
    id: id,
    hasPerson: hasPerson,
    quality: 4,
    motionHint: motionHint,
    caption: caption,
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

  /// The 03 script reply envelope: `{"segments":[{"photo":…,"line":…}]}`.
  String scriptReply(List<Map<String, dynamic>> segments) =>
      jsonEncode(<String, dynamic>{'segments': segments});

  QwenClient makeClient(http.Client transport) => QwenClient(
    apiKey: 'test-key',
    baseUrl: 'https://example.test/v1',
    client: transport,
  );

  final photos = <PhotoInfo>[
    info('001_a', caption: '清晨的院子'),
    info('002_b', hasPerson: true, caption: '草地上奔跑的孩子'),
    info('003_c', motionHint: '镜头缓慢左移', caption: '湖边远山'),
    info('004_d', caption: '傍晚的厨房'),
  ];

  final goodSegments = <Map<String, dynamic>>[
    {'photo': '001_a', 'line': '清晨的阳光洒在院墙上，树影在风里轻轻晃动'},
    {'photo': '002_b', 'line': '孩子在草地上追着皮球跑，笑声落进春天里'},
    {'photo': '003_c', 'line': '湖面倒映着远处的青山，风把涟漪推向岸边'},
    {'photo': '004_d', 'line': '傍晚的厨房亮起暖灯，饭菜的热气慢慢升起'},
  ];

  test('script produces one line per photo with total 60-80 chars', () async {
    http.Request? captured;
    final llm = makeClient(
      MockClient((request) async {
        captured ??= request;
        return chatOk(scriptReply(goodSegments));
      }),
    );
    llm.sleep = (_) async {};

    final script = await runScript(selected: photos, llm: llm);

    expect(script.segments, hasLength(4));
    expect(
      script.segments.map((s) => s.photoId).toList(),
      photos.map((p) => p.id).toList(),
      reason: '段顺序与入选照片顺序一致',
    );
    expect(
      script.totalChars,
      inInclusiveRange(60, 80),
      reason: '全片口播合计 60–80 字',
    );

    // system prompt contract: 每段一句、标准书面语、合计 60–80 字、
    // segments 为 JSON 数组。
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    final system = (body['messages'] as List<dynamic>).first;
    final prompt = (system as Map<String, dynamic>)['content'] as String;
    expect(prompt, contains('一句'));
    expect(prompt, contains('书面'));
    expect(prompt, contains('60–80'));
    expect(prompt, contains('JSON 数组'));
  });

  test('person photo gets null motionPrompt, scenery gets template with '
      'static-subject constraint', () async {
    final llm = makeClient(
      MockClient((request) async {
        return chatOk(
          scriptReply(<Map<String, dynamic>>[
            {'photo': '001_p', 'line': '院子里的合影定格了这一刻'},
            {'photo': '002_u', 'line': '灯下的人影安静地停在画面里'},
            {
              'photo': '003_s',
              'line': '海边的落日把天空染成橙色',
              // 模型自写的动效提示会被忽略：模板由代码合成。
              'motion_prompt': '随便写写',
            },
          ]),
        );
      }),
    );
    llm.sleep = (_) async {};

    final script = await runScript(
      selected: <PhotoInfo>[
        info('001_p', hasPerson: true, caption: '合影'),
        info('002_u', hasPerson: true, personUnknown: true, caption: '夜景'),
        info('003_s', motionHint: '镜头缓慢左移', caption: '海边落日'),
      ],
      llm: llm,
    );

    expect(script.segments, hasLength(3));
    expect(script.segments[0].motionPrompt, isNull, reason: '人物段无动效');
    expect(
      script.segments[1].motionPrompt,
      isNull,
      reason: '人物未识别的照片同样按人物路线处理',
    );
    final motion = script.segments[2].motionPrompt!;
    expect(motion, contains('主体保持静止'));
    expect(
      motion,
      contains('主体保持静止，仅背景与光影微动'),
      reason: '硬约束句与 spec §4-03 原文逐字一致',
    );
    expect(motion, contains('镜头缓慢左移'), reason: 'motion_hint 并入模板');
    expect(motion, isNot('随便写写'), reason: '动效由代码合成而非模型输出');
  });

  test('lines contain no control tags', () async {
    final llm = makeClient(
      MockClient((request) async {
        return chatOk(
          scriptReply(<Map<String, dynamic>>[
            {'photo': '001_a', 'line': '[very slowly] 清晨的阳光洒进院子'},
            {'photo': '002_b', 'line': '孩子在草地上奔跑 [smiling]'},
          ]),
        );
      }),
    );
    llm.sleep = (_) async {};

    final script = await runScript(
      selected: <PhotoInfo>[
        info('001_a', caption: '院子'),
        info('002_b', hasPerson: true, caption: '草地'),
      ],
      llm: llm,
    );

    expect(script.segments, hasLength(2));
    for (final segment in script.segments) {
      expect(
        RegExp(r'\[[^\]]*\]').hasMatch(segment.line),
        isFalse,
        reason: '口播文本不含控制标签: ${segment.line}',
      );
    }
    expect(script.segments[0].line, '清晨的阳光洒进院子');
    expect(script.segments[1].line, '孩子在草地上奔跑');
  });

  test('segment count mismatch retried once and recovers', () async {
    var calls = 0;
    final llm = makeClient(
      MockClient((request) async {
        calls++;
        if (calls == 1) {
          return chatOk(scriptReply(goodSegments.sublist(0, 3)));
        }
        return chatOk(scriptReply(goodSegments));
      }),
    );
    llm.sleep = (_) async {};

    final script = await runScript(selected: photos, llm: llm);

    expect(script.segments, hasLength(4));
    expect(calls, 2, reason: '段数不符按 transient 重试 1 次');
  });

  test('line over 40 chars fails as transient after one retry', () async {
    var calls = 0;
    const longLine =
        '这段口播稿故意写得特别长用来触发单段超过四十字的校验违规需要按 transient 重试一次后失败而不是悄悄截断或返回空稿';
    final llm = makeClient(
      MockClient((request) async {
        calls++;
        return chatOk(
          scriptReply(<Map<String, dynamic>>[
            {'photo': '001_a', 'line': longLine},
            {'photo': '002_b', 'line': '孩子在草地上奔跑'},
          ]),
        );
      }),
    );
    llm.sleep = (_) async {};

    await expectLater(
      runScript(
        selected: <PhotoInfo>[info('001_a'), info('002_b', hasPerson: true)],
        llm: llm,
      ),
      throwsA(
        isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.transient),
      ),
    );
    expect(calls, 2, reason: '重试 1 次后仍违规 → 失败，不降级');
  });

  test('persistent count violation fails, never an empty script', () async {
    var calls = 0;
    final llm = makeClient(
      MockClient((request) async {
        calls++;
        return chatOk(scriptReply(goodSegments.sublist(0, 3)));
      }),
    );
    llm.sleep = (_) async {};

    await expectLater(
      runScript(selected: photos, llm: llm),
      throwsA(
        isA<PipelineError>().having((e) => e.cls, 'cls', ErrorClass.transient),
      ),
    );
    expect(calls, 2, reason: '两次都少段 → 抛错而非返回空/部分脚本');
  });
}
