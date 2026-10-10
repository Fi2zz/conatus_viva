# conatus_viva — 月度相册视频流水线

输入一组照片（本地路径或 URL）和方言地区，端到端产出 15–20 秒的相册视频：多模态选片、口播文案、方言配音、万相图生视频、字幕合成。全程断点续跑、不重复扣费。

核心是纯 Dart 管线（`lib/pipeline/`，不依赖 Flutter），宿主是 [conatus](https://github.com/Fi2zz/conatus) 的 `generate_monthly_video` 工具 + 实验 CLI（`bin/conatus_host.dart`）。

## 快速开始

```bash
# 1. 配置：复制模板，按需填写 workspace_id（百炼业务空间 ID，控制台可查）
cp pipeline_config.example.json pipeline_config.json

# 2. 密钥（只走环境变量，不落任何文件）
export DASHSCOPE_API_KEY=sk-...

# 3. 干跑：只到配音，返回分段路由与成本预估，不渲染
dart run bin/conatus_host.dart --photos /path/to/照片目录 --dialect 河南 --dry-run

# 4. 正式出片（i2v 按秒计费，≈0.15 元/秒）
dart run bin/conatus_host.dart --photos /path/to/照片目录 --dialect 河南 --content-id my-album
```

产出在 `pipeline_out/<content-id>/`：`06_final.mp4` + `06_final.srt`，中间产物（分类、文案、音轨、分段视频、`state.json`）全部落盘。中断后重跑同一条命令即从断点继续，已成功的步骤自动跳过。

## CLI 参数

| 参数 | 说明 |
|---|---|
| `--photos` | 逗号分隔的路径/URL，或一个目录（自动取图片，排序） |
| `--dialect` | 方言地区（如 河南、上海；未覆盖地区回落普通话） |
| `--count, -n` | 入选照片数上限（默认 4） |
| `--content-id` | 内容 ID（缺省按时间生成）；同 ID 重跑 = 断点续跑 |
| `--dry-run` | 只跑到配音，返回成本预估，不渲染 |
| `--mute` | 跳过配音，静音音轨出片（字幕照常） |
| `--prefer-provider` | 图片供给方式：`base64`（默认，直传免上传）/ `dashscope` / `oss` |
| `--agent` | 把参数包成自然语言任务交给 agent loop 执行 |

运行中进度打在 stderr（`[mm:ss]` 前缀），stdout 只输出结果 JSON。

## 管线结构

```
lib/pipeline/
  config.dart        配置加载（pipeline_config.json + 环境变量密钥）
  dialect_map.dart   省市 → 方言指令映射（兜底普通话）
  state.dart         state.json 状态机（原子写、24h 任务恢复、成本核算）
  artifacts.dart     工件目录布局（产物存在即跳过）
  ffmpeg.dart        ffprobe 测时长 + 命令拼装（Ken Burns / 归一化 / 拼接 / 静音）
  bailian/           百炼客户端：llm（分类/文案）、tts（配音）、i2v（万相）、uploader（图片供给）
  steps/             六步流水线：ingest → classify/select → script → tts → render → compose
  orchestrator.dart  编排器（步级幂等 + dry-run 停点 + --mute）
  monthly_video_tool.dart  conatus 工具封装（高风险，走审批）
bin/conatus_host.dart      实验 CLI
```

人物照片硬规则走 Ken Burns（ffmpeg zoompan），不提交万相；风景照走 i2v，审核拒答自动降级 Ken Burns 且零计费。

## 配置说明（pipeline_config.json）

不入库（含 workspace_id），模板见 `pipeline_config.example.json`：

- `workspace_id`：百炼业务空间 ID；非空时 LLM/TTS/i2v 端点全部切到 `https://<id>.cn-beijing.maas.aliyuncs.com`，留空走默认 `dashscope.aliyuncs.com`
- `tts.voice_id`：null → 用 `fallback_model`（qwen3-tts-flash）+ `fallback_voice`（系统音色 Cherry）；填 qwen-audio 音色 ID → 走方言指令通道（`请用河南话表达。`）
- `i2v`：模型/分辨率/水印/种子/轮询参数，全部显式钉死防默认抬价

OSS 回退（`--prefer-provider oss`）另需环境变量 `OSS_ACCESS_KEY_ID` / `OSS_ACCESS_KEY_SECRET` 及配置里的 `oss.bucket` / `oss.endpoint`。

## 测试

```bash
dart test test/pipeline/   # 全程离线（MockClient + 本机 ffmpeg fixture）
dart analyze lib bin test  # 零告警基线
```

## 文档

- 设计 spec：`docs/superpowers/specs/2026-10-10-monthly-album-video-pipeline-design.md`
- 实施计划：`docs/superpowers/plans/2026-10-10-conatus-viva-pipeline.md`
- M0 冒烟记录：`docs/superpowers/plans/m0-smoke-report.md`
- 方言配音方案：`docs/万相图生视频方言配音方案_v1.0.md`
