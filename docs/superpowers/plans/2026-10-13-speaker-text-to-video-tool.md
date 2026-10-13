# 方言配音主讲人 · 文生视频工具 (Recut v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有 Web 工具从「相册流水线（上传照片）」改造成「文生视频主讲人」：参数为时长 / 方言类型 / 主题文字，生成带卡通主讲人（左下角圆角卡牌）的方言口播视频，完成后展示下载链接。

**Architecture:** 保留壳（Flutter `lib/main.dart` 启动本地 Dart server + WebView 承载 React）。React 表单改为三参数；Dart server 用 JSON 文生视频 API 取代照片 multipart API；复用 `万相 3.0` 文生视频（`generateTextToVideo` + `t2vPrompt`），新增 ffmpeg 叠加步把卡通形象合成到成片左下角。生成前前端做费用确认。

**Tech Stack:** Dart 3.12（`lib/pipeline/**`、`lib/server/pipeline_server.dart`、`lib/server/api_router.dart` 纯 Dart；`lib/server/web_build_assets.dart` 与 `lib/main.dart` 可用 Flutter）、`package:http`（含 `http/testing.dart` MockClient）、本机 ffmpeg/ffprobe、React 19 + TypeScript + Vite。

**Spec:** `docs/superpowers/specs/2026-10-13-speaker-text-to-video-tool-design.md`

## Global Constraints

- `lib/pipeline/**` 与 `lib/server/pipeline_server.dart`、`lib/server/api_router.dart` 一律禁止 `import 'package:flutter/...'`（纯 Dart，可整体搬后端）。`lib/server/web_build_assets.dart` 与 `lib/main.dart` 是既有 Flutter 例外（资源物化）。
- 方言指令复用现有 `lib/pipeline/host.dart` 的 `t2vPrompt(prompt, dialect)`（追加「请用××话表达。」）；未知地区回落普通话。不得另造一套方言映射。
- 文生视频模型 = 配置 `t2v.model`（默认 `wan3.0-video`）；分辨率/宽高比/水印/种子/音频/poll 秒/超时全部取 `cfg.t2v*`，显式传入，不依赖服务端默认。
- 时长范围 **2–30 秒**；越界或非数字一律拒绝/钳制，绝不透传给 API。
- 主讲人叠加：卡通形象缩放至成片高度 **26%**，**左下角**，边距 = 画面宽/高的 **4%**，圆角；音轨保持（`-c:a copy`），时长不变。
- 密钥只走环境变量 `DASHSCOPE_API_KEY`；任何测试不得发真实网络请求、不得读真实密钥。
- 费用 = `时长 × cfg.t2vYuanPerSecond`（配置 `t2v.yuan_per_second`，默认 0.15 占位）；文案标注「预估，以实际账单为准」。前端确认前不 `POST /api/t2v`。
- 相册流水线（`lib/pipeline/**` 其余、`bin/conatus_host.dart`、相册相关测试）不得被改动或破坏；本计划只从本工具 server 摘除照片端点。
- 每任务结束执行 `dart analyze lib bin test` 零告警 + 相关测试通过。

## Review Focus

以下五类输入/条件 spec 隐含但最容易出问题，各自归属任务的测试必须钉住：

1. **时长为 0 / 负数 / 非数字 / > 30** → 预期：server 拒绝或钳制到 2–30，绝不把越界时长提交给万相（Task 4 校验测试）。
2. **主题文字为空/纯空白** → 预期：server 400 + 前端不提交；不生成空提示词（Task 4、Task 6）。
3. **缺 `DASHSCOPE_API_KEY`** → 预期：run 变 `failed` 且 `error` 为中文明示，进程不崩溃（Task 4）。
4. **主讲人素材缺失/不可读** → 预期：叠加步失败 → run `failed` 带 ffmpeg stderr，不挂起、不产出半成品下载（Task 3、Task 4）。
5. **下载一个不存在/未完成的 run** → 预期：`GET /api/t2v/:id/video` 返回 404 JSON，前端可读不崩溃（Task 4）。

---

### Task 1: 配置新增文生视频单价

**Files:**
- Modify: `lib/pipeline/config.dart`
- Modify: `pipeline_config.json`（本地，不入库）、`pipeline_config.example.json`
- Test: `test/pipeline/config_test.dart`

**Interfaces:**
- Consumes: 既有 `PipelineConfig` 构造与 `_section`/`_string` 等静态解析器。
- Produces: `PipelineConfig.t2vYuanPerSecond`（`double`，构造参数默认 `0.15`）；解析配置 `t2v.yuan_per_second`。

- [ ] **Step 1: 写失败测试**

在 `test/pipeline/config_test.dart` 增加：

```dart
test('t2v yuan_per_second parses, defaults to 0.15', () async {
  final file = File('${tmp.path}/cfg.json');
  file.writeAsStringSync('{"t2v": {"yuan_per_second": 0.2}}');
  final cfg = await PipelineConfig.load(file: file, env: const {});
  expect(cfg.t2vYuanPerSecond, 0.2);

  final bare = File('${tmp.path}/bare.json');
  bare.writeAsStringSync('{}');
  final dflt = await PipelineConfig.load(file: bare, env: const {});
  expect(dflt.t2vYuanPerSecond, 0.15);
});
```

（若该文件已有 `late Directory tmp;` 与 setUp，直接复用；否则按现有用例结构补。）

- [ ] **Step 2: 运行测试确认失败**

Run: `dart test test/pipeline/config_test.dart -r expanded`
Expected: 编译失败 / `t2vYuanPerSecond` 未定义。

- [ ] **Step 3: 实现**

在 `lib/pipeline/config.dart`：
- 构造函数加 `this.t2vYuanPerSecond = 0.15,`（放在 `t2v*` 组内）。
- 字段 `final double t2vYuanPerSecond;`。
- `load` 中 `t2vYuanPerSecond: _double(t2v, 'yuan_per_second', 0.15),`。
- 新增 `static double _double(Map<String, dynamic> map, String key, double fallback)`（`value is num ? value.toDouble() : fallback`）。

在 `pipeline_config.json` 与 `pipeline_config.example.json` 的 `t2v` 块加 `"yuan_per_second": 0.15`（example 若无 `t2v` 块则新建，并保留其余键）。

- [ ] **Step 4: 运行测试确认通过**

Run: `dart test test/pipeline/config_test.dart -r expanded`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/config.dart pipeline_config.example.json test/pipeline/config_test.dart
git commit -m "feat(config): add t2v per-second price"
```

---

### Task 2: ffmpeg 主讲人叠加参数 + 集成测试

**Files:**
- Modify: `lib/pipeline/ffmpeg.dart`
- Test: `test/pipeline/ffmpeg_test.dart`

**Interfaces:**
- Consumes: `runFfmpeg`（既有）。
- Produces: `List<String> overlayAvatarArgs({required File video, required File avatar, required File out})`。

- [ ] **Step 1: 写失败测试**

在 `test/pipeline/ffmpeg_test.dart` 的 args group 增加：

```dart
test('overlayAvatarArgs rounds + scales the avatar and keeps audio', () {
  final args = overlayAvatarArgs(
    video: File('/tmp/v.mp4'),
    avatar: File('/tmp/a.jpg'),
    out: File('/tmp/o.mp4'),
  );
  final joined = args.join(' ');
  expect(joined, contains('overlay'));
  expect(joined, contains('scale2ref'));
  expect(joined, contains('geq'));            // 圆角 alpha
  expect(args, containsAllInOrder(['-c:a', 'copy']));
  expect(joined, contains('libx264'));
  expect(joined, contains('yuv420p'));
  expect(joined, contains('[v]'));
  expect(args, containsAllInOrder(['-i', '/tmp/v.mp4']));
  expect(args, containsAllInOrder(['-i', '/tmp/a.jpg']));
  expect(args.last, '/tmp/o.mp4');
});
```

在 real-ffmpeg group 增加：

```dart
test('overlayAvatarArgs output keeps duration and an audio track', () async {
  final video = await makeClip('host3s.mp4'); // 640x360 + 440Hz sine
  final avatar = await makeImage('avatar.png', w: 512, h: 512);
  final out = File('${tmp.path}/overlaid.mp4');
  await runFfmpeg(overlayAvatarArgs(video: video, avatar: avatar, out: out));
  expect(await mediaDurationSeconds(out), closeTo(3.0, 0.3));
  final codecs = await probeCodecs(out);
  expect(codecs, contains('h264'));
  expect(codecs, contains('aac'));
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `dart test test/pipeline/ffmpeg_test.dart -r expanded`
Expected: `overlayAvatarArgs` 未定义。

- [ ] **Step 3: 实现 `overlayAvatarArgs`**

在 `lib/pipeline/ffmpeg.dart` 末尾新增。过滤链（`filter_complex`）表达式：

```
[1:v]format=rgba,geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(lt(hypot(max(0\,abs(X-W/2)-(W/2-W*0.1))\,max(0\,abs(Y-H/2)-(H/2-W*0.1)))\,W*0.1)\,255\,0)'[av];
[av][0:v]scale2ref=w='main_h*0.26':h='main_h*0.26'[av2][base];
[base][av2]overlay=x='main_w*0.04':y='main_h-overlay_h-main_h*0.04':format=auto[v]
```

（单行拼接亦可；`\,` 用于 geq 参数内的逗号转义。`W/H` 为素材原始尺寸，圆角半径 = 素材宽 10%，随缩放等比。）

参数列表：

```dart
[
  '-y',
  '-i', video.path,
  '-i', avatar.path,
  '-filter_complex', <上述表达式>,
  '-map', '[v]',
  '-map', '0:a?',
  '-c:v', 'libx264',
  '-pix_fmt', 'yuv420p',
  '-c:a', 'copy',
  '-shortest',
  out.path,
]
```

`0:a?` 让无音轨的输入也能跑通；`-shortest` 以视频长度封顶。

- [ ] **Step 4: 运行测试确认通过**

Run: `dart test test/pipeline/ffmpeg_test.dart -r expanded`
Expected: PASS（含真实 ffmpeg 集成用例）。若 geq 报错，按 ffmpeg stderr 调整表达式转义。

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/ffmpeg.dart test/pipeline/ffmpeg_test.dart
git commit -m "feat(ffmpeg): avatar overlay args (rounded card, bottom-left)"
```

---

### Task 3: 主讲人视频编排（生成 + 叠加）

**Files:**
- Create: `lib/pipeline/speaker_video.dart`
- Test: `test/pipeline/speaker_video_test.dart`

**Interfaces:**
- Consumes: `Wan30VideoClient`、`generateTextToVideo`（`text_to_video.dart`）、`t2vPrompt`（`host.dart`）、`runFfmpeg` + `overlayAvatarArgs`（Task 2）。
- Produces:
  - `const int t2vMinDurationS = 2;`、`const int t2vMaxDurationS = 30;`
  - `class SpeakerVideoResult { final String rawVideoPath; final String finalVideoPath; final int durationS; final String taskId; const SpeakerVideoResult({required ...}); }`
  - `Future<SpeakerVideoResult> generateSpeakerVideo({required Wan30VideoClient client, required String theme, required String dialect, required int durationS, required String contentId, required File avatar, String baseDir = 'pipeline_out/speaker', int pollSeconds = 15, int maxWaitMinutes = 10, Future<void> Function(Duration)? sleep, void Function(String)? onProgress, Future<void> Function({required File video, required File avatar, required File out})? overlay})`

编排：`prompt = t2vPrompt(theme, dialect)` → `generateTextToVideo(..., outFile: <baseDir>/<contentId>/raw.mp4)` → `overlay`（默认 `runFfmpeg(overlayAvatarArgs(...))`）→ `<baseDir>/<contentId>/video.mp4`。

- [ ] **Step 1: 写失败测试**

`test/pipeline/speaker_video_test.dart`：用 `MockClient` 返回 submit/poll/download（照抄 `test/pipeline/text_to_video_test.dart` 的 `_Mock` 思路），并**注入 `overlay`**（写空文件，避免真跑 ffmpeg 与真 mp4 字节）。断言：

```dart
test('appends dialect instruction and writes raw + final paths', () async {
  String? sentPrompt;
  // _Mock 捕获 POST body 的 input.prompt → sentPrompt
  final result = await generateSpeakerVideo(
    client: Wan30VideoClient(apiKey: 'k', client: mock.client, audio: true),
    theme: '河南美食', dialect: '河南', durationS: 5, contentId: 'run-1',
    avatar: File('${tmp.path}/avatar.jpg'),
    baseDir: tmp.path,
    sleep: (_) async {},
    overlay: ({required video, required avatar, required out}) async =>
        File(out.path).writeAsBytesSync(<int>[0]),
  );
  expect(sentPrompt, contains('河南美食'));
  expect(sentPrompt, contains('请用河南话表达。'));
  expect(result.rawVideoPath, endsWith('run-1/raw.mp4'));
  expect(result.finalVideoPath, endsWith('run-1/video.mp4'));
  expect(result.taskId, 't1');
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `dart test test/pipeline/speaker_video_test.dart -r expanded`
Expected: `speaker_video.dart` 未定义。

- [ ] **Step 3: 实现 `lib/pipeline/speaker_video.dart`**

新增类型与函数如上；`raw`/`final` 路径由 `baseDir` + `contentId` 拼接，写前 `Directory(parent).createSync(recursive: true)`。默认 `overlay` 走真实 ffmpeg。

- [ ] **Step 4: 运行测试确认通过**

Run: `dart test test/pipeline/speaker_video_test.dart -r expanded`
Expected: PASS。

- [ ] **Step 5: Commit**

```bash
git add lib/pipeline/speaker_video.dart test/pipeline/speaker_video_test.dart
git commit -m "feat(speaker): orchestrate t2v + avatar overlay"
```

---

### Task 4: Server 改为文生视频 API

**Files:**
- Modify: `lib/server/api_router.dart`、`lib/server/pipeline_server.dart`
- Test: `test/server/api_router_test.dart`、`test/server/pipeline_server_test.dart`

**Interfaces:**
- Consumes: `SpeakerVideoResult` / `t2vMinDurationS` / `t2vMaxDurationS`（Task 3）、`Wan30VideoClient`、`cfg.t2v*`、`cfg.requireApiKey()`、`_uniqueDialects`。
- Produces:
  - `enum ApiRoute { dialects, createT2v, getT2v, getT2vVideo, unknown }`
  - `typedef SpeakerVideoRunner = Future<SpeakerVideoResult> Function({required String theme, required String dialect, required int durationS, required String contentId, required void Function(String) onProgress});`
  - `PipelineServer({required cfg, required staticDir, int port, SpeakerVideoRunner? speakerRunner, File? avatarImage})`

路由：`GET /api/dialects` → dialects；`POST /api/t2v` → createT2v；`GET /api/t2v/<id>` → getT2v；`GET /api/t2v/<id>/video` → getT2vVideo（`/video` 优先于裸 `:id`）。删除 `createRun/getRun/getRunVideo/getRunSrt` 与 multipart/照片处理代码。

- [ ] **Step 1: 写失败测试**

`test/server/api_router_test.dart` 重写为：

```dart
test('t2v routes, video wins over bare id', () {
  expect(apiRouteFor('GET', '/api/dialects'), ApiRoute.dialects);
  expect(apiRouteFor('POST', '/api/t2v'), ApiRoute.createT2v);
  expect(apiRouteFor('GET', '/api/t2v/run-1/video'), ApiRoute.getT2vVideo);
  expect(apiRouteFor('GET', '/api/t2v/run-1'), ApiRoute.getT2v);
  expect(apiRouteFor('POST', '/api/t2v/run-1/video'), ApiRoute.unknown);
  expect(apiRouteFor('GET', '/api/runs'), ApiRoute.unknown);
  expect(apiRouteFor('GET', '/api/nope'), ApiRoute.unknown);
});
```

`test/server/pipeline_server_test.dart` 保留静态服务用例，新增（注入假 runner，写一份临时 `final.mp4`）：

```dart
test('POST /api/t2v runs and serves the mp4', () async {
  // 假 runner 写 out 文件并返回 SpeakerVideoResult(finalVideoPath: ...)
  final id = (await _postJson(port, '/api/t2v',
      {'duration': 5, 'dialect': 'henan', 'theme': '河南美食'}))['id'];
  // 轮询 GET /api/t2v/<id> 直到 completed
  // GET /api/t2v/<id>/video → 200 + content-disposition attachment
});

test('rejects empty theme and out-of-range duration', () async {
  expect((await _postJson(port, '/api/t2v', {'duration': 5, 'dialect': 'henan', 'theme': ' '})).status, 400);
  expect((await _postJson(port, '/api/t2v', {'duration': 99, 'dialect': 'henan', 'theme': 'x'})).status, 400);
});

test('download of unknown run is 404 JSON', () async {
  final res = await _get(port, '/api/t2v/nope/video');
  expect(res.status, 404);
  expect(res.body, contains('"error"'));
});
```

（`_postJson` 辅助：`HttpClient.post` + `Content-Type: application/json` + `jsonEncode`，返回 `(status, Map/body)`。）

- [ ] **Step 2: 运行测试确认失败**

Run: `dart test test/server/ -r expanded`
Expected: 编译失败（旧枚举/路由不匹配）。

- [ ] **Step 3: 实现**

- `api_router.dart`：替换枚举与 `apiRouteFor`（`/api/t2v` 前缀，`/video` 优先）。
- `pipeline_server.dart`：
  - 删除 multipart / `_saveUploadedPhoto` / 照片字段。
  - `_createT2v`：`Content-Type` 须含 `application/json`；读 body → `jsonDecode`；取 `duration`（int、`[t2vMinDurationS, t2vMaxDurationS]` 否则 400）、`dialect`（非空否则 400）、`theme`（`trim()` 非空否则 400）。生成 `_newRunId()`，建 `RunRecord`，`unawaited(_runT2v(...))`，返回 `202 {id}`。
  - `_runT2v`：调用 `speakerRunner ?? _defaultRunner`；`onProgress` 追加到 `record.logs`；成功 → `status='completed'`、`record.videoPath = result.finalVideoPath`；`on PipelineError` / `on ConfigException` / 其它 → `failed` + `error`（缺 key 时 `ConfigException.message` 明示）。
  - `_defaultRunner`：`avatarImage == null` 时抛 `PipelineError`（“主讲人素材未配置”）；否则按 `cfg.t2v*` 建 `Wan30VideoClient` 调 `generateSpeakerVideo`。
  - `_getDialects`：加 `'t2v': {'yuan_per_second': cfg.t2vYuanPerSecond, 'duration_min': t2vMinDurationS, 'duration_max': t2vMaxDurationS}`。
  - `_getT2v` / `_getT2vVideo`：404 JSON；文件存在校验；`Content-Disposition: attachment; filename="video.mp4"`。
- 保留 `_serveStatic`/`_serveFile`/`_sendJson`/`_newRunId`。

- [ ] **Step 4: 运行测试确认通过**

Run: `dart test test/server/ -r expanded && dart analyze lib bin test`
Expected: PASS、零告警。

- [ ] **Step 5: Commit**

```bash
git add lib/server/api_router.dart lib/server/pipeline_server.dart test/server/
git commit -m "feat(server): text-to-video API replaces photo run API"
```

---

### Task 5: 素材物化与服务器装配

**Files:**
- Modify: `lib/server/web_build_assets.dart`、`lib/server/start.dart`、`lib/main.dart`
- Test: `test/server/web_build_assets_test.dart`

**Interfaces:**
- Consumes: `AssetBundle`（`package:flutter/services.dart`）。
- Produces:
  - `Future<File> materializeAssetFile(AssetBundle bundle, {required String key, required String suffix})`（把打包资源写成临时文件并返回）。
  - `Future<String> startPipelineServer({int port = 18080, String? staticDir, File? avatarImage})`（`avatarImage` 透传给 `PipelineServer`）。

- [ ] **Step 1: 写失败测试（flutter_test）**

在 `test/server/web_build_assets_test.dart` 增加：

```dart
test('materializeAssetFile writes the avatar bytes', () async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  if (!manifest.listAssets().contains('assets/images/speaker_avatar.jpg')) {
    markTestSkipped('avatar asset not bundled');
    return;
  }
  final file = await materializeAssetFile(rootBundle,
      key: 'assets/images/speaker_avatar.jpg', suffix: '.jpg');
  addTearDown(() => file.deleteSync());
  expect(file.existsSync(), isTrue);
  expect(file.lengthSync(), greaterThan(0));
});
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test test/server/web_build_assets_test.dart -r expanded`
Expected: `materializeAssetFile` 未定义。

- [ ] **Step 3: 实现**

- `web_build_assets.dart`：加 `materializeAssetFile`（`bundle.load(key)` → 写 `Directory.systemTemp.createTemp` 目录下 `speaker<suffix>`）。
- `start.dart`：`startPipelineServer` 加 `File? avatarImage`，构造 `PipelineServer(..., avatarImage: avatarImage)`。
- `main.dart`：`final avatar = await materializeAssetFile(rootBundle, key: 'assets/images/speaker_avatar.jpg', suffix: '.jpg');` 传入 `startPipelineServer(staticDir: staticDir.path, avatarImage: avatar)`。

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test test/server/web_build_assets_test.dart -r expanded`
Expected: PASS（或按提示 skip）。

- [ ] **Step 5: Commit**

```bash
git add lib/server/web_build_assets.dart lib/server/start.dart lib/main.dart test/server/web_build_assets_test.dart
git commit -m "feat(server): pass bundled avatar image to the pipeline server"
```

---

### Task 6: React 前端改为三参数 + 下载链接

**Files:**
- Modify: `frontend/src/App.tsx`、`frontend/src/App.css`

**Interfaces:**
- Consumes: `GET /api/dialects` → `{dialects: {code,label,instruction}[], t2v: {yuan_per_second, duration_min, duration_max}}`；`POST /api/t2v` `{duration, dialect, theme}` → `{id}`；`GET /api/t2v/:id` → `{status, logs, error?, video_path?}`；`GET /api/t2v/:id/video`。

- [ ] **Step 1: 实现 UI**

`App.tsx`：
- 启动拉 `/api/dialects`，存 `dialects` 与 `t2v`（单价/上下限）。
- 表单：时长 slider（`min=t2v.duration_min`，`max=t2v.duration_max`，默认 5）、方言 `select`、主题 `textarea`。
- 点「生成」：`store` 估算 `duration * t2v.yuan_per_second` → `window.confirm('预估费用 ¥X.XX（以实际账单为准），确认生成？')`；取消则不提交。
- 确认后 `POST /api/t2v`（`Content-Type: application/json`），轮询 `GET /api/t2v/:id`（1s），展示 `status`/`logs`/`error`。
- `completed`：内联 `<video controls src={`/api/t2v/${id}/video`}>` + 下载链接 `<a href=... download>下载视频</a>`。
- 提交前校验：主题 `trim()` 非空。

`App.css`：删掉照片/复选框相关块，补 slider/textarea/视频预览样式（沿用现有卡片风格）。

- [ ] **Step 2: 构建 + 静态检查**

Run: `cd frontend && npm run lint && npm run build`
Expected: lint 无错误；`tsc -b && vite build` 成功，产物写入 `../web_build/`。

- [ ] **Step 3: 手动验证（本地）**

Run: 启动 app（`flutter run -d macos` 或 `dart run lib/server/...` 开发路径）。填三参数 → 确认弹窗 → 观察日志 → 完成后下载链接可用。
Expected: 表单三参数可用；确认前不发请求；完成后视频可播放/下载。（真实生成需 `DASHSCOPE_API_KEY`，无 key 时展示明示错误。）

- [ ] **Step 4: 提交 web 构建产物与源码**

```bash
git add frontend/src/App.tsx frontend/src/App.css web_build/
git commit -m "feat(web): text-to-video form with cost confirm and download link"
```

---

## Self-Review

- **Spec coverage:** §3 参数/UI → Task 6；§4 API → Task 4；§5.1 生成 → Task 3；§5.2 叠加 → Task 2/3；§6 费用 → Task 1/4/6；§7 错误 → Task 4（Review Focus 3/4/5）；§8 测试 → 各任务；§9 文件 → 全覆盖；§10 假设 → 已在 Constraints 固化。
- **Step scan:** 每步单一动作、可验证；代码块只给签名/断言/关键表达式，正文留给实现者。
- **Type consistency:** `SpeakerVideoResult.finalVideoPath`（Task 3）↔ server `record.videoPath`（Task 4）↔ 前端 `video_path`；`t2vMinDurationS/Max`（Task 3）↔ server 校验（Task 4）↔ 前端上下限（Task 6）；`overlayAvatarArgs`/`materializeAssetFile` 名称前后一致。
- **Review Focus:** 5 项各有归属测试（Task 4 ×4：时长、空主题、缺 key、404；Task 3 ×1：素材不可读）。
- **Proportion:** 计划 ≈ spec 体量，未逐行抄代码。
