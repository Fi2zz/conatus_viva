import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:conatus/conatus.dart';
import 'package:flutter_wanxiang/pipeline/bailian/wan30_video.dart';
import 'package:flutter_wanxiang/pipeline/config.dart';
import 'package:flutter_wanxiang/pipeline/errors.dart';
import 'package:flutter_wanxiang/pipeline/ffmpeg.dart';
import 'package:flutter_wanxiang/pipeline/host.dart';
import 'package:flutter_wanxiang/pipeline/srt.dart';
import 'package:flutter_wanxiang/pipeline/t2v_subtitles.dart';
import 'package:flutter_wanxiang/pipeline/text_to_video.dart';

/// 实验宿主：手跑月度相册视频流水线的 CLI 入口。
///
/// 默认路径直接调 `generate_monthly_video` 工具并把 PipelineResult JSON
/// 打到 stdout；`--agent` 把参数包成自然语言任务交给 AgentLoop。
Future<void> main(List<String> argv) async {
  final parser = buildParser();
  final ArgResults results;
  try {
    results = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n\n${parser.usage}');
    exit(64);
  }
  if (results.flag('help')) {
    stdout.writeln(parser.usage);
    return;
  }
  final envError = validateEnv(Platform.environment);
  if (envError != null) {
    stderr.writeln(envError);
    exit(exitCodeMissingEnv);
  }
  exit(await run(results, parser));
}

ArgParser buildParser() {
  return ArgParser()
    ..addOption('photos', help: '逗号分隔的照片路径/URL，或一个目录')
    ..addOption('dialect', help: '方言地区（如 河南、上海）')
    ..addOption('count', abbr: 'n', defaultsTo: '4', help: '入选照片数上限')
    ..addOption('content-id', help: '内容 ID（缺省按时间生成）')
    ..addFlag('dry-run', help: '只跑到配音，返回成本预估，不渲染')
    ..addFlag('mute', help: '跳过配音，静音音轨出片（字幕照常）')
    ..addOption(
      'video-model',
      help: '视频模型：wan2.6-i2v-flash（默认）/ wan3.0-video / '
          'wan3.0-video-prime（缺省用配置 i2v.model）',
    )
    ..addOption(
      'text-to-video',
      help: '文生视频：提示词（切到文生视频模式，无需 --photos/--dialect）',
    )
    ..addOption(
      'video-resolution',
      help: '文生视频分辨率：480P/720P/1080P（缺省用配置 t2v.resolution）',
    )
    ..addOption(
      'video-ratio',
      help: '文生视频宽高比：adaptive/16:9/9:16 等（缺省用配置 t2v.ratio）',
    )
    ..addOption(
      'video-duration',
      help: '文生视频时长秒：2-30 或 -1 智能（缺省用配置 t2v.duration）',
    )
    ..addFlag(
      'video-audio',
      defaultsTo: true,
      help: '文生视频是否保留原生音频（--no-video-audio 关闭；缺省用配置 t2v.audio）',
    )
    ..addOption(
      'video-out',
      help: '文生视频输出文件路径（缺省 pipeline_out/videos/<id>/video.mp4）',
    )
    ..addOption(
      'subtitle-text',
      help: '文生视频字幕文本（每行一条；与 --subtitle-file 互斥）',
    )
    ..addOption(
      'subtitle-file',
      help: '文生视频字幕文件（.srt 原样复制，其它按纯文本；与 --subtitle-text 互斥）',
    )
    ..addOption('agent', help: '自然语言任务，交给 agent loop 执行')
    ..addOption(
      'prefer-provider',
      defaultsTo: 'base64',
      allowed: <String>['base64', 'dashscope', 'oss'],
      help: '图片 URL 提供方（base64 直传免上传；oss 走签名上传回退）',
    )
    ..addFlag('help', abbr: 'h', negatable: false, help: '打印用法');
}

Future<int> run(ArgResults results, ArgParser parser) async {
  final args = parseArgs(results, parser);
  if (args == null) return 64;
  final PipelineConfig cfg;
  try {
    cfg = await PipelineConfig.load();
  } on ConfigException catch (e) {
    stderr.writeln(e.message);
    return exitCodeMissingEnv;
  }
  if (args.textToVideo != null) return runTextToVideo(cfg, args);
  final startedAt = DateTime.now();
  final ctx = await createHost(
    cfg: cfg,
    preferProvider: args.preferProvider,
    onProgress: (message) => printProgress(startedAt, message),
  );
  try {
    return args.agentTask == null
        ? await runDirect(ctx, args)
        : await runAgent(ctx, cfg, args);
  } finally {
    ctx.dispose();
  }
}

/// Progress lines go to stderr (stdout stays pure result JSON) with an
/// elapsed `mm:ss` prefix since run start.
void printProgress(DateTime startedAt, String message) {
  final elapsed = DateTime.now().difference(startedAt);
  final mm = elapsed.inMinutes.toString().padLeft(2, '0');
  final ss = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
  stderr.writeln('[$mm:$ss] $message');
}

/// 缺必填参数返回 null（用法错误已由 stderr 说明）。
HostArgs? parseArgs(ArgResults results, ArgParser parser) {
  final textToVideo = results['text-to-video'] as String?;
  if (textToVideo != null && textToVideo.isNotEmpty) {
    return _parseTextToVideo(results, parser, textToVideo);
  }
  final photos = results['photos'] as String?;
  final dialect = results['dialect'] as String?;
  final count = int.tryParse(results['count'] as String);
  if (photos == null || dialect == null || count == null) {
    stderr.writeln('必须提供 --photos 与 --dialect（--count 需为整数）\n\n'
        '${parser.usage}');
    return null;
  }
  return HostArgs(
    photos: expandPhotos(photos),
    dialect: dialect,
    count: count,
    contentId: results['content-id'] as String?,
    dryRun: results.flag('dry-run'),
    mute: results.flag('mute'),
    agentTask: results['agent'] as String?,
    preferProvider: results['prefer-provider'] as String,
    videoModel: results['video-model'] as String?,
  );
}

/// 文生视频参数解析：只要提示词（+可选覆盖），不需要照片与方言。
HostArgs? _parseTextToVideo(
  ArgResults results,
  ArgParser parser,
  String prompt,
) {
  if (results['agent'] != null) {
    stderr.writeln('--text-to-video 不支持 --agent\n\n${parser.usage}');
    return null;
  }
  final subtitleText = _nonEmpty(results['subtitle-text'] as String?);
  final subtitleFile = _nonEmpty(results['subtitle-file'] as String?);
  if (subtitleText != null && subtitleFile != null) {
    stderr.writeln('--subtitle-text 与 --subtitle-file 只能二选一\n\n${parser.usage}');
    return null;
  }
  final model = results['video-model'] as String?;
  if (model != null) {
    final problem = t2vModelProblem(model);
    if (problem != null) {
      stderr.writeln('$problem\n\n${parser.usage}');
      return null;
    }
  }
  final durationRaw = _nonEmpty(results['video-duration'] as String?);
  int? duration;
  if (durationRaw != null) {
    duration = int.tryParse(durationRaw);
    final outOfRange =
        duration == null || (duration != -1 && (duration < 2 || duration > 30));
    if (outOfRange) {
      stderr.writeln('--video-duration 需为 2-30 的整数或 -1\n\n${parser.usage}');
      return null;
    }
  }
  return HostArgs(
    photos: const <String>[],
    dialect: (results['dialect'] as String?) ?? '',
    count: 0,
    dryRun: false,
    preferProvider: results['prefer-provider'] as String,
    videoModel: model,
    textToVideo: prompt,
    videoResolution: _nonEmpty(results['video-resolution'] as String?),
    videoRatio: _nonEmpty(results['video-ratio'] as String?),
    videoDuration: duration,
    videoAudio: results.wasParsed('video-audio')
        ? results.flag('video-audio')
        : null,
    videoOut: _nonEmpty(results['video-out'] as String?),
    subtitleText: subtitleText,
    subtitleFile: subtitleFile,
  );
}

String? _nonEmpty(String? value) =>
    (value == null || value.isEmpty) ? null : value;

/// 文生视频模式：直接调万相 3.0，落盘 mp4（可选 SRT）后打印结果 JSON。
Future<int> runTextToVideo(PipelineConfig cfg, HostArgs args) async {
  final model = t2vModelFor(cfg, args);
  final problem = t2vModelProblem(model);
  if (problem != null) {
    stderr.writeln(problem);
    return 64;
  }
  final contentId = args.contentId ?? _timestampId();
  final outFile = args.videoOut ?? 'pipeline_out/videos/$contentId/video.mp4';
  final prompt = t2vPrompt(args.textToVideo!, args.dialect);
  final client = Wan30VideoClient(
    apiKey: cfg.requireApiKey(),
    host: cfg.apiHost,
    model: model,
    resolution: args.videoResolution ?? cfg.t2vResolution,
    ratio: args.videoRatio ?? cfg.t2vRatio,
    watermark: cfg.t2vWatermark,
    seed: cfg.t2vSeed,
    audio: args.videoAudio ?? cfg.t2vAudio,
  );
  try {
    final result = await generateTextToVideo(
      client: client,
      prompt: prompt,
      durationS: args.videoDuration ?? cfg.t2vDuration,
      outFile: outFile,
      pollSeconds: cfg.t2vPollSeconds,
      maxWaitMinutes: cfg.t2vMaxWaitMinutes,
      onProgress: (message) => stderr.writeln(message),
    );
    final srtPath = await _writeSubtitles(args, result);
    stdout.writeln(
      jsonEncode(<String, dynamic>{
        'mode': 'text_to_video',
        'model': model,
        'prompt': prompt,
        'duration_s': result.durationS,
        'video_path': result.filePath,
        'srt_path': ?srtPath,
        'task_id': result.taskId,
      }),
    );
    return 0;
  } on PipelineError catch (e) {
    stderr.writeln('text-to-video failed: ${e.message}');
    return 1;
  }
}

/// Writes the subtitle track next to the mp4 when requested; returns its path.
/// A `.srt` input is copied verbatim (timings already authored); other text is
/// split into one cue per line, evenly across the clip (the model returns no
/// transcript, so timing is approximate by construction).
Future<String?> _writeSubtitles(HostArgs args, TextToVideoResult result) async {
  final file = args.subtitleFile;
  final text = args.subtitleText;
  if (file == null && text == null) return null;
  final srtPath = _srtPathFor(result.filePath);
  try {
    if (file != null && file.toLowerCase().endsWith('.srt')) {
      File(file).copySync(srtPath);
      return srtPath;
    }
    final raw = file != null ? File(file).readAsStringSync() : text!;
    final seconds = result.durationS > 0
        ? result.durationS
        : (await mediaDurationSeconds(File(result.filePath))).ceil();
    final srt = renderSrt(
      buildSubtitleEntries(text: raw, duration: Duration(seconds: seconds)),
    );
    if (srt.isEmpty) {
      stderr.writeln('字幕文本为空，跳过 SRT');
      return null;
    }
    File(srtPath).writeAsStringSync(srt);
    return srtPath;
  } on FileSystemException catch (e) {
    stderr.writeln('字幕写入失败：$e');
    return null;
  } on FfmpegException catch (e) {
    stderr.writeln('探测视频时长失败，跳过 SRT：$e');
    return null;
  }
}

String _srtPathFor(String videoPath) {
  final dot = videoPath.lastIndexOf('.');
  final slash = videoPath.lastIndexOf(Platform.pathSeparator);
  return dot > slash ? '${videoPath.substring(0, dot)}.srt' : '$videoPath.srt';
}

String _timestampId() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final day = '${now.year}${two(now.month)}${two(now.day)}';
  final time = '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  return 't2v-$day-$time';
}

Future<int> runDirect(Context ctx, HostArgs args) async {
  final result = await runPipelineTool(ctx, args);
  if (result.isError) {
    stderr.writeln('pipeline failed: ${result.content}');
    return 1;
  }
  stdout.writeln(result.content);
  return 0;
}

Future<int> runAgent(Context ctx, PipelineConfig cfg, HostArgs args) async {
  final loop = attachAgentLoop(ctx, cfg: cfg);
  stderr.writeln('session log: $sessionLogDir/${loop.session?.id}.jsonl');
  try {
    final turn = await loop.run(agentTask(args));
    stdout.writeln(turn.reply);
    return 0;
  } on LlmException catch (e) {
    stderr.writeln('agent failed: $e');
    return 1;
  }
}
