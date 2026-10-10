# M0 真钱冒烟执行记录

> 执行人：用户（手动，2026-10-10）。本记录由控制器按执行过程与修复历史整理，未经复核的项明确标注。

## 结论

**端到端跑通：`06_final.mp4` 已生成。** 路径：ingest → classify → select → script → tts（后改 --mute 跳过）→ render（万相 i2v + Ken Burns）→ compose + SRT。

## 过程中发现并修复的问题（已全部入库）

| 问题 | 现象 | 修复 | 提交 |
|---|---|---|---|
| TTS 端点错误 | `TTS HTTP 403: Model access denied.`（qwen3-tts-flash 不在 SpeechSynthesizer 服务） | 按模型族分流：qwen-audio-* → SpeechSynthesizer（instruction 入 input）；qwen3-* → multimodal-generation（不下发 instruction 与控制标签） | `92eec93` |
| workspace 主机 | 百炼业务空间要求 `https://<id>.cn-beijing.maas.aliyuncs.com` | `pipeline_config.json` 新增 `workspace_id`，LLM/TTS/i2v/上传全端点派生切换 | `92eec93` |
| 上传端点 405 | `DashScope upload HTTP 405`（`/api/v1/uploads` 在 workspace 主机不可用） | 万相 `img_url` 原生支持 base64 数据 URL（官方方式三）→ 新增 `Base64ImageUrlProvider` 并设为默认，绕开上传/24h 过期/OSS | `17c1995` |
| ffmpeg 不认 `.tmp` | `Unable to choose an output format for '…seg_0.wav.tmp'` | `silentWavArgs` 显式 `-f wav`；TTS 临时文件改 `audio.tmp.wav` | `1d7426d` + 工作区 |
| CLI 无反馈 | 长轮询期间像卡死 | 步级 + 段级进度输出（stderr，`[mm:ss]` 前缀） | `4f3826d` |

## 出口清单核对（spec §7）

- [x] 端到端产出 `06_final.mp4` 可播（用户确认）
- [x] 断点续跑生效（多次失败重跑均从断点继续，未重复提交 i2v 任务）
- [x] DashScope 上传 URL 问题（Review Focus #1）——以 base64 直传取代，不再是阻塞项
- [ ] 方言配音听感——**未验**：本次以 `--mute`（静音音轨）出片；TTS 链路修复后（qwen3-tts-flash 走通或填 `tts.voice_id` 走 qwen-audio 指令通道）需单独复核
- [ ] SRT 与语音对齐——静音版仅有字幕时长逻辑对齐，配音版待验
- [ ] `--agent` 模式——未跑
- [ ] 幂等重跑零新提交——部分验证（断点恢复未重复扣费）；完整「全部 skip」未单独跑

## 后续

1. TTS 配音链路：当前 `voice_id: null` 走 `qwen3-tts-flash` + Cherry 系统音色；要方言指令通道需 qwen-audio 音色（填 `tts.voice_id`）。
2. `--mute` 出的静音版如要换成配音版：删 `pipeline_out/<id>/04_audio/` 后去 `--mute` 重跑，或换新 content-id。
3. 合 master 前：全分支评审（SDD final review）尚未执行。
