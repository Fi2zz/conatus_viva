# 图片合成 / 视频合成 双类型 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在桌面 app 中落地「图片合成」与「视频合成」两个生成类型，图片侧支持万相 2.7 / 千问图像 3.0 / Z-Image 的文生图、图生图与系列图，视频侧新增通用文生视频入口。

**Architecture:** 纯 Dart 生成层新增 `generation_models.dart`（模型目录）、`image_client.dart`（三族适配器）、`image_generation.dart`（提交→轮询→下载编排）；内嵌 server 新增 `/api/models`、`/api/images/*`、`/api/videos/*`；React 前端新增两个平行 tab，复用现有「页内费用确认 + 1 秒轮询」交互。价格与能力全部由目录 + 配置驱动，前端不硬编码。

**Tech Stack:** Dart 3 / `package:http` / `package:test`；React 19 + Vite + TypeScript；Vitest。

**Spec:** `docs/superpowers/specs/2026-10-22-image-and-video-generation-split-design.md`

## Global Constraints

- `lib/pipeline/**` 与 `lib/server/**` 不得 import `package:flutter/*`。
- 密钥只从环境变量读（`PipelineConfig.requireApiKey`），不落文件、不进日志。
- 所有 Dart 测试必须离线：HTTP 用 `MockClient`，生成任务用注入的 fake runner。
- `dart analyze lib bin test` 必须零告警。
- 价格只来自配置/目录，前端费用文案必须含「以实际账单为准」。
- 失败不计费：本地校验失败返回 4xx；百炼任务失败或超时 `cost = 0`。
- 既有 `/api/t2v/*`、`/api/dialects`、`/api/edit-models` 行为不得改变。
- 写文件一律 `.tmp` + `rename` 原子落盘。
- API JSON 字段名用 `snake_case`；Dart 侧用 lowerCamelCase。

## Review Focus

- 参考图不是合法 `data:image/*;base64,...`、超 10MB 或超过模型张数上限 → 返回 400 且不发起百炼请求。
- 子模式与模型能力不匹配（`z-image-turbo` + i2i、`qwen-image-3.0` + series）→ 400，文案列出该模型支持的模式。
- 非法 `size`（`0*0`、`abc`、超出该模型像素范围）→ 400，不产生任何费用。
- 下载阶段单张失败 → 其余图片照常落盘可用，`cost` 只计成功张数。
- 任务超时 → `failed` 且 `cost = 0`，目录里不出现半写的 `image-XX.png`。

---

## File Structure

| 文件 | 职责 |
|---|---|
| `lib/pipeline/generation_models.dart` | 图片/视频模型目录、能力校验、价格档位解析与合并 |
| `lib/pipeline/bailian/image_client.dart` | `ImageTask` / `ImageRequest` / 三族请求体与响应解析 |
| `lib/pipeline/image_generation.dart` | 图片任务编排：校验、轮询、下载、原子落盘、计费 |
| `lib/pipeline/config.dart` | 新增 `image.*` 与 `pricing.*` 解析 |
| `lib/server/api_router.dart` | 新增 7 条路由 |
| `lib/server/pipeline_server.dart` | 模型清单、图片/视频任务与文件下载 |
| `frontend/src/imageCost.ts` | 图片预估纯函数 |
| `frontend/src/CostGate.tsx` | 页内费用确认条（图片/视频共用） |
| `frontend/src/useJob.ts` | 轮询 hook |
| `frontend/src/ImageStudio.tsx` | 图片合成页 |
| `frontend/src/TextToVideo.tsx` | 通用文生视频页 |
| `frontend/src/App.tsx` | 四 tab 导航 |

---

### Task 1: 配置层新增 image 任务参数与定价表

**Files:**
- Modify: `lib/pipeline/config.dart`
- Test: `test/pipeline/config_test.dart`
- Modify: `pipeline_config.example.json`

**Interfaces:**
- Consumes: 既有 `_section` / `_double` 辅助方法与 `PipelineConfig.load`。
- Produces:
  - `final int imagePollSeconds`
  - `final int imageMaxWaitMinutes`
  - `final String imageDefaultModel`
  - `final Map<String, Map<String, double>> imagePrices`
  - `final Map<String, Map<String, double>> videoPrices`
  - 构造函数新增同名可选参数，默认 `5` / `10` / `'qwen-image-3.0-pro'` / `const {}` / `const {}`。

- [ ] **Step 1: 写失败测试**

在 `test/pipeline/config_test.dart` 的 `main()` 末尾追加：

```dart
test('image section defaults', () async {
  final c = await PipelineConfig.load(file: await writeConfig(tmp, '{}'), env: {});
  expect(c.imagePollSeconds, 5);
  expect(c.imageMaxWaitMinutes, 10);
  expect(c.imageDefaultModel, 'qwen-image-3.0-pro');
  expect(c.imagePrices, isEmpty);
  expect(c.videoPrices, isEmpty);
});

test('pricing tables parse model → tier → price', () async {
  final c = await PipelineConfig.load(
    file: await writeConfig(
      tmp,
      '{"image": {"poll_seconds": 3, "default_model": "wan2.7-image"},'
      ' "pricing": {"image": {"wan2.7-image-pro": {"2K": 0.5, "4K": 1.0}},'
      ' "video": {"wan3.0-video": {"720P": 0.42}}}}',
    ),
    env: {},
  );
  expect(c.imagePollSeconds, 3);
  expect(c.imageDefaultModel, 'wan2.7-image');
  expect(c.imagePrices['wan2.7-image-pro'], {'2K': 0.5, '4K': 1.0});
  expect(c.videoPrices['wan3.0-video'], {'720P': 0.42});
});

test('malformed pricing values are ignored', () async {
  final c = await PipelineConfig.load(
    file: await writeConfig(
      tmp,
      '{"pricing": {"image": {"x": {"2K": "free", "1K": 0.2}}, "video": []}}',
    ),
    env: {},
  );
  expect(c.imagePrices['x'], {'1K': 0.2});
  expect(c.videoPrices, isEmpty);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/config_test.dart -n "image section defaults"`
Expected: FAIL — `imagePollSeconds` 未定义。

- [ ] **Step 3: 实现配置字段与解析**

在 `PipelineConfig.load` 中新增 `_section(json, 'image')`、`_priceTable(json, 'image')`、`_priceTable(json, 'video')`，并在构造函数加可选参数（默认值见 Interfaces）。新增静态方法：

```dart
/// `pricing.<section>.<model>.<tier> = 元`；非数字或非对象条目跳过。
static Map<String, Map<String, double>> _priceTable(
  Map<String, dynamic> json,
  String section,
) {
  final root = _section(json, 'pricing');
  final table = _section(root, section);
  final out = <String, Map<String, double>>{};
  for (final entry in table.entries) {
    final tiers = entry.value;
    if (tiers is! Map<String, dynamic>) continue;
    final prices = <String, double>{
      for (final t in tiers.entries)
        if (t.value is num) t.key: (t.value as num).toDouble(),
    };
    if (prices.isNotEmpty) out[entry.key] = prices;
  }
  return out;
}
```

同时把三个新键写进 `pipeline_config.example.json` 的 `image` 段与 `pricing` 段（数值照 spec §5）。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/config_test.dart`
Expected: PASS（全文件）。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/config.dart test/pipeline/config_test.dart pipeline_config.example.json
git commit -m "feat(config): 图片任务参数与图片/视频定价表"
```

---

### Task 2: 模型目录与价格档位

**Files:**
- Create: `lib/pipeline/generation_models.dart`
- Test: `test/pipeline/generation_models_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `imagePrices` / `videoPrices`。
- Produces:
  - `enum GenerationKind { image, video }`
  - `enum ImageFamily { qwen3, wan27, zImage }`
  - `enum ImageMode { t2i, i2i, series }`
  - `class ImageModel { String id, label; ImageFamily family; Set<ImageMode> modes; int maxImages, maxRefImages; bool supportsNegativePrompt; List<String> sizes; Map<String, double> defaultPrices; Map<String, Object?> toJson(Map<String, double> prices); }`
  - `class VideoModel { String id, label; List<String> resolutions; int durationMin, durationMax; bool supportsAudio; Map<String, double> defaultPrices; Map<String, Object?> toJson(Map<String, double> prices); }`
  - `const List<ImageModel> kImageModels`（顺序即 UI 顺序：qwen-pro、qwen、wan-pro、wan、z-image）
  - `const List<VideoModel> kTextToVideoModels`（`wan3.0-video`、`wan3.0-video-prime`）
  - `ImageModel? findImageModel(String id)` / `VideoModel? findTextToVideoModel(String id)`
  - `String priceTierFor(String? size)` — `'1K'|'2K'|'4K'`
  - `Map<String, double> resolvePrices({required Map<String, double> defaults, required Map<String, Map<String, double>> overrides, required String model})`
  - `double unitPrice({required Map<String, double> prices, required String tier})` — 缺失档位回落到最便宜档；空表返回 `0`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:test/test.dart';

void main() {
  test('catalog covers the five image models with their capabilities', () {
    expect(kImageModels.map((m) => m.id), [
      'qwen-image-3.0-pro',
      'qwen-image-3.0',
      'wan2.7-image-pro',
      'wan2.7-image',
      'z-image-turbo',
    ]);
    final z = findImageModel('z-image-turbo')!;
    expect(z.modes, {ImageMode.t2i});
    expect(z.maxImages, 1);
    expect(findImageModel('wan2.7-image')!.modes, contains(ImageMode.series));
    expect(findImageModel('qwen-image-3.0')!.maxRefImages, 3);
  });

  test('video catalog only exposes text-to-video models', () {
    expect(kTextToVideoModels.map((m) => m.id), [
      'wan3.0-video',
      'wan3.0-video-prime',
    ]);
    expect(findTextToVideoModel('wan2.6-i2v-flash'), isNull);
  });

  test('priceTierFor maps pixel sizes by area', () {
    expect(priceTierFor(null), '2K');
    expect(priceTierFor('1K'), '1K');
    expect(priceTierFor('1024*1024'), '1K');
    expect(priceTierFor('2048*2048'), '2K');
    expect(priceTierFor('4096*4096'), '4K');
    expect(priceTierFor('abc'), '2K');
  });

  test('resolvePrices lets config override catalog defaults per tier', () {
    final merged = resolvePrices(
      defaults: {'2K': 0.5},
      overrides: {
        'qwen-image-3.0-pro': {'1K': 0.35},
      },
      model: 'qwen-image-3.0-pro',
    );
    expect(merged, {'2K': 0.5, '1K': 0.35});
  });

  test('unitPrice falls back to the cheapest configured tier', () {
    expect(unitPrice(prices: {'1K': 0.2, '2K': 0.5}, tier: '4K'), 0.2);
    expect(unitPrice(prices: {'2K': 0.5}, tier: '2K'), 0.5);
    expect(unitPrice(prices: {}, tier: '2K'), 0);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/generation_models_test.dart`
Expected: FAIL — 找不到 `generation_models.dart`。

- [ ] **Step 3: 实现目录**

按 spec §2.1 / §2.2 填数据：

- qwen3：`maxImages: 6`、`maxRefImages: 3`、`supportsNegativePrompt: true`、`modes: {t2i, i2i}`、默认价 `{'1K': 0.35, '2K': 0.5}`（vanilla 版 `{'1K': 0.2, '2K': 0.3}`）。
- wan27：`maxImages: 4`、`maxRefImages: 9`、`supportsNegativePrompt: false`、`modes: {t2i, i2i, series}`、pro 价 `{'1K': 0.35, '2K': 0.5, '4K': 1.0}`，标准版 `{'1K': 0.2, '2K': 0.3}`。
- zImage：`maxImages: 1`、`maxRefImages: 0`、`modes: {t2i}`、默认价 `{'2K': 0.1}`。
- 视频：`wan3.0-video` 默认价 `{'480P': 0.21, '720P': 0.42, '1080P': 0.84}`；prime `{'480P': 0.45, '720P': 0.9, '1080P': 1.8}`；两者 `durationMin: 2, durationMax: 30, supportsAudio: true`。

`priceTierFor` 的像素解析：`size` 含 `*` 且两侧为整数才按面积分档，否则返回 `'2K'`。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/generation_models_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/generation_models.dart test/pipeline/generation_models_test.dart
git commit -m "feat(models): 图片/视频模型目录与价格档位"
```

---

### Task 3: 三族图片 client（请求体 + 响应解析）

**Files:**
- Create: `lib/pipeline/bailian/image_client.dart`
- Test: `test/pipeline/image_client_test.dart`

**Interfaces:**
- Consumes: `PipelineError` / `ErrorClass`（`errors.dart`）、`package:http`、Task 2 的 `ImageFamily` / `ImageMode`。
- Produces:
  - `enum ImageTaskStatus { running, succeeded, failed }`
  - `class ImageTask { String taskId; ImageTaskStatus status; List<Uri> imageUrls; String? errorCode; }`
  - `class ImageRequest { String model; ImageFamily family; ImageMode mode; String prompt; String? negativePrompt; String? size; int n; int? seed; List<String> refImages; }`
  - `abstract class ImageGenClient { Future<ImageTask> submit(ImageRequest); Future<ImageTask> poll(String taskId); Future<List<int>> download(Uri url); }`
  - `class QwenImageClient` / `WanImageClient` / `ZImageClient`，构造函数 `({required String apiKey, http.Client? client, String? host, required String model})`
  - `ImageGenClient buildImageClient({required ImageRequest request, required String apiKey, http.Client? client, String? host})`

- [ ] **Step 1: 写失败测试**

覆盖三件事：请求体、两种响应结构、错误分类。

```dart
import 'dart:convert';

import 'package:flutter_wanxiang/pipeline/bailian/image_client.dart';
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

ImageRequest _req({
  ImageMode mode = ImageMode.t2i,
  List<String> refs = const [],
  String? negative,
  String? size,
  int n = 1,
}) => ImageRequest(
  model: 'qwen-image-3.0-pro',
  family: ImageFamily.qwen3,
  mode: mode,
  prompt: '一只猫',
  negativePrompt: negative,
  size: size,
  n: n,
  seed: 7,
  refImages: refs,
);

void main() {
  test('qwen body carries messages, refs and negative prompt', () async {
    late Map<String, dynamic> body;
    final client = QwenImageClient(
      apiKey: 'k',
      model: 'qwen-image-3.0-pro',
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(req.headers['X-DashScope-Async'], 'enable');
        return http.Response(
          '{"output":{"task_id":"t1","task_status":"PENDING"}}',
          200,
        );
      }),
    );
    await client.submit(
      _req(
        mode: ImageMode.i2i,
        refs: ['data:image/png;base64,AAA'],
        negative: '模糊',
        size: '1024*1024',
      ),
    );
    expect(body['model'], 'qwen-image-3.0-pro');
    final content =
        (body['input'] as Map)['messages'][0]['content'] as List<dynamic>;
    expect(content.first, {'image': 'data:image/png;base64,AAA'});
    expect(content.last, {'text': '一只猫'});
    expect((body['parameters'] as Map)['negative_prompt'], '模糊');
    expect((body['parameters'] as Map)['size'], '1024*1024');
  });

  test('wan body uses size tier and sequential flag', () async {
    late Map<String, dynamic> body;
    final client = WanImageClient(
      apiKey: 'k',
      model: 'wan2.7-image-pro',
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(
          '{"output":{"task_id":"t1","task_status":"PENDING"}}',
          200,
        );
      }),
    );
    await client.submit(
      ImageRequest(
        model: 'wan2.7-image-pro',
        family: ImageFamily.wan27,
        mode: ImageMode.series,
        prompt: '四季',
        size: '2K',
        n: 4,
        refImages: const [],
      ),
    );
    final params = body['parameters'] as Map<String, dynamic>;
    expect(params['enable_sequential'], isTrue);
    expect(params['size'], '2K');
    expect(params['n'], 4);
    expect(params.containsKey('thinking_mode'), isFalse);
  });

  test('z-image body uses prompt and results url parsing', () async {
    late Map<String, dynamic> body;
    final client = ZImageClient(
      apiKey: 'k',
      model: 'z-image-turbo',
      client: MockClient((req) async {
        if (req.method == 'POST') {
          body = jsonDecode(req.body) as Map<String, dynamic>;
          return http.Response(
            '{"output":{"task_id":"t1","task_status":"PENDING"}}',
            200,
          );
        }
        return http.Response(
          '{"output":{"task_id":"t1","task_status":"SUCCEEDED",'
          '"results":[{"url":"https://x/1.png"}]}}',
          200,
        );
      }),
    );
    await client.submit(
      ImageRequest(
        model: 'z-image-turbo',
        family: ImageFamily.zImage,
        mode: ImageMode.t2i,
        prompt: '一只猫',
        n: 1,
        refImages: const [],
      ),
    );
    expect((body['input'] as Map)['prompt'], '一只猫');
    final task = await client.poll('t1');
    expect(task.status, ImageTaskStatus.succeeded);
    expect(task.imageUrls.single.toString(), 'https://x/1.png');
  });

  test('choices-shaped response is parsed for qwen and wan', () async {
    final client = QwenImageClient(
      apiKey: 'k',
      model: 'qwen-image-3.0-pro',
      client: MockClient((req) async => http.Response(
        '{"output":{"task_id":"t1","task_status":"SUCCEEDED","choices":['
        '{"message":{"content":[{"image":"https://x/a.png"},{"image":"https://x/b.png"}]}}]}}',
        200,
      )),
    );
    final task = await client.poll('t1');
    expect(task.imageUrls.map((u) => u.toString()), ['https://x/a.png', 'https://x/b.png']);
  });

  test('5xx is transient, 400 is fatal', () async {
    Future<void> expectClass(int status, ErrorClass cls) async {
      final client = QwenImageClient(
        apiKey: 'k',
        model: 'qwen-image-3.0-pro',
        client: MockClient((req) async => http.Response('{"message":"x"}', status)),
      );
      await expectLater(
        client.poll('t1'),
        throwsA(isA<PipelineError>().having((e) => e.cls, 'cls', cls)),
      );
    }

    await expectClass(500, ErrorClass.transient);
    await expectClass(400, ErrorClass.fatal);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/image_client_test.dart`
Expected: FAIL — 文件不存在。

- [ ] **Step 3: 实现 client**

要点（其余按既有 `dashscope_video.dart` 的写法）：

- 三族共用 `submitUri` 之外的机制：POST 带 `X-DashScope-Async: enable`，轮询 `GET $host/api/v1/tasks/<id>`。
- `QwenImageClient.submitUri` / `WanImageClient.submitUri` = `$host/api/v1/services/aigc/image-generation/generation`；`ZImageClient.submitUri` = `$host/api/v1/services/aigc/text2image/image-synthesis`。
- 统一 `parseTask(String body, String? fallbackTaskId)`：读 `output.task_status` / `output.task_id`；`SUCCEEDED` 时按族抽 URL——`choices[].message.content[].image` 或 `results[].url`；`FAILED`/`CANCELED` 记 `output.code`。
- 请求体按 Task 3 测试与 spec §3.1 生成；`refImages` 以 `{"image": dataUrl}` 形式排在 `{"text": prompt}` 之前。
- 错误分类：408/429/5xx/网络异常 → `transient`；其余非 2xx → `fatal`；200 但结构畸形 → `transient`。
- `download` 直接 GET 并返回 `bodyBytes`，非 200 按同一规则分类。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/image_client_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/bailian/image_client.dart test/pipeline/image_client_test.dart
git commit -m "feat(image): 千问/万相/Z-Image 三族图片 client"
```

---

### Task 4: 图片任务编排

**Files:**
- Create: `lib/pipeline/image_generation.dart`
- Test: `test/pipeline/image_generation_test.dart`

**Interfaces:**
- Consumes: Task 2 `findImageModel` / `ImageMode`；Task 3 `ImageGenClient` / `ImageRequest`。
- Produces:
  - `class ImageJobImage { int index; String path; bool ok; String? error; }`
  - `class ImageJob { String id; String model; ImageMode mode; int n; List<ImageJobImage> images; double cost; }`
  - `Future<ImageJob> generateImages({required ImageGenClient client, required ImageRequest request, required String baseDir, required String contentId, required double unitPrice, int pollSeconds = 5, int maxWaitMinutes = 10, Future<void> Function(Duration)? sleep, DateTime Function()? now, void Function(String)? onProgress})`
  - `void validateImageRequest(ImageRequest request)` — 抛 `PipelineError(ErrorClass.fatal, ...)`，供 server 映射成 400
  - `bool isValidDataUrl(String value)` — 校验 `data:image/(png|jpeg|webp);base64,` 前缀

- [ ] **Step 1: 写失败测试**

```dart
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/image_client.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:flutter_wanxiang/pipeline/image_generation.dart';
import 'package:test/test.dart';

ImageRequest _req({int n = 2, List<String> refs = const [], String? size}) =>
    ImageRequest(
      model: 'qwen-image-3.0-pro',
      family: ImageFamily.qwen3,
      mode: refs.isEmpty ? ImageMode.t2i : ImageMode.i2i,
      prompt: '一只猫',
      size: size,
      n: n,
      refImages: refs,
    );

class _FakeClient implements ImageGenClient {
  _FakeClient({this.statuses = const [ImageTaskStatus.running, ImageTaskStatus.succeeded], this.urls = const ['https://x/1.png', 'https://x/2.png']});
  final List<ImageTaskStatus> statuses;
  final List<String> urls;
  int polls = 0;

  @override
  Future<ImageTask> submit(ImageRequest request) async => ImageTask(
    taskId: 't1',
    status: ImageTaskStatus.running,
    imageUrls: const [],
  );

  @override
  Future<ImageTask> poll(String taskId) async {
    final status = statuses[polls++ < statuses.length ? polls - 1 : statuses.length - 1];
    return ImageTask(
      taskId: taskId,
      status: status,
      imageUrls: status == ImageTaskStatus.succeeded ? urls.map(Uri.parse).toList() : const [],
    );
  }

  @override
  Future<List<int>> download(Uri url) async => [1, 2, 3];
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('conatus_img_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('submits, polls, downloads and charges per successful image', () async {
    final job = await generateImages(
      client: _FakeClient(),
      request: _req(n: 2),
      baseDir: tmp.path,
      contentId: 'c1',
      unitPrice: 0.5,
      sleep: (_) async {},
      onProgress: (_) {},
    );
    expect(job.cost, 1.0);
    expect(job.images.map((i) => i.ok), [true, true]);
    expect(File('${tmp.path}/c1/image-01.png').existsSync(), isTrue);
    expect(File('${tmp.path}/c1/image-02.png').existsSync(), isTrue);
    expect(File('${tmp.path}/c1/.tmp-image-01.png').existsSync(), isFalse);
  });

  test('a failed download keeps the others and only charges successes', () async {
    final client = _FailingDownloadClient();
    final job = await generateImages(
      client: client,
      request: _req(n: 2),
      baseDir: tmp.path,
      contentId: 'c2',
      unitPrice: 0.5,
      sleep: (_) async {},
    );
    expect(job.cost, 0.5);
    expect(job.images.map((i) => i.ok), [true, false]);
  });

  test('terminal failure throws and writes nothing', () async {
    await expectLater(
      generateImages(
        client: _FakeClient(statuses: const [ImageTaskStatus.running, ImageTaskStatus.failed]),
        request: _req(),
        baseDir: tmp.path,
        contentId: 'c3',
        unitPrice: 0.5,
        sleep: (_) async {},
      ),
      throwsA(isA<PipelineError>()),
    );
    expect(Directory('${tmp.path}/c3').existsSync(), isFalse);
  });

  test('validation rejects unsupported mode, refs and size before any request', () {
    expect(
      () => validateImageRequest(ImageRequest(
        model: 'z-image-turbo',
        family: ImageFamily.zImage,
        mode: ImageMode.i2i,
        prompt: 'x',
        n: 1,
        refImages: const ['data:image/png;base64,AAA'],
      )),
      throwsA(isA<PipelineError>()),
    );
    expect(
      () => validateImageRequest(_req(refs: List.filled(4, 'data:image/png;base64,AAA'))),
      throwsA(isA<PipelineError>()),
    );
    expect(() => validateImageRequest(_req(size: '0*0')), throwsA(isA<PipelineError>()));
    expect(isValidDataUrl('data:image/png;base64,AAA'), isTrue);
    expect(isValidDataUrl('https://x/a.png'), isFalse);
  });
}

class _FailingDownloadClient extends _FakeClient {
  @override
  Future<List<int>> download(Uri url) async {
    if (url.path.endsWith('2.png')) throw const PipelineError(ErrorClass.transient, 'boom');
    return [1, 2, 3];
  }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/image_generation_test.dart`
Expected: FAIL — 文件不存在。

- [ ] **Step 3: 实现编排与校验**

- `validateImageRequest`：模型存在 → `modes` 含请求模式 → `refs.length <= maxRefImages`、每条 `isValidDataUrl` 且解码后 ≤10MB → `n` 在 `1..maxImages`（series 放宽到 12）→ `size` 合法（`1K|2K|4K` 或 `W*H`，且宽高 ≥ 512、总像素 ≤ 2048²；wan pro 的 4K 档 ≤ 4096²）。
- `generateImages`：提交 → `pollSeconds` 间隔轮询到终态 → 失败抛 `PipelineError(ErrorClass.transient, '图片任务 $taskId 失败：<code>')` → 成功逐张下载，先写 `<dir>/.tmp-image-XX.png` 再 `rename`，单张异常记 `ok: false` 继续 → `cost = unitPrice * 成功张数`。
- 超时抛 `PipelineError(ErrorClass.fatal, '图片任务 $taskId 超时')`，不创建任务目录（目录在拿到成功结果后才创建）。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/pipeline/image_generation_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/image_generation.dart test/pipeline/image_generation_test.dart
git commit -m "feat(image): 图片生成任务编排与校验"
```

---

### Task 5: server 路由、模型清单与图片接口

**Files:**
- Modify: `lib/server/api_router.dart`
- Modify: `lib/server/pipeline_server.dart`
- Test: `test/server/api_router_test.dart`
- Test: `test/server/image_api_test.dart`

**Interfaces:**
- Consumes: Task 1 配置字段；Task 2 目录与 `resolvePrices` / `unitPrice` / `priceTierFor`；Task 4 `generateImages` / `ImageJob` / `validateImageRequest`。
- Produces:
  - `enum ApiRoute` 新增 `getModels`、`createImage`、`getImage`、`getImageFile`
  - `typedef ImageRunner = Future<ImageJob> Function({required ImageRequest request, required String contentId, required void Function(String message) onProgress});`
  - `PipelineServer` 新增可选参数 `imageRunner`、`imagesOutputDir`
  - `class JobRunRecord { String id; String status; List<String> logs; String? filePath; List<String> imagePaths; double cost; String? error; }`（图片与视频任务共用）

- [ ] **Step 1: 写失败测试**

`api_router_test.dart` 追加：

```dart
test('image + models routes, file wins over bare id', () {
  expect(apiRouteFor('GET', '/api/models'), ApiRoute.getModels);
  expect(apiRouteFor('POST', '/api/images'), ApiRoute.createImage);
  expect(apiRouteFor('GET', '/api/images/img-1/2'), ApiRoute.getImageFile);
  expect(apiRouteFor('GET', '/api/images/img-1'), ApiRoute.getImage);
  expect(apiRouteFor('POST', '/api/images/img-1/2'), ApiRoute.unknown);
  expect(apiRouteFor('GET', '/api/models/x'), ApiRoute.unknown);
});
```

`image_api_test.dart`（新建）：

```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_wanxiang/pipeline/bailian/image_client.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/generation_models.dart';
import 'package:flutter_wanxiang/pipeline/image_generation.dart';
import 'package:flutter_wanxiang/server/pipeline_server.dart';
import 'package:test/test.dart';

// _cfg / _get / _postJson 复制 pipeline_server_test.dart 的写法，
// _cfg 使用 PipelineConfig 默认构造 + 下列覆盖：
const _cfg = PipelineConfig(
  llmModel: 'qwen3.8-flash',
  ttsModel: 'qwen-audio-3.1-tts-flash',
  ttsFallbackModel: 'qwen3-tts-flash',
  ttsVoiceId: null,
  ttsFallbackVoice: 'Cherry',
  i2vModel: 'wan2.6-i2v-flash',
  i2vResolution: '720P',
  i2vWatermark: true,
  i2vSeed: 42,
  i2vPollSeconds: 15,
  i2vMaxWaitMinutes: 10,
  ossBucket: '',
  ossEndpoint: '',
  ossPrefix: 'pipeline-exp/',
  targetCount: 4,
  minClipS: 2,
  maxClipS: 15,
);

void main() {
  late Directory staticDir;
  late Directory outDir;
  late PipelineServer server;

  setUp(() async {
    staticDir = Directory.systemTemp.createTempSync('conatus_img_static');
    File('${staticDir.path}/index.html').writeAsStringSync('<html></html>');
    outDir = Directory.systemTemp.createTempSync('conatus_img_out');
    server = PipelineServer(
      cfg: _cfg,
      staticDir: staticDir,
      port: 0,
      imagesOutputDir: outDir.path,
      imageRunner:
          ({required ImageRequest request, required String contentId, required void Function(String) onProgress}) async {
            final path = '${outDir.path}/$contentId/image-01.png';
            File(path).createSync(recursive: true);
            File(path).writeAsBytesSync([9, 9]);
            onProgress('fake');
            return ImageJob(
              id: contentId,
              model: request.model,
              mode: request.mode,
              n: request.n,
              images: [ImageJobImage(index: 1, path: path, ok: true)],
              cost: 0.5,
            );
          },
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    staticDir.deleteSync(recursive: true);
    outDir.deleteSync(recursive: true);
  });

  test('GET /api/models returns both kinds with merged prices', () async {
    final res = await _get(server.boundPort!, '/api/models');
    expect(res.status, 200);
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final image = body['image'] as List<dynamic>;
    expect(image.map((m) => m['id']), contains('qwen-image-3.0-pro'));
    expect((image.first['prices'] as Map).isNotEmpty, isTrue);
    expect((body['video'] as List).map((m) => m['id']), contains('wan3.0-video'));
  });

  test('POST /api/images runs a job and serves the file', () async {
    final created = await _postJson(server.boundPort!, '/api/images', {
      'model': 'qwen-image-3.0-pro',
      'mode': 't2i',
      'prompt': '一只猫',
      'n': 1,
    });
    expect(created.status, 202);
    final id = (jsonDecode(created.body) as Map<String, dynamic>)['id'] as String;

    var status = 'running';
    Map<String, dynamic> body = {};
    for (var i = 0; i < 50 && status == 'running'; i++) {
      body = jsonDecode((await _get(server.boundPort!, '/api/images/$id')).body)
          as Map<String, dynamic>;
      status = body['status'] as String;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(status, 'completed');
    expect(body['cost'], 0.5);
    expect((body['results'] as List).single['index'], 1);

    final file = await _get(server.boundPort!, '/api/images/$id/1');
    expect(file.status, 200);
  });

  test('unsupported mode and oversized refs are 400 before any run', () async {
    final bad = await _postJson(server.boundPort!, '/api/images', {
      'model': 'z-image-turbo',
      'mode': 'i2i',
      'prompt': 'x',
      'n': 1,
      'refs': ['data:image/png;base64,AAA'],
    });
    expect(bad.status, 400);
    expect(bad.body, contains('模式'));

    final tooMany = await _postJson(server.boundPort!, '/api/images', {
      'model': 'qwen-image-3.0-pro',
      'mode': 'i2i',
      'prompt': 'x',
      'n': 1,
      'refs': List.filled(4, 'data:image/png;base64,AAA'),
    });
    expect(tooMany.status, 400);
  });

  test('missing model is 400', () async {
    final res = await _postJson(server.boundPort!, '/api/images', {'prompt': 'x'});
    expect(res.status, 400);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/server/api_router_test.dart test/server/image_api_test.dart`
Expected: FAIL — 路由枚举/构造参数不存在。

- [ ] **Step 3: 实现路由与 handler**

- `apiRouteFor`：`/api/models` GET → `getModels`；`/api/images` POST → `createImage`；`/api/images/<id>` GET → `getImage`；`/api/images/<id>/<n>` GET → `getImageFile`（必须先判 4 段）。
- `_getModels`：`kImageModels` / `kTextToVideoModels` 逐项 `toJson(resolvePrices(defaults: m.defaultPrices, overrides: cfg.imagePrices|videoPrices, model: m.id))`，并附 `image.default_model`。
- `_createImage`：校验 JSON、`model/mode/prompt` 必填；从目录取 `ImageModel`，用其 `family` 构造 `ImageRequest`（`family` 绝不从请求体读）；`n`/`seed`/`refs` 默认值；`validateImageRequest` 抛出的 `PipelineError` → 400（`error` 用其 `message`）；其余异常走既有 500。校验通过后建 `JobRunRecord` 并 `unawaited(_runImage(...))`，返回 202 `{id}`。
- `_runImage`：调 `imageRunner ?? _defaultImageRunner`；默认 runner 用 `buildImageClient` + `generateImages`，`baseDir = imagesOutputDir ?? '$HOME/conatus_viva/images'`；成功写 `imagePaths`、`cost`，异常按主讲人模式分类写 `error`。
- `_getImage` / `_getImageFile`：文件按 `image/png` 返回，`<n>` 超出范围 → 404。
- 任务 id 前缀 `img-`，复用 `_newRunId` 的格式（把前缀参数化）。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/server`
Expected: PASS（含既有主讲人测试）。

- [ ] **Step 5: 提交**

```bash
git add lib/server/api_router.dart lib/server/pipeline_server.dart test/server/api_router_test.dart test/server/image_api_test.dart
git commit -m "feat(server): 模型清单与图片合成接口"
```

---

### Task 6: 通用文生视频接口

**Files:**
- Modify: `lib/server/api_router.dart`
- Modify: `lib/server/pipeline_server.dart`
- Test: `test/server/api_router_test.dart`
- Test: `test/server/video_api_test.dart`

**Interfaces:**
- Consumes: Task 2 `findTextToVideoModel` / `resolvePrices`；既有 `generateTextToVideo` 与 `Wan30VideoClient`。
- Produces:
  - `enum ApiRoute` 新增 `createVideo`、`getVideo`、`getVideoFile`
  - `typedef TextToVideoRunner = Future<TextToVideoResult> Function({required String prompt, required String model, required String resolution, required String ratio, required int durationS, required bool audio, required String contentId, required void Function(String message) onProgress});`
  - `PipelineServer` 新增可选参数 `videoRunner`、`videosOutputDir`

- [ ] **Step 1: 写失败测试**

`api_router_test.dart` 追加：

```dart
test('video routes, file wins over bare id', () {
  expect(apiRouteFor('POST', '/api/videos'), ApiRoute.createVideo);
  expect(apiRouteFor('GET', '/api/videos/vid-1/video'), ApiRoute.getVideoFile);
  expect(apiRouteFor('GET', '/api/videos/vid-1'), ApiRoute.getVideo);
  expect(apiRouteFor('POST', '/api/videos/vid-1'), ApiRoute.unknown);
});
```

`video_api_test.dart`：复制 `image_api_test.dart` 的 `_get` / `_postJson` / setUp 骨架（额外 `import 'package:flutter_wanxiang/pipeline/text_to_video.dart';`），注入：

```dart
videoRunner:
    ({required String prompt, required String model, required String resolution,
      required String ratio, required int durationS, required bool audio,
      required String contentId, required void Function(String) onProgress}) async {
      final path = '${outDir.path}/$contentId/video.mp4';
      File(path).createSync(recursive: true);
      File(path).writeAsBytesSync([1, 2]);
      onProgress('fake');
      return TextToVideoResult(filePath: path, taskId: 't1', durationS: durationS);
    },
```

断言：

```dart
test('POST /api/videos then poll and download', () async {
  final created = await _postJson(server.boundPort!, '/api/videos', {
    'model': 'wan3.0-video',
    'prompt': '一只猫',
    'resolution': '720P',
    'ratio': 'adaptive',
    'duration': 5,
    'audio': true,
  });
  expect(created.status, 202);
  final id = (jsonDecode(created.body) as Map<String, dynamic>)['id'] as String;
  // 轮询直到 completed（同 image 测试的 20ms 间隔写法）
  final file = await _get(server.boundPort!, '/api/videos/$id/video');
  expect(file.status, 200);
});

test('unknown model and out-of-range duration are 400', () async {
  expect((await _postJson(server.boundPort!, '/api/videos', {
    'model': 'wan2.6-i2v-flash', 'prompt': 'x', 'duration': 5,
  })).status, 400);
  expect((await _postJson(server.boundPort!, '/api/videos', {
    'model': 'wan3.0-video', 'prompt': 'x', 'duration': 99,
  })).status, 400);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/server/video_api_test.dart`
Expected: FAIL — `createVideo` 不存在。

- [ ] **Step 3: 实现**

- 路由：`/api/videos` POST；`/api/videos/<id>` GET；`/api/videos/<id>/video` GET（先判 4 段）。
- `_createVideo`：校验 `model` 在 `kTextToVideoModels`、`prompt` 非空、`duration` 在目录区间、`resolution` 在目录列表、`audio` 为 bool、`ratio` 缺省 `adaptive`。
- `_runVideo`：默认 runner 构造 `Wan30VideoClient(apiKey: cfg.requireApiKey(), host: cfg.apiHost, model:, resolution:, ratio:, audio:, watermark: cfg.t2vWatermark, seed: cfg.t2vSeed)`，调用 `generateTextToVideo(outFile: '$baseDir/$id/video.mp4', pollSeconds: cfg.t2vPollSeconds, maxWaitMinutes: cfg.t2vMaxWaitMinutes)`。
- 任务 id 前缀 `vid-`。
- 记录类型复用 Task 5 的 `ImageRunRecord` 结构，改名 `JobRunRecord`（含 `filePath` 与 `imagePaths`），两处共用，避免重复。

- [ ] **Step 4: 跑测试确认通过**

Run: `dart test test/server`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/server/api_router.dart lib/server/pipeline_server.dart test/server/api_router_test.dart test/server/video_api_test.dart
git commit -m "feat(server): 通用文生视频接口"
```

---

### Task 7: 前端纯函数与共享件

**Files:**
- Create: `frontend/src/imageCost.ts`
- Create: `frontend/src/CostGate.tsx`
- Create: `frontend/src/useJob.ts`
- Create: `frontend/src/imageCost.test.ts`
- Modify: `frontend/src/App.css`（确认条样式复用 `.confirm`）

**Interfaces:**
- Consumes: `GET /api/models` 返回的 `prices: Record<string, number>`。
- Produces:
  - `export function priceTierFor(size: string | null): '1K' | '2K' | '4K'`
  - `export function unitPrice(prices: Record<string, number>, size: string | null): number`
  - `export function estimateImageCost(prices: Record<string, number>, size: string | null, n: number): number`
  - `export function CostGate(props: { estimate: number; detail: string; onConfirm: () => void; onCancel: () => void }): ReactElement | null`（`import type { ReactElement } from 'react'`）
  - `export interface JobBase { id: string; status: 'running' | 'completed' | 'failed'; logs: string[]; error?: string }`
  - `export function useJob<T extends JobBase>(id: string | null, buildUrl: (id: string) => string): T | null`

- [ ] **Step 1: 写失败测试**

```ts
import { describe, expect, it } from 'vitest'
import { estimateImageCost, priceTierFor, unitPrice } from './imageCost'

describe('priceTierFor', () => {
  it('maps pixel sizes by area', () => {
    expect(priceTierFor(null)).toBe('2K')
    expect(priceTierFor('1024*1024')).toBe('1K')
    expect(priceTierFor('2048*2048')).toBe('2K')
    expect(priceTierFor('4096*4096')).toBe('4K')
    expect(priceTierFor('abc')).toBe('2K')
  })
})

describe('unitPrice', () => {
  it('falls back to the cheapest tier', () => {
    expect(unitPrice({ '1K': 0.2, '2K': 0.5 }, '4K')).toBe(0.2)
    expect(unitPrice({}, '2K')).toBe(0)
  })

  it('uses the exact tier when present', () => {
    expect(unitPrice({ '2K': 0.5, '4K': 1 }, '4K')).toBe(1)
  })
})

describe('estimateImageCost', () => {
  it('multiplies unit price by image count', () => {
    expect(estimateImageCost({ '2K': 0.5 }, '2K', 4)).toBe(2)
  })
})
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd frontend && npm test -- imageCost`
Expected: FAIL — 模块不存在。

- [ ] **Step 3: 实现三个文件**

- `imageCost.ts`：与 Dart `priceTierFor` / `unitPrice` 完全同规则（面积阈值 2,250,000 / 4,194,304）。
- `CostGate.tsx`：`estimate <= 0` 时返回 `null`；否则渲染 `.confirm` 区块，文案包含 `预估费用 ¥{estimate.toFixed(2)}`、`{detail}`、`以实际账单为准`，按钮「取消」「确认生成」。禁止 `window.confirm`（仓库有 `check:dialogs` 脚本）。
- `useJob.ts`：`id` 为 null 时不轮询；`setInterval` 1s `fetch(buildUrl(id))`，`status !== 'running'` 时清理；卸载时清理；`status` 变化时重置。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd frontend && npm test -- imageCost && npm run lint`
Expected: PASS，oxlint 无告警。

- [ ] **Step 5: 提交**

```bash
git add frontend/src/imageCost.ts frontend/src/imageCost.test.ts frontend/src/CostGate.tsx frontend/src/useJob.ts
git commit -m "feat(web): 图片估价纯函数与费用确认/轮询共享件"
```

---

### Task 8: 图片合成页

**Files:**
- Create: `frontend/src/ImageStudio.tsx`
- Modify: `frontend/src/App.tsx`（新增 tab 与渲染分支）
- Modify: `frontend/src/App.css`

**Interfaces:**
- Consumes: Task 5 的 `GET /api/models`、`POST /api/images`、`GET /api/images/<id>`、`GET /api/images/<id>/<n>`；Task 7 的 `estimateImageCost` / `CostGate` / `useJob`。
- Produces: `export default function ImageStudio(): JSX.Element`

- [ ] **Step 1: 定义页面行为（先写组件骨架与类型）**

```ts
interface ImageModelDto {
  id: string
  label: string
  family: 'qwen3' | 'wan27' | 'zImage'
  modes: Array<'t2i' | 'i2i' | 'series'>
  max_images: number
  max_ref_images: number
  supports_negative_prompt: boolean
  sizes: string[]
  prices: Record<string, number>
}

interface ImageJobDto extends JobBase {
  results?: Array<{ index: number; path: string }>
  cost?: number
}
```

- 进入页面 `fetch('/api/models')`，默认选中 `default_model`。
- 子模式按钮只渲染当前模型 `modes` 里的项；切换模型后若当前子模式不被支持，自动选 `modes[0]` 并显示一行提示。
- 字段：提示词（必填）、反向提示词（仅 `supports_negative_prompt`）、尺寸下拉（`sizes` + 「自动」）、张数（`1..max_images`，series 时 `1..12` 并注明「最多 n 张，实际由模型决定」）、种子（可空）。
- 参考图：`<input type="file" accept="image/*" multiple>`；每个文件 `readAsDataURL`，前端校验 MIME 与 ≤10MB、数量 ≤ `max_ref_images`，超限给 `.form-error` 文案；缩略图列表带「移除」。
- 提交：`mode === 'i2i'` 或 `series` 且有 refs 时把 `refs` 放进 body；否则不传。
- 费用：`estimateImageCost(model.prices, size, n)`；`CostGate` 确认后才 `POST /api/images`。
- 结果：`useJob<ImageJobDto>(id, (i) => '/api/images/' + i)`；`completed` 后网格渲染 `<img src={`/api/images/${id}/${r.index}`}>` 与单独下载链接，并显示 `cost`。

- [ ] **Step 2: 接入 App 导航**

`App.tsx` 的 `mode` 改为 `'image' | 'video' | 'speaker' | 'edit-cost'`，tab 顺序：图片合成 / 文生视频 / 方言配音主讲人 / 视频编辑成本；`image` 分支渲染 `<ImageStudio />`。

- [ ] **Step 3: 手动验证（离线即可）**

Run: `cd frontend && npm run build`
Expected: `tsc -b` 与 vite 构建通过，产物写入 `../web_build/`。

再跑：`cd frontend && npm run lint && npm run check:dialogs`
Expected: 均通过（无原生 confirm/alert）。

- [ ] **Step 4: 提交**

```bash
git add frontend/src/ImageStudio.tsx frontend/src/App.tsx frontend/src/App.css web_build
git commit -m "feat(web): 图片合成页（文生图/图生图/系列图）"
```

---

### Task 9: 通用文生视频页

**Files:**
- Create: `frontend/src/TextToVideo.tsx`
- Modify: `frontend/src/App.tsx`
- Modify: `frontend/src/App.css`

**Interfaces:**
- Consumes: Task 6 的 `/api/videos*`；Task 7 的 `CostGate` / `useJob`；`/api/models` 的 `video` 数组。
- Produces: `export default function TextToVideo(): JSX.Element`

- [ ] **Step 1: 实现页面**

```ts
interface VideoModelDto {
  id: string
  label: string
  resolutions: string[]
  prices: Record<string, number>
  duration_min: number
  duration_max: number
  supports_audio: boolean
}
```

- 字段：模型、提示词、分辨率（`resolutions`）、宽高比（`adaptive` / `16:9` / `9:16` / `1:1`）、时长 slider、保留音频 checkbox。
- 费用：`duration * unitPrice(model.prices, resolution)`（前端直接按分辨率键取值，缺省取最便宜档，与 `imageCost.ts` 的回落规则一致）。
- 确认后 `POST /api/videos`；`useJob<VideoJobDto>(id, (i) => '/api/videos/' + i)`；完成后 `<video src={`/api/videos/${id}/video`}>` + 下载。
- 文案含「以实际账单为准」。

- [ ] **Step 2: 接入 App**

`video` 分支渲染 `<TextToVideo />`。

- [ ] **Step 3: 验证**

Run: `cd frontend && npm test && npm run lint && npm run build`
Expected: 全部通过，`web_build/` 更新。

- [ ] **Step 4: 提交**

```bash
git add frontend/src/TextToVideo.tsx frontend/src/App.tsx frontend/src/App.css web_build
git commit -m "feat(web): 通用文生视频页"
```

---

### Task 10: 文档、示例配置与全量回归

**Files:**
- Modify: `README.md`
- Modify: `docs/万相视频生成与编辑成本核算_v1.0.md`
- Modify: `pipeline_config.example.json`（若 Task 1 已写则只校对）

- [ ] **Step 1: 更新 README**

- 顶部一句话改为「图片 / 视频两类生成」。
- 新增「图片合成」章：五个模型、三种子模式、费用口径（张数 × 单价）、参考图限制（单张 10MB、qwen 3 张 / wan 9 张）。
- 内嵌 API 表补 `/api/models`、`/api/images*`、`/api/videos*`。
- 管线结构树补三个新文件。
- 说明价格来自 `pricing.*`，为占位值。

- [ ] **Step 2: 更新成本文档**

新增一节「图片生成（按张计费）」，列出五个模型的档位与占位单价，并注明「控制台为准」。

- [ ] **Step 3: 全量验证**

Run:
```bash
dart analyze lib bin test
dart test
cd frontend && npm test && npm run lint && npm run build && npm run check:dialogs
```
Expected: 分析零告警、Dart 测试全绿、前端测试/lint/构建/对话框检查全绿。

- [ ] **Step 4: 提交**

```bash
git add README.md docs/万相视频生成与编辑成本核算_v1.0.md pipeline_config.example.json web_build
git commit -m "docs: 图片/视频双类型生成说明与成本口径"
```

---

## Self-Review Notes

- Spec §2 模型清单 → Task 2；§3 架构 → Task 3/4；§4 API → Task 5/6；§5 配置计费 → Task 1/2/7；§6 前端 → Task 7/8/9；§7 错误处理 → Task 4/5 的 400 分支；§8 测试 → 每个任务的 Step 1；§9 顺序 → 本计划顺序。
- 五条 Review Focus 分别落在：参考图校验（Task 4 `validateImageRequest`）、子模式能力（Task 4 + Task 2）、`size` 校验（Task 4）、单张下载失败（Task 4 `_FailingDownloadClient`）、超时不留半写文件（Task 4 计费与原子写测试）。
- `JobRunRecord` 在 Task 5 定义（图片/视频共用），Task 6 只加字段使用，不再改名。
