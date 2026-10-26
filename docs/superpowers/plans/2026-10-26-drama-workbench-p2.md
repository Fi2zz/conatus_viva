# 短剧工作台 P2（定妆 + 画面）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 先完成 P1 验收并落地设置/密钥入口，再把短剧「定妆」与「画面」两工序接成真实可运行的编排：首帧、片段、缓存、重跑、降级、批量与费用闸门。

**Architecture:** 纯 Dart 层负责 hash、估算、计划单视图与顺序执行器；媒体调用藏在可注入的 `DramaMediaGateway` 后，测试用 fake，真实实现复用现有图片/视频客户端与 ffmpeg。`DramaRunner` 逐项持久化 `state.json`，`DramaRunRegistry` 只保存内存 run 状态；HTTP 只做校验、估算、启动与读取。密钥从 macOS Keychain（Windows 回退 0600 文件）读取，设置页写入，不读 `.env`。

**Tech Stack:** Dart 3 / Flutter（仅外壳与原生通道）/ React 19 + TypeScript + Vite / DashScope 图片与 i2v 客户端 / ffmpeg + ffprobe。

**Spec:** `docs/superpowers/specs/2026-10-23-drama-workbench-design.md`（本计划同时修订：设置入口、`estimate` 新请求格式、移除 `.env`、P2 产物路径）。

## Global Constraints

- `lib/pipeline/**`、`lib/server/**` 禁止 import `package:flutter/...`；原生 Keychain 只在 `lib/platform_secret_store.dart` 与 `macos/Runner/` 使用。
- 单价只来自 `pipeline_config.json` 与 `lib/pipeline/generation_models.dart`；新代码不得硬编码价格。
- `state.json` 幂等与「产物存在 + hash 一致即跳过」契约不可绕过；`force` 是唯一显式重跑入口。
- 视频失败不自动重试；图片按成功张数计费；本地 ffmpeg 失败零费用可重试。
- 所有 HTTP 只绑 `InternetAddress.loopbackIPv4`；资产端点禁止目录列表与路径逃逸。
- 密钥只来自设置入口：macOS Keychain，其他平台用户目录 0600 文件；**不读取 `.env`**；进程环境仅 CLI/CI 显式注入；任何日志、响应、异常不得回显密钥。
- 前端只经本地 HTTP 访问后端；不得直连厂商 API；不得使用 `window.confirm/alert`。
- 前端改动必须 `make web` 并提交 `web_build/`。
- 测试默认离线；唯一的真实调用是任务 16 的手工 smoke，必须显式开关与费用确认。
- 不提交 `pipeline_out/`、密钥、临时 smoke 产物。

## Review Focus

1. **未配置密钥**：设置页显示「未配置」，所有付费按钮在发请求前给出中文提示，不出现 500、不发起网络调用。
2. **路径逃逸**：`GET .../assets/../...`、绝对路径、含反斜杠的路径必须 400，目录不能被列出。
3. **并发重复扣费**：同一集连续点击或双标签页第二次 run 必须 409 `episode_busy`，不得创建第二个 run。
4. **批量部分失败**：一条镜头失败不抹掉已成功产物；重跑只补失败项，已成功项不再扣费。
5. **失效传播**：改分镜表或重新生成定妆后，依赖的 frame/clip 必须显示 `stale`，而不是继续复用旧文件。
6. **预算**：总预算或 i2v 预算不足时，run 必须在任何付费调用前 409 `budget_exceeded`。
7. **取消**：取消只阻止后续项；在途付费项允许完成并持久化，不谎报已退款。

---

## Phase A：P1 验收（先收尾，不改功能）

### Task 1: 记录 P1 验收结果并勾选清单

**Files:**
- Modify: `docs/superpowers/plans/2026-10-23-drama-workbench-p1.md:1804-1814`
- Modify: `docs/superpowers/specs/2026-10-23-drama-workbench-design.md:732-740`
- Create: `docs/superpowers/plans/2026-10-26-p1-acceptance.md`

**Interfaces:**
- Consumes: 上周已提交的 P1 实现。
- Produces: 一份带命令输出的验收记录；两份文档的 checkbox 全部勾选。

- [ ] **Step 1: 跑基线命令并记录**

Run:

```bash
make analyze
make test-dart
make test-web
cd frontend && npm run build
```

Expected: 全部退出码 0；把每条命令的结果摘要（通过/失败、测试数量）写进 `2026-10-26-p1-acceptance.md`，不要粘贴密钥或完整环境。

- [ ] **Step 2: 验证 `web_build` 与源码一致**

Run:

```bash
make web
git status --short web_build
```

Expected: `web_build` 无改动；若有改动，说明是构建环境差异，并把生成物一并提交。

- [ ] **Step 3: 逐项核对 P1 验收清单**

对照 `2026-10-23-drama-workbench-p1.md` 的 9 条验收清单，在验收记录里逐条写「证据（测试名 / 文件 / 手工检查）」；空态、未接入诊断、`run` 501、费用闸门以现有测试和代码路径为证据。发现红项时停止，不勾选，先报告。

- [ ] **Step 4: 勾选并提交**

把 P1 计划与设计文档里已完成项改成 `- [x]`，提交：

```bash
git add docs/superpowers/plans/2026-10-23-drama-workbench-p1.md \
  docs/superpowers/specs/2026-10-23-drama-workbench-design.md \
  docs/superpowers/plans/2026-10-26-p1-acceptance.md
git commit -m "docs(short-drama): P1 验收记录与清单勾选"
```

---

## Phase B：设置 / 密钥入口（移除 `.env`）

### Task 2: `PipelineConfig` 支持运行时密钥与动态工作空间

**Files:**
- Modify: `lib/pipeline/config.dart:21-235`
- Test: `test/pipeline/config_test.dart`
- Modify: `test/pipeline/host_smoke_test.dart:9`, `test/server/pipeline_server_test.dart:11`, `test/server/image_api_test.dart:12`, `test/server/drama_api_test.dart:13`, `test/server/short_drama_api_test.dart:8`, `test/server/video_api_test.dart:9`

**Interfaces:**
- Produces:
  - `PipelineConfig({..., String? baseUrl, Map<String, String>? env})`（不再是 `const`）
  - `String get effectiveWorkspaceId`
  - `String get workspaceId`
  - `String get baseUrl`
  - `String get apiHost`
  - `bool get hasApiKey`
  - `bool get hasOss`
  - `void updateSecrets(Map<String, String?> values)`（null 或空串 = 清除）
- Consumes: 现有 `requireApiKey()`、OSS getter。

- [ ] **Step 1: 写失败测试**

在 `test/pipeline/config_test.dart` 新增：

```dart
test('updateSecrets overrides key and workspace host immediately', () async {
  final cfg = await PipelineConfig.load(file: await writeConfig(tmp, '{}'), env: <String, String>{});
  expect(cfg.hasApiKey, isFalse);
  cfg.updateSecrets(<String, String?>{
    'DASHSCOPE_API_KEY': 'sk-test',
    'DASHSCOPE_WORKSPACE_ID': 'ws-1',
  });
  expect(cfg.requireApiKey(), 'sk-test');
  expect(cfg.workspaceId, 'ws-1');
  expect(cfg.apiHost, 'https://ws-1.cn-beijing.maas.aliyuncs.com');
  expect(cfg.baseUrl, 'https://ws-1.cn-beijing.maas.aliyuncs.com/compatible-mode/v1');
});

test('empty secret clears the override', () async {
  final cfg = await PipelineConfig.load(file: await writeConfig(tmp, '{}'), env: <String, String>{});
  cfg.updateSecrets(<String, String?>{'DASHSCOPE_API_KEY': 'sk-test'});
  cfg.updateSecrets(<String, String?>{'DASHSCOPE_API_KEY': ''});
  expect(cfg.hasApiKey, isFalse);
  expect(cfg.requireApiKey, throwsA(isA<ConfigException>()));
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/config_test.dart`
Expected: FAIL，`updateSecrets` / `hasApiKey` 不存在。

- [ ] **Step 3: 实现**

- 构造函数去掉 `const`，`_env = Map<String, String>.of(env ?? const {})`。
- 把 `workspaceId` / `baseUrl` 改成 getter：保存 `_configuredWorkspaceId` / `_configuredBaseUrl`；`effectiveWorkspaceId` 先读 `_env['DASHSCOPE_WORKSPACE_ID']`。
- `load` 里 `base_url` 为空时传 `null`，让 getter 从 `apiHost` 派生。
- 新增 `hasApiKey`、`hasOss`、`updateSecrets`。
- 删除所有测试文件里 `const PipelineConfig(` 的 `const`。

- [ ] **Step 4: 跑测试**

Run: `dart test test/pipeline/config_test.dart test/pipeline/host_smoke_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/config.dart test/pipeline/config_test.dart test/pipeline/host_smoke_test.dart \
  test/server/pipeline_server_test.dart test/server/image_api_test.dart test/server/drama_api_test.dart \
  test/server/short_drama_api_test.dart test/server/video_api_test.dart
git commit -m "feat(config): 支持运行时密钥覆盖与动态工作空间主机"
```

### Task 3: `SecretStore`、设置 API 与启动加载

**Files:**
- Create: `lib/server/settings.dart`
- Create: `lib/server/settings_controller.dart`
- Modify: `lib/server/api_router.dart:28-67`
- Modify: `lib/server/pipeline_server.dart:200-340`
- Test: `test/server/settings_api_test.dart`
- Test: `test/server/api_router_test.dart`

**Interfaces:**
- Produces:
  - `abstract interface class SecretStore { Future<Map<String, String>> readAll(); Future<void> writeAll(Map<String, String> values); }`
  - `class MemorySecretStore implements SecretStore`
  - `class FileSecretStore implements SecretStore`（`FileSecretStore(this.file)`）
  - `class SettingsController { SettingsController({required PipelineConfig cfg, required SecretStore? store}); Future<void> handle(HttpRequest req); }`
  - `ApiRoute.settings`
- Consumes: Task 2 的 `cfg.updateSecrets` / `hasApiKey` / `hasOss`。

- [ ] **Step 1: 写失败测试**

`test/server/settings_api_test.dart` 覆盖：

```dart
test('PUT saves secrets, GET never echoes them, and config is live', () async {
  final store = MemorySecretStore();
  final cfg = await PipelineConfig.load(file: await _writeCfg(tempDir), env: const <String, String>{});
  final server = PipelineServer(cfg: cfg, staticDir: tempDir, secretStore: store);
  await server.start();
  final put = await _send(port, 'PUT', '/api/settings', {
    'dashscope_api_key': 'sk-live',
    'workspace_id': 'ws-1',
  });
  expect(put.status, 200);
  expect(put.body, isNot(contains('sk-live')));
  expect(cfg.requireApiKey(), 'sk-live');
  expect(cfg.apiHost, contains('ws-1'));
  final get = await _send(port, 'GET', '/api/settings');
  expect(get.body, isNot(contains('sk-live')));
  expect((jsonDecode(get.body) as Map)['dashscope_configured'], isTrue);
});

test('empty value clears and malformed body is 400', () async {
  expect((await _send(port, 'PUT', '/api/settings', {'dashscope_api_key': 'sk-live'})).status, 200);
  expect((await _send(port, 'PUT', '/api/settings', {'dashscope_api_key': ''})).status, 200);
  expect(cfg.hasApiKey, isFalse);
  expect((await _send(port, 'PUT', '/api/settings', {'workspace_id': 42})).status, 400);
});
```

`test/server/api_router_test.dart` 增加：`GET/PUT /api/settings` → `ApiRoute.settings`。

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/server/settings_api_test.dart test/server/api_router_test.dart`
Expected: FAIL，路由/类型不存在。

- [ ] **Step 3: 实现存储与 API**

- `FileSecretStore` 用原子写（`.tmp` + rename），文件不存在返回空 map；父目录自动创建；测试可传临时文件。
- `GET /api/settings` 返回 `{dashscope_configured, workspace_id, oss_configured}`，不返回任何密钥片段。
- `PUT /api/settings` 接受 `dashscope_api_key`、`workspace_id`、`oss_access_key_id`、`oss_access_key_secret`；非字符串 400 `invalid_body`；省略 = 不变；空串 = 清除。
- `SettingsController.handle` 先校验 `req.uri.path == '/api/settings'`。
- `PipelineServer` 增加 `SecretStore? secretStore`；`start()` 在 bind 前 `readAll()` 并 `cfg.updateSecrets`；新增 `_settings` 字段并接 `ApiRoute.settings`。
- `store == null` 时 `PUT` 返回 501 `secrets_unavailable`，`GET` 仍可读当前 cfg。

- [ ] **Step 4: 跑测试**

Run: `dart test test/server/settings_api_test.dart test/server/api_router_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/server/settings.dart lib/server/settings_controller.dart lib/server/api_router.dart \
  lib/server/pipeline_server.dart test/server/settings_api_test.dart test/server/api_router_test.dart
git commit -m "feat(server): 设置 API 与密钥存储抽象"
```

### Task 4: macOS Keychain 通道、平台存储与移除 `.env`

**Files:**
- Create: `lib/platform_secret_store.dart`
- Modify: `macos/Runner/MainFlutterWindow.swift:12-32`
- Modify: `lib/main.dart:1-41`
- Modify: `lib/server/start.dart:19-80`
- Modify: `lib/pipeline/config.dart`（如需调整 `load` 的 env 默认）
- Delete: `lib/speaker_tool/speaker_env.dart`
- Delete: `.env.example`
- Modify: `pubspec.yaml:45`、`pubspec.lock`
- Modify: `Makefile:19-23`

**Interfaces:**
- Produces:
  - `class PlatformSecretStore implements SecretStore`（macOS → `MethodChannel('viva/secrets')`；其他平台 → `FileSecretStore`）
  - `startPipelineServer({..., SecretStore? secretStore})`（删除 `env` 参数）
- Consumes: Task 3 的 `SecretStore` / `PipelineServer(secretStore:)`。

- [ ] **Step 1: 写原生通道与 Dart 平台存储**

Swift 在 `MainFlutterWindow.awakeFromNib` 里注册 `viva/secrets`：

```swift
private func registerSecrets(_ controller: FlutterViewController) {
  let channel = FlutterMethodChannel(
    name: "viva/secrets",
    binaryMessenger: controller.engine.binaryMessenger
  )
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "readAll": result(Self.readAllSecrets())
    case "writeAll":
      guard let values = call.arguments as? [String: String] else {
        result(FlutterError(code: "invalid_args", message: "expected map", details: nil))
        return
      }
      do { try Self.writeAllSecrets(values); result(nil) }
      catch { result(FlutterError(code: "keychain", message: "\(error)", details: nil)) }
    default: result(FlutterMethodNotImplemented)
    }
  }
}
```

Keychain 常量：`service = "com.conatusviva.secrets"`，accounts 固定四个；`readAllSecrets` 用 `SecItemCopyMatching`，`writeAllSecrets` 空串删除、否则 `SecItemUpdate` / `SecItemAdd`；不打印值。

`lib/platform_secret_store.dart`：

```dart
class PlatformSecretStore implements SecretStore {
  static const MethodChannel _channel = MethodChannel('viva/secrets');
  @override
  Future<Map<String, String>> readAll() async {
    if (Platform.isMacOS) {
      final map = await _channel.invokeMapMethod<String, String>('readAll');
      return map ?? <String, String>{};
    }
    return _fileStore().readAll();
  }
  @override
  Future<void> writeAll(Map<String, String> values) async {
    if (Platform.isMacOS) {
      await _channel.invokeMethod<void>('writeAll', values);
      return;
    }
    await _fileStore().writeAll(values);
  }
  FileSecretStore _fileStore() => FileSecretStore(_fallbackFile());
}
```

`_fallbackFile()`：macOS 不会走到；Windows 用 `%APPDATA%/Viva/secrets.json`，其他用 `$HOME/.viva/secrets.json`；写入后 `chmod 600`（非 Windows）。

- [ ] **Step 2: 接线启动并移除 `.env`**

- `main.dart` 删除 `flutter_dotenv` import 与 `_resolveEnv`；创建 `PlatformSecretStore()`，传给 `startPipelineServer(secretStore: ...)`。
- `start.dart` 删除 `env` 参数；`_loadConfig()` 用 `env: const {}`（桌面端不再读进程环境或 `.env`）；`PipelineServer(..., secretStore: secretStore)`。
- `pubspec.yaml` 删除 `flutter_dotenv`，跑 `flutter pub get` 更新 lock。
- 删除 `lib/speaker_tool/speaker_env.dart` 与 `.env.example`。
- `Makefile setup` 只复制 `pipeline_config.json`，帮助文案删掉 `.env`。

- [ ] **Step 3: 编译与离线测试**

Run:

```bash
flutter pub get
make analyze
make test-dart
```

Expected: 零告警，Dart 测试全绿；不出现 `flutter_dotenv` 引用。

- [ ] **Step 4: macOS 手工验证 Keychain**

Run: `make run`，在设置页填入测试 key，保存后关闭再打开应用；确认设置页仍显示「已配置」，且 `security find-generic-password -s com.conatusviva.secrets -a DASHSCOPE_API_KEY -w` 能取到值（不要把输出贴进日志）。未完成 Task 5 前先跳过 UI 步骤，只验证通道可调用。

- [ ] **Step 5: 提交**

```bash
git add lib/platform_secret_store.dart macos/Runner/MainFlutterWindow.swift lib/main.dart \
  lib/server/start.dart pubspec.yaml pubspec.lock Makefile
git add -u lib/speaker_tool/speaker_env.dart .env.example
git commit -m "feat(settings): macOS Keychain 存储并移除 .env 读取"
```

### Task 5: 设置页与文档清理

**Files:**
- Create: `frontend/src/settings/api.ts`
- Create: `frontend/src/settings/settings.ts`
- Create: `frontend/src/settings/SettingsDialog.tsx`
- Create: `frontend/src/settings/Settings.css`
- Modify: `frontend/src/App.tsx`
- Test: `frontend/src/settings/settings.test.tsx`
- Modify: `README.md:18,122-124,184`
- Modify: `AGENTS.md:29,51,63,158`

**Interfaces:**
- Produces:
  - `SettingsStatus { dashscope_configured: boolean; workspace_id: string; oss_configured: boolean }`
  - `settingsApi.get(): Promise<SettingsStatus>`
  - `settingsApi.save(input: SettingsInput): Promise<SettingsStatus>`
  - `<SettingsDialog onClose={() => void} initialStatus?: SettingsStatus />`
- Consumes: Task 3 的 `/api/settings`。

- [ ] **Step 1: 写失败测试**

`settings.test.tsx` 用 `renderToString`：

```tsx
it('renders unconfigured status and never renders a secret value', () => {
  const html = renderToString(
    <SettingsDialog
      initialStatus={{ dashscope_configured: false, workspace_id: '', oss_configured: false }}
      onClose={() => {}}
    />,
  );
  expect(html).toContain('未配置');
  expect(html).not.toContain('sk-');
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd frontend && npx vitest run src/settings/settings.test.tsx`
Expected: FAIL，组件不存在。

- [ ] **Step 3: 实现设置弹窗与入口**

- `SettingsDialog`：API Key 用 `type="password"`；Workspace ID 文本框；OSS 折叠区；保存/清除按钮；加载 `GET /api/settings`；保存后显示「已保存」，不显示密钥。
- `App.tsx` 增加固定右上角「设置」按钮与 `settingsOpen` 状态；空态/工作台都能打开。
- 样式放 `Settings.css`，不引入新依赖；不使用原生对话框。

- [ ] **Step 4: 更新文档**

- README：`make setup` 只建 `pipeline_config.json`；密钥改成「打开应用 → 设置 → 填 API Key」；删除 `.env` 段落。
- AGENTS：密钥约束改为 Keychain / 0600 文件、不读 `.env`；`make setup` 文案同步；提交检查清单把 `.env` 改成「密钥文件」。

- [ ] **Step 5: 测试、构建、提交**

Run:

```bash
cd frontend && npm test && npm run lint && npm run check:dialogs && npm run build
cd .. && make web
git status --short web_build
```

Expected: 全绿，`web_build` 有更新。

```bash
git add frontend/src/settings frontend/src/App.tsx frontend/src/App.css web_build README.md AGENTS.md
git commit -m "feat(web): 设置页录入百炼与 OSS 密钥"
```

---

## Phase C：P2 后端

### Task 6: hash、计划单视图与状态增量方法

**Files:**
- Create: `lib/pipeline/drama/hashes.dart`
- Create: `lib/pipeline/drama/plan_view.dart`
- Modify: `lib/pipeline/drama/state.dart:181-333`
- Modify: `lib/pipeline/drama/series.dart:238-414`
- Modify: `lib/pipeline/drama/store.dart:193-210`
- Test: `test/pipeline/drama/hashes_test.dart`
- Test: `test/pipeline/drama/plan_view_test.dart`
- Test: `test/pipeline/drama/state_test.dart`（新建）

**Interfaces:**
- Produces:
  - `String dramaCastHash({required DramaCastMember member, required String model, required String size})`
  - `String dramaFrameHash({required Shot shot, required String? castAvatarHash, required String model, required String size})`
  - `String dramaClipHash({required Shot shot, required String frameHash, required String route, required String model, required String resolution, required int i2vSeconds})`
  - `class DramaPlanView { DramaPlanView(Map<String, Object?> json); ShotRoute routeFor(String shotId); int i2vSecondsFor(String shotId); double durationFor(String shotId); }`
  - `DramaEpisodeState.withShot(String shotId, DramaShotState shotState)`
  - `DramaEpisodeState.withActualYuan(double actual)`
  - `DramaEpisodeState.withActiveRun(String? runId)`
  - `DramaEpisodeState.withWarnings(List<String> warnings)`
  - `DramaSeries.withCastMember(DramaCastMember member)`
  - `DramaStore.seriesAssetFile(String seriesId, String relativePath)`
- Consumes: `dramaHash`、`Shot`、`ShotRoute`。

- [ ] **Step 1: 写 hash 与 plan 失败测试**

```dart
test('frame hash changes when cast avatar or visual changes', () {
  final base = dramaFrameHash(shot: shot, castAvatarHash: 'sha256:a', model: 'wan2.7-image', size: '1K');
  expect(base, isNot(dramaFrameHash(shot: shot.copyWith(visual: '新画面'), castAvatarHash: 'sha256:a', model: 'wan2.7-image', size: '1K')));
  expect(base, isNot(dramaFrameHash(shot: shot, castAvatarHash: 'sha256:b', model: 'wan2.7-image', size: '1K')));
});

test('plan view reads route and i2v seconds', () {
  final view = DramaPlanView({'shots': [{'shot_id': 's01', 'route': 'i2v', 'i2v_seconds': 3, 'duration_s': 3.2}]});
  expect(view.routeFor('s01'), ShotRoute.i2v);
  expect(view.i2vSecondsFor('s01'), 3);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/drama/hashes_test.dart test/pipeline/drama/plan_view_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现**

- Hash 输入只含影响画面的字段：cast = name/description/model/size；frame = visual（空时用 line）+ framing + kind + speaker + castAvatarHash + model + size；clip = frameHash + motion + route + model + resolution + i2vSeconds。
- `DramaPlanView` 只读 `plan['shots']`；未知 shot 返回 `ShotRoute.micro`、0 秒、2.0 秒。
- 状态/剧模型加增量方法，保持所有字段复制。
- `seriesAssetFile` 与 `assetFile` 同样的逃逸校验，根目录是 `seriesDir(seriesId)`。

- [ ] **Step 4: 跑测试**

Run: `dart test test/pipeline/drama/hashes_test.dart test/pipeline/drama/plan_view_test.dart test/pipeline/drama/state_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/hashes.dart lib/pipeline/drama/plan_view.dart lib/pipeline/drama/state.dart \
  lib/pipeline/drama/series.dart lib/pipeline/drama/store.dart test/pipeline/drama/hashes_test.dart \
  test/pipeline/drama/plan_view_test.dart test/pipeline/drama/state_test.dart
git commit -m "feat(short-drama): 产物 hash、计划单视图与状态增量方法"
```

### Task 7: 新格式估算（cast/frame）与定价注入

**Files:**
- Create: `lib/pipeline/drama/pricing.dart`
- Create: `lib/pipeline/drama/run_target.dart`
- Modify: `lib/pipeline/drama/cost.dart:1-171`
- Modify: `lib/pipeline/drama/controller.dart:26-93,387-412`
- Modify: `lib/server/pipeline_server.dart:200-240`
- Test: `test/pipeline/drama/cost_test.dart`
- Test: `test/server/drama_api_test.dart`

**Interfaces:**
- Produces:
  - `typedef ImageUnitPrice = double Function(String model, String tier);`
  - `typedef VideoUnitPrice = double Function(String model, String resolution);`
  - `class DramaPricing { const DramaPricing({required this.i2vYuanPerSecond, required this.imagePrice, required this.videoPrice}); final double i2vYuanPerSecond; final ImageUnitPrice imagePrice; final VideoUnitPrice videoPrice; }`
  - `enum DramaRunTarget { frame, clip, all }`（文件 `lib/pipeline/drama/run_target.dart`）
  - `enum DramaEstimateStep { story, storyboard, cast, frame }`
  - `class DramaEstimateRequest { const DramaEstimateRequest({required this.step, this.castIds = const [], this.shotIds = const [], this.target = DramaRunTarget.all, this.force = false}); }`
  - `DramaEstimateRequest parseDramaEstimateRequest(Map<String, Object?> body)`
  - `DramaEstimate estimateDrama({required DramaSeries series, required DramaEpisode episode, required Storyboard? storyboard, required Map<String, Object?>? planJson, required DramaEpisodeState state, required DramaEstimateRequest request, required DramaPricing pricing, required DramaStore store})`
  - `DramaEstimate` 增 `i2vEstimatedYuan`；预算快照增 `i2vTotalYuan` / `i2vActualYuan` / `i2vRemainingYuan`。
- Consumes: Task 6 的 hash、plan view、store 资产检查。

- [ ] **Step 1: 写失败测试**

```dart
final testPricing = DramaPricing(
  i2vYuanPerSecond: 0.15,
  imagePrice: (_, __) => 0.35,
  videoPrice: (_, __) => 0.15,
);

test('frame estimate prices missing frames and i2v clips, skips cached', () {
  final estimate = estimateDrama(
    series: series, episode: episode, storyboard: board, planJson: planJson,
    state: state, request: const DramaEstimateRequest(step: DramaEstimateStep.frame),
    pricing: testPricing, store: store,
  );
  expect(estimate.items.map((e) => e.kind), containsAll(<String>['image', 'clip']));
  expect(estimate.i2vEstimatedYuan, 0.45);
});

test('new estimate request rejects unknown step', () {
  expect(() => parseDramaEstimateRequest({'step': 'voice'}), throwsArgumentError);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/drama/cost_test.dart test/server/drama_api_test.dart`
Expected: FAIL，旧 `targets` 签名不匹配。

- [ ] **Step 3: 实现估算**

- `DramaPricing.catalog()` 用目录默认价；server 构造时用 `resolvePrices(defaults, overrides: cfg.imagePrices/videoPrices)` 覆盖。
- 请求解析只接受 `{step, cast_ids?, shot_ids?, target?, force?}`；**不保留 `targets`**。
- `story` / `storyboard` 返回 `unpriced` llm 项。
- `cast`：默认取分镜里被引用的 speaker；`cast_ids` 显式时只取这些；已有 avatar 且 hash 一致且文件存在且未 force → 跳过。
- `frame`：`target=frame|clip|all`；frame 缺失/过期生成 image 项；clip 缺失/过期按 plan 路由：`i2v` 用 `i2v_seconds × 视频单价`，`kenburns/micro` 用 0 元 `local` 项。
- 预算快照：`i2v_actual` = 已成功 i2v clip 的 cost 之和；`i2v_remaining = max(0, i2v_budget - i2v_actual)`。
- Controller `_estimate` 改读新 body；`DramaController` 构造增加 `pricing`（默认目录价）。

- [ ] **Step 4: 跑测试**

Run: `dart test test/pipeline/drama/cost_test.dart test/server/drama_api_test.dart`
Expected: PASS；旧的 `targets` 测试已删除或改成新格式。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/pricing.dart lib/pipeline/drama/run_target.dart lib/pipeline/drama/cost.dart \
  lib/pipeline/drama/controller.dart lib/server/pipeline_server.dart test/pipeline/drama/cost_test.dart \
  test/server/drama_api_test.dart
git commit -m "feat(short-drama): 定妆与画面估算改用新格式"
```

### Task 8: ffmpeg 竖屏参数化

**Files:**
- Modify: `lib/pipeline/ffmpeg.dart:96-155`
- Test: `test/pipeline/ffmpeg_test.dart:160-310`

**Interfaces:**
- Produces:
  - `List<String> kenBurnsArgsFor({required File img, required int durationS, required File out, int width = 1280, int height = 720, int fps = 24, double zoomStep = 0.0015, double maxZoom = 1.5})`
  - `List<String> microArgsFor({required File img, required int durationS, required File out, int width = 1280, int height = 720, int fps = 24})`
  - `List<String> normalizeArgsFor({required File input, required File out, int width = 1280, int height = 720, int fps = 24})`
  - 原 `kenBurnsArgs` / `normalizeArgs` 委托新函数，默认值不变。
- Consumes: 现有 `runFfmpeg`、`mediaDurationSeconds`。

- [ ] **Step 1: 写失败测试**

```dart
test('kenBurnsArgsFor emits 1080x1920/24fps', () {
  final args = kenBurnsArgsFor(img: img, durationS: 3, out: out, width: 1080, height: 1920);
  expect(args.join(' '), contains('scale=1080:1920'));
  expect(args.join(' '), contains('s=1080x1920'));
});

test('micro is gentler than kenburns', () {
  expect(microArgsFor(img: img, durationS: 3, out: out).join(' '), contains('1.08'));
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/ffmpeg_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现并保留默认包装**

默认 `kenBurnsArgs` / `normalizeArgs` 输出参数必须与现在逐字一致；新增竖屏测试跑真实 ffmpeg，断言输出 1080×1920。

- [ ] **Step 4: 跑测试**

Run: `dart test test/pipeline/ffmpeg_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/ffmpeg.dart test/pipeline/ffmpeg_test.dart
git commit -m "feat(ffmpeg): 支持竖屏参数化 kenburns 与 normalize"
```

### Task 9: 可注入媒体网关

**Files:**
- Create: `lib/pipeline/drama/media_gateway.dart`
- Test: `test/pipeline/drama/media_gateway_test.dart`

**Interfaces:**
- Produces:
  - `class DramaMediaResult { const DramaMediaResult({required this.path, required this.costYuan, required this.model, this.durationS}); }`
  - `abstract interface class DramaMediaGateway { Future<DramaMediaResult> generateImage({required String model, required ImageMode mode, required String prompt, required String baseDir, required String contentId, List<File> refFiles = const [], String size = '1K', required void Function(String) onLog}); Future<DramaMediaResult> generateI2vClip({required String model, required String resolution, required File firstFrame, required String prompt, required int durationS, required File outFile, required void Function(String) onLog}); Future<void> renderLocalClip({required File image, required File outFile, required ShotRoute route, required int width, required int height, required int durationS}); Future<void> normalizeClip({required File input, required File outFile, required int width, required int height}); }`
  - `class DashScopeDramaMediaGateway implements DramaMediaGateway`（构造：`cfg`、`pricing`、`http.Client?`、`sleep`）。
- Consumes: `buildImageClient`、`generateImages`、`I2vClient`、`Base64ImageUrlProvider`、Task 8 的 ffmpeg 助手。

- [ ] **Step 1: 写失败测试**

```dart
test('gateway fails before network when API key is missing', () async {
  final cfgFile = File('${tempDir.path}/cfg.json')..writeAsStringSync('{}');
  final cfg = await PipelineConfig.load(file: cfgFile, env: <String, String>{});
  final gateway = DashScopeDramaMediaGateway(cfg: cfg, pricing: testPricing());
  expect(
    () => gateway.generateImage(model: 'wan2.7-image', mode: ImageMode.t2i, prompt: 'x', baseDir: temp, contentId: 'h', onLog: (_) {}),
    throwsA(isA<ConfigException>()),
  );
});

test('local clip writes a playable 1080x1920 mp4 at zero cost', () async {
  await gateway.renderLocalClip(image: fixturePng, outFile: out, route: ShotRoute.kenburns, width: 1080, height: 1920, durationS: 2);
  expect(await mediaDurationSeconds(out), closeTo(2, 0.2));
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/drama/media_gateway_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现**

- 图片：先 `cfg.requireApiKey()`；`findImageModel` 未知模型抛 `PipelineError`；refFiles 转 data URL；`generateImages` 写到 `<baseDir>/<contentId>/image-01.png`；全部下载失败抛 `PipelineError`；cost 用 job.cost。
- i2v：先 `requireApiKey()`；`I2vClient(model, resolution, cfg.apiHost, watermark: true, seed: cfg.i2vSeed)`；首帧用 `Base64ImageUrlProvider().publish`；submit → 按 `cfg.i2vPollSeconds` 轮询到 `cfg.i2vMaxWaitMinutes`；成功下载到 `outFile`（`.tmp` + rename）；失败直接抛，**不自动重试**；cost = `durationS × videoPrice`。
- 本地片段：`kenBurnsArgsFor` / `microArgsFor`，`runFfmpeg` 后用 `mediaDurationSeconds` 校验；零费用。
- `normalizeClip`：`normalizeArgsFor` + 校验时长。
- 文件写入前 `parent.createSync(recursive: true)`。

- [ ] **Step 4: 跑测试**

Run: `dart test test/pipeline/drama/media_gateway_test.dart`
Expected: PASS（真实网络不参与）。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/media_gateway.dart test/pipeline/drama/media_gateway_test.dart
git commit -m "feat(short-drama): 图片/i2v/本地片段媒体网关"
```

### Task 10: 定妆执行器与缓存跳过

**Files:**
- Create: `lib/pipeline/drama/runner.dart`
- Create: `lib/pipeline/drama/run_registry.dart`
- Create: `test/pipeline/drama/fake_gateway.dart`
- Test: `test/pipeline/drama/runner_test.dart`

**Interfaces:**
- Produces:
  - `enum DramaRunStatus { running, completed, failed, cancelled }`
  - `class DramaRunItem { id, kind, status, path, costYuan, error }`
  - `class DramaRun { id, seriesId, episodeId, step, status, items, logs, actualYuan, error; Future<void> done; }`
  - `class DramaRunner { DramaRunner({required DramaStore store, required DramaMediaGateway gateway, DateTime Function()? now}); DramaRun? run(String id); DramaRun? activeFor(String seriesId, String episodeId); Future<DramaRun> startStep({required String seriesId, required String episodeId, required DramaStep step, List<String> castIds = const [], List<String> shotIds = const [], DramaRunTarget target = DramaRunTarget.all, bool force = false}); Future<DramaRun> startShot({required String seriesId, required String episodeId, required String shotId, required DramaRunTarget target, bool force = false, bool degrade = false}); Future<void> cancel(String runId); void recoverOrphan(String seriesId, String episodeId); }`
  - `enum DramaRunTarget { frame, clip, all }`（复用 Task 7 的 `run_target.dart`）
- Consumes: Task 6/7/9 的 hash、pricing、gateway、store。

- [ ] **Step 1: 写失败测试**

```dart
test('cast run persists avatar, cost, and skips on second run', () async {
  final gateway = FakeGateway(cost: 0.35);
  final runner = makeRunner(store: store, gateway: gateway);
  final run = await runner.startStep(seriesId: 's', episodeId: 'e', step: DramaStep.cast);
  await run.done;
  expect(run.status, DramaRunStatus.completed);
  final series = store.readSeries('s');
  expect(series.cast['erniu']!.avatar!.approved, isFalse);
  expect(store.readState('s', 'e').actualYuan, 0.35);
  await runner.startStep(seriesId: 's', episodeId: 'e', step: DramaStep.cast).then((r) => r.done);
  expect(gateway.imageCalls, 1);
});

test('force regenerates even when cache matches', () async {
  await runner.startStep(seriesId: 's', episodeId: 'e', step: DramaStep.cast).then((r) => r.done);
  await runner.startStep(seriesId: 's', episodeId: 'e', step: DramaStep.cast, force: true).then((r) => r.done);
  expect(gateway.imageCalls, 2);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/drama/runner_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现 cast + run 生命周期**

- `DramaRun` 暴露 `Future<void> done`（Completer），供测试与控制器等待；异步执行用 `unawaited`。
- 同一集已有 running run → `StateError('episode_busy')`。
- 开始：state step = running、activeRun = runId、持久化；结束：step = succeeded/failed、activeRun = null、持久化。
- cast：hash 一致 + avatar 文件存在 + 未 force → skip 项；否则调用 gateway，写 `cast/<id>/<hash>/image-01.png`，`approved: false`，累加 cost，逐项 `store.writeSeries` + `store.writeState`。
- `ConfigException` / 鉴权失败：整 run `failed`，`error` 写中文，后续项不再发起。
- 单项失败：该项 `failed`，继续下一项。
- `cancel` 置标记，当前项完成后停止，run `cancelled`。
- `recoverOrphan`：state.activeRun 不存在于内存 → 把 running 工序改 `interrupted`、清 activeRun。

- [ ] **Step 4: 跑测试**

Run: `dart test test/pipeline/drama/runner_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/runner.dart lib/pipeline/drama/run_registry.dart \
  test/pipeline/drama/fake_gateway.dart test/pipeline/drama/runner_test.dart
git commit -m "feat(short-drama): 定妆执行器与 run 生命周期"
```

### Task 11: 画面执行器（首帧 / i2v / 本地片段 / 失效）

**Files:**
- Modify: `lib/pipeline/drama/runner.dart`
- Modify: `test/pipeline/drama/runner_test.dart`

**Interfaces:**
- Produces:
  - frame/clip 分支复用 Task 10 的 `DramaRunner`；
  - `DramaRunItem.kind` 取值 `frame|clip|local_clip`；
  - 单镜降级：`degrade: true` 时忽略 plan 路由，走 `ShotRoute.kenburns`。
- Consumes: Task 6 的 frame/clip hash、Task 7 的 plan view、Task 9 的 gateway。

- [ ] **Step 1: 写失败测试**

```dart
test('frame run generates frame then i2v clip with costs', () async {
  final run = await runner.startStep(seriesId: 's', episodeId: 'e', step: DramaStep.frame);
  await run.done;
  expect(run.items.map((i) => i.kind), containsAll(<String>['frame', 'clip']));
  expect(store.readState('s', 'e').actualYuan, closeTo(0.8, 0.001));
  expect(File(store.assetFile('s', 'e', state.shots['s01']!.clip.path!).path).existsSync(), isTrue);
});

test('changed storyboard marks frame/clip stale and re-runs only those', () async {
  store.writeStoryboard('s', 'e', boardWithChangedVisualFor('s02'));
  final steps = deriveDramaSteps(/* same inputs */);
  expect(steps.firstWhere((s) => s.key == DramaStep.frame).status, DramaStatus.stale);
  final callsBefore = gateway.imageCalls;
  await runner.startStep(seriesId: 's', episodeId: 'e', step: DramaStep.frame).then((r) => r.done);
  expect(gateway.imageCalls, callsBefore + 1);
});

test('one failing shot does not stop the batch', () async {
  gateway.failShot('s02');
  final run = await runner.startStep(seriesId: 's', episodeId: 'e', step: DramaStep.frame);
  await run.done;
  expect(run.items.firstWhere((i) => i.id == 's02').status, DramaStatus.failed);
  expect(store.readState('s', 'e').shots['s01']!.frame.status, DramaStatus.succeeded);
  expect(store.readState('s', 'e').shots['s03']!.frame.status, DramaStatus.succeeded);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/pipeline/drama/runner_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现 frame/clip**

- 取 plan；`target` 控制只跑 frame / clip / both。
- frame：hash 一致 + 文件存在 + 未 force → skip；否则 `generateImage`，speaker 有已采用 avatar 时用 i2i + refFiles，否则 t2i；写 `assets/frames/<shot>/<hash>/image-01.png`。
- clip：用当前 frame hash 计算 clip hash；i2v 用 `generateI2vClip`（时长 `i2vSeconds`），本地用 `renderLocalClip`（时长 `ceil(duration_s)`）。
- i2v 成功后 `normalizeClip` 到 `series.frame`（1080×1920）；本地片段直接按目标尺寸生成。
- 写 `assets/clips/<shot>/<hash>.mp4`，状态、cost、duration 持久化；失败标 `failed` 并继续。
- `degrade: true` 强制 `kenburns`，费用 0。
- 更新 `DramaEpisodeState.withShot`；每次成功/失败都落盘。

- [ ] **Step 4: 跑测试**

Run: `dart test test/pipeline/drama/runner_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/runner.dart test/pipeline/drama/runner_test.dart
git commit -m "feat(short-drama): 画面执行器、缓存与本地降级"
```

### Task 12: run/estimate/assets 路由与工序推导

**Files:**
- Modify: `lib/pipeline/drama/controller.dart:26-205,446-490`
- Modify: `lib/pipeline/drama/steps.dart:29-197`
- Modify: `lib/server/pipeline_server.dart:200-240,336-340`
- Test: `test/server/drama_api_test.dart`
- Test: `test/pipeline/drama/steps_test.dart`

**Interfaces:**
- Produces:
  - `DramaController({..., DramaRunner? runner, DramaPricing? pricing})`
  - `kDramaWiredSteps = {split, story, cast, board, frame}`
  - `DramaRoute.runStatus` / `cancelRun` / `asset` / `seriesAsset`
  - `GET .../runs/<id>`、`POST .../runs/<id>:cancel`、`GET .../assets/<path>`、`GET /api/drama/series/<sid>/assets/<path>`
- Consumes: Task 7/10/11。

- [ ] **Step 1: 写失败测试**

```dart
test('POST frame run returns 202, poll completes, assets serve png', () async {
  final res = await _post(port, '/api/drama/series/s/episodes/e/steps/frame:run', {});
  expect(res.status, 202);
  final runId = (jsonDecode(res.body) as Map)['run_id'];
  final polled = await _pollRun(port, runId);
  expect(polled['status'], 'completed');
  final asset = await _get(port, '/api/drama/series/s/episodes/e/assets/frames/s01/hash/image-01.png');
  expect(asset.status, 200);
  expect(asset.contentType, 'image/png');
});

test('second concurrent run is 409 episode_busy', () async {
  final first = await _post(port, '/api/drama/series/s/episodes/e/steps/frame:run', {});
  expect(first.status, 202);
  final second = await _post(port, '/api/drama/series/s/episodes/e/steps/frame:run', {});
  expect(second.status, 409);
  expect((jsonDecode(second.body) as Map)['code'], 'episode_busy');
});

test('over-budget run is 409 budget_exceeded and creates no run', () async {
  // 先把本集 total_budget_yuan 调到 0.01
  final res = await _post(port, '/api/drama/series/s/episodes/e/steps/frame:run', {});
  expect(res.status, 409);
  expect((jsonDecode(res.body) as Map)['code'], 'budget_exceeded');
  expect((jsonDecode(res.body) as Map).containsKey('run_id'), isFalse);
});

test('path escape is 400', () async {
  final res = await _get(port, '/api/drama/series/s/episodes/e/assets/%2e%2e/state.json');
  expect(res.status, 400);
});

test('voice run stays 501', () async {
  final res = await _post(port, '/api/drama/series/s/episodes/e/steps/voice:run', {});
  expect(res.status, 501);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `dart test test/server/drama_api_test.dart test/pipeline/drama/steps_test.dart`
Expected: FAIL。

- [ ] **Step 3: 实现路由与推导**

- `parseDramaRoute`：`steps/<key>:run`、`shots/<id>:run`、`runs/<id>`、`runs/<id>:cancel`、`assets/...`、series `assets/...`。
- `_runStep`：校验 step ∈ cast/frame；`estimate`；超总预算或 i2v 预算 → 409 `budget_exceeded`；`runner.startStep`；202 `{run_id}`。
- `_runShot`：校验 shot 存在；body `target` 默认 all；`degrade`；同样预算检查。
- `_getRun` / `_cancelRun`：404 / 200。
- `_asset`：`store.assetFile` / `seriesAssetFile`；扩展名白名单 png/jpg/webp/mp4/wav；目录或未知扩展 404；逃逸 400。
- `_bundle` 先 `runner.recoverOrphan`；`wired` 用 `runner == null ? kP1WiredSteps : kDramaWiredSteps`；capabilities cast/frame 随 runner 可用。
- `deriveDramaSteps`：cast/frame 的 `status` 支持 `stale`（artifact hash 与当前 hash 不一致）；`cost_yuan` 从 artifact 求和；frame 完成 = 所有镜头 clip 成功且 hash 一致。

- [ ] **Step 4: 跑测试**

Run: `dart test test/server/drama_api_test.dart test/pipeline/drama/steps_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add lib/pipeline/drama/controller.dart lib/pipeline/drama/steps.dart lib/server/pipeline_server.dart \
  test/server/drama_api_test.dart test/pipeline/drama/steps_test.dart
git commit -m "feat(short-drama): run/资产端点与失效推导"
```

---

## Phase D：P2 前端

### Task 13: 类型、API、资产 URL 与 run hook

**Files:**
- Create: `frontend/src/shortDrama/asset.ts`
- Create: `frontend/src/shortDrama/run.ts`
- Modify: `frontend/src/shortDrama/types.ts:140-194`
- Modify: `frontend/src/shortDrama/api.ts:90-184`
- Test: `frontend/src/shortDrama/asset.test.ts`

**Interfaces:**
- Produces:
  - `DramaArtifact { status; path; source_hash; model; cost_yuan; duration_s; error }`
  - `EpisodeState.shots: Record<string, { frame: DramaArtifact; clip: DramaArtifact; audio: DramaArtifact }>`
  - `DramaEstimate.i2v_estimated_yuan`、`budget.i2v_*`
  - `DramaRun` 类型
  - `dramaApi.estimate(seriesId, episodeId, input: EstimateInput)`
  - `dramaApi.runStep` / `runShot` / `getRun` / `cancelRun`
  - `seriesAssetUrl(seriesId, path)` / `episodeAssetUrl(seriesId, episodeId, path)`
  - `isTerminalRun(status)` / `runSummary(run)`
- Consumes: Task 7/12 的 wire 格式。

- [ ] **Step 1: 写失败测试**

```ts
it('encodes every path segment', () => {
  expect(episodeAssetUrl('s 1', 'e/1', 'assets/frames/s01/sha/image-01.png'))
    .toBe('/api/drama/series/s%201/episodes/e%2F1/assets/frames/s01/sha/image-01.png');
});
it('terminal statuses', () => {
  expect(isTerminalRun('completed')).toBe(true);
  expect(isTerminalRun('running')).toBe(false);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd frontend && npx vitest run src/shortDrama/asset.test.ts`
Expected: FAIL。

- [ ] **Step 3: 实现类型与客户端**

- 新 `EstimateInput = {step:"story"|"storyboard"|"cast"|"frame"; cast_ids?; shot_ids?; target?; force?}`。
- `runStep` 返回 `{run_id:string}`；`getRun` 返回 `DramaRun`；`cancelRun` 返回 `{status:string}`。
- `run.ts` 提供 `useDramaRun(seriesId, episodeId, onDone)`：启动后 1 秒轮询；终态停止并 `onDone()`；卸载时停止；错误转中文。
- 所有资产 URL 逐段 `encodeURIComponent`。

- [ ] **Step 4: 跑测试与类型检查**

Run:

```bash
cd frontend && npm test && npm run lint && npm run build
```

Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add frontend/src/shortDrama/asset.ts frontend/src/shortDrama/run.ts \
  frontend/src/shortDrama/types.ts frontend/src/shortDrama/api.ts \
  frontend/src/shortDrama/asset.test.ts
git commit -m "feat(web): 短剧 run 类型、API 与资产地址"
```

### Task 14: 定妆舞台（生成 / 采用 / 预览）

**Files:**
- Modify: `frontend/src/shortDrama/stages/CastStage.tsx`
- Modify: `frontend/src/shortDrama/StageRouter.tsx:42-43`
- Modify: `frontend/src/shortDrama/WorkbenchShell.tsx:79-86`
- Modify: `frontend/src/shortDrama/ShortDrama.css`
- Test: `frontend/src/shortDrama/workbench.test.tsx`

**Interfaces:**
- Consumes: Task 13 的 `dramaApi` / `useDramaRun` / `seriesAssetUrl`、`DramaCostGate`。
- Produces: CastStage props `{ bundle, onBundle, onReload }`。

- [ ] **Step 1: 写失败测试**

```tsx
it('cast stage shows avatar status and cost action without a fake progress', () => {
  const html = renderToString(<CastStage bundle={bundleWithAvatar} onBundle={() => {}} onReload={() => {}} />);
  expect(html).toContain('待采用');
  expect(html).toContain('生成定妆');
  expect(html).not.toContain('运行中');
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd frontend && npx vitest run src/shortDrama/workbench.test.tsx`
Expected: FAIL。

- [ ] **Step 3: 实现**

- 角色卡：头像（`seriesAssetUrl`）、描述、状态（未生成 / 待采用 / 已采用）。
- 「生成定妆」：`estimate({step:"cast", cast_ids:[id]})` → `DramaCostGate` → `runStep('cast', {cast_ids:[id]})` → 轮询 → `onReload()`.
- 「重新生成」传 `force: true`，按钮直接标价。
- 「采用」：`dramaApi.updateSeries` 复制 series，把该角色 `avatar.approved=true`，成功后 `onBundle`/`onReload`。
- 无角色时保持现有空态提示。
- StageRouter 把 `onBundle`/`onReload` 传给 CastStage。

- [ ] **Step 4: 跑测试**

Run: `cd frontend && npm test && npm run lint`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add frontend/src/shortDrama/stages/CastStage.tsx frontend/src/shortDrama/StageRouter.tsx \
  frontend/src/shortDrama/WorkbenchShell.tsx frontend/src/shortDrama/ShortDrama.css \
  frontend/src/shortDrama/workbench.test.tsx
git commit -m "feat(web): 定妆工序生成、采用与预览"
```

### Task 15: 画面舞台与 Inspector（时间轴 / 逐镜 / 批量 / 降级）

**Files:**
- Modify: `frontend/src/shortDrama/stages/FrameStage.tsx`
- Modify: `frontend/src/shortDrama/Inspector.tsx`
- Modify: `frontend/src/shortDrama/WorkbenchShell.tsx:40-98`
- Modify: `frontend/src/shortDrama/DramaCostGate.tsx:19-90`
- Modify: `frontend/src/shortDrama/ShortDrama.css`
- Test: `frontend/src/shortDrama/workbench.test.tsx`

**Interfaces:**
- Consumes: Task 13 的 run API / asset URL、Task 12 的 `state.shots`。
- Produces: FrameStage props `{ bundle, selectedShotId, onSelectShot, onReload }`；Inspector 接收 `shotState`。

- [ ] **Step 1: 写失败测试**

```tsx
it('frame stage renders thumbnails and per-shot actions', () => {
  const html = renderToString(<FrameStage bundle={bundleWithArtifacts} selectedShotId="s01" onSelectShot={() => {}} onReload={() => {}} />);
  expect(html).toContain('生成全部首帧');
  expect(html).toContain('降级为静帧');
  expect(html).toContain('assets/frames');
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd frontend && npx vitest run src/shortDrama/workbench.test.tsx`
Expected: FAIL。

- [ ] **Step 3: 实现舞台**

- 镜头条显示首帧缩略图、clip 状态点、`stale/failed` 标记。
- 批量：「生成全部首帧」`{step:"frame", target:"frame"}`；「生成全部片段」`{step:"frame", target:"clip"}`；都走 estimate → 闸门 → run → 1 秒轮询。
- 单镜：`runShot(id,{target:"frame"|"clip"|"all"})`；「降级为静帧」传 `degrade:true`，估算应为 0 元。
- 运行面板：状态、日志、取消按钮；终态 `onReload()`。
- Inspector：有 frame 显示 `<img>`，有 clip 显示 `<video controls>`；显示 artifact 状态、本镜实际成本、hash 短码、错误。
- `DramaCostGate` 增加 i2v 预算行（有 `i2v_budget` 时显示）。
- 无分镜/无计划保持现有空态；不伪造进度。

- [ ] **Step 4: 测试、lint、构建、提交**

Run:

```bash
cd frontend && npm test && npm run lint && npm run check:dialogs && npm run build
cd .. && make web
```

Expected: 全绿，`web_build` 更新。

```bash
git add frontend/src/shortDrama/stages/FrameStage.tsx frontend/src/shortDrama/Inspector.tsx \
  frontend/src/shortDrama/WorkbenchShell.tsx frontend/src/shortDrama/DramaCostGate.tsx \
  frontend/src/shortDrama/ShortDrama.css frontend/src/shortDrama/workbench.test.tsx web_build
git commit -m "feat(web): 画面工序时间轴、批量生成与降级"
```

---

## Phase E：P2 验收

### Task 16: 离线验收与一次小额真实跑

**Files:**
- Create: `test/manual/drama_real_smoke.dart`
- Modify: `docs/superpowers/plans/2026-10-26-drama-workbench-p2.md`（勾选）
- Modify: `docs/superpowers/specs/2026-10-23-drama-workbench-design.md`（P2 DoD）

**Interfaces:**
- Consumes: Task 1-15 的全部实现。
- Produces: 离线全绿证据 + 真实产物截图/路径 + 费用记录（不含密钥）。

- [ ] **Step 1: 跑离线基线**

Run:

```bash
make analyze
make test-dart
make test-web
cd frontend && npm run build
```

Expected: 全部退出码 0；把结果写进验收记录。

- [ ] **Step 2: 写 gated 真实 smoke（不默认运行）**

`test/manual/drama_real_smoke.dart` 规则：

- 仅当 `RUN_REAL_DRAMA=1` 时执行，否则 `skip: 'set RUN_REAL_DRAMA=1'`。
- 从 macOS Keychain 读 `DASHSCOPE_API_KEY`：`security find-generic-password -s com.conatusviva.secrets -a DASHSCOPE_API_KEY -w`，不打印。
- 读 `pipeline_config.json`，用临时目录作为 `DramaStore` root；创建一剧一集、一个 action/priority=hook/3 秒镜头；保存分镜并重算计划。
- 先用 `estimateDrama` 打印总价与 i2v 价；**超过 ¥2.0 直接失败**，不发起调用。
- 跑 cast → 采用 avatar → 跑 frame（frame + i2v）；断言 avatar/frame/clip 文件存在、state 成本 > 0、clip 时长在 2-4 秒。
- 不把任何 key、临时目录内容写进仓库。

Run（只有用户确认费用后才执行）:

```bash
RUN_REAL_DRAMA=1 dart test test/manual/drama_real_smoke.dart
```

Expected: PASS；费用约 ¥1.15（1 张定妆 + 1 张首帧 + 3 秒 i2v），以实际账单为准。

- [ ] **Step 3: 手工核对 UI**

`make run` 后确认：

- 设置页显示已配置，保存后无需重启即可生成。
- 定妆生成后显示「待采用」，点「采用」后工序完成。
- 画面工序显示缩略图，批量/单镜/降级动作都有价格，超预算时确认按钮禁用。
- 运行中可取消；完成后底栏成本更新。
- 空态、未接入的 voice/edit/pack 仍显示「未接入」。

- [ ] **Step 4: 勾选与提交**

把本计划任务 checkbox 与设计文档 P2 DoD 勾选，提交：

```bash
git add test/manual/drama_real_smoke.dart docs/superpowers/plans/2026-10-26-drama-workbench-p2.md \
  docs/superpowers/specs/2026-10-23-drama-workbench-design.md
git commit -m "docs(short-drama): P2 验收记录与真实 smoke"
```

---

## 自检记录

- **Spec 覆盖**：P2 的 CastRunner / FrameRunner / ClipRunner（Task 10-11）、estimate/run/runs（Task 7/12）、竖屏 ffmpeg（Task 8）、逐镜/重跑/降级/时间轴/缓存/批量（Task 11/15）、离线 fake + ffmpeg fixture（Task 8/10/11）均有对应任务；设置入口与移除 `.env` 为本次新增阶段（Task 2-5）。
- **未做（明确）**：P3 的 voice/edit/pack、t2v 计划路由、旧 CLI/端点删除、旧计划单导入；这些不在本计划内。
- **Review Focus 对应测试**：1 → Task 9/15；2 → Task 12；3 → Task 10/12；4 → Task 11；5 → Task 11/12；6 → Task 7/12；7 → Task 10/11。
