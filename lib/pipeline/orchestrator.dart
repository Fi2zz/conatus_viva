import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'artifacts.dart';
import 'bailian/i2v.dart';
import 'bailian/llm.dart';
import 'bailian/tts.dart';
import 'bailian/uploader.dart';
import 'config.dart';
import 'dialect_map.dart';
import 'errors.dart';
import 'ffmpeg.dart';
import 'state.dart';
import 'steps/classify.dart';
import 'steps/compose.dart';
import 'steps/ingest.dart';
import 'steps/render.dart';
import 'steps/script.dart';
import 'steps/select.dart';
import 'steps/tts_step.dart';

/// One run's parameters, as assembled by the tool / CLI host.
class PipelineInput {
  const PipelineInput({
    required this.photos,
    required this.dialect,
    required this.count,
    required this.contentId,
    required this.dryRun,
    this.mute = false,
  });

  /// Local paths or `http(s)://` URLs (ingest accepts both, spec §3.1).
  final List<String> photos;

  /// Region text resolved via [resolveDialect] (unknown → mandarin).
  final String dialect;
  final int count;
  final String contentId;

  /// `true` → stop after tts and return the cost plan without rendering.
  final bool dryRun;

  /// `true` → skip TTS entirely and fill silent narration tracks locally
  /// (subtitles still render); the video path works without TTS access.
  final bool mute;
}

/// Per-segment outcome of a run (planned in dry-run, final otherwise).
class SegmentSummary {
  const SegmentSummary({
    required this.index,
    required this.route,
    required this.durationS,
    required this.status,
  });

  final int index;

  /// `i2v` | `kenburns` (same vocabulary as [SegmentState]).
  final String route;
  final int durationS;

  /// `planned` in a dry run; the [SegmentStatus] name otherwise.
  final String status;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'index': index,
    'route': route,
    'duration_s': durationS,
    'status': status,
  };
}

/// The run's outcome. [status] is `completed` | `dry_run` | `failed`.
class PipelineResult {
  const PipelineResult({
    required this.contentId,
    required this.status,
    required this.segments,
    required this.estimatedYuan,
    this.videoPath,
    this.srtPath,
    this.plan,
    this.error,
  });

  static const String statusCompleted = 'completed';
  static const String statusDryRun = 'dry_run';
  static const String statusFailed = 'failed';

  final String contentId;
  final String status;
  final String? videoPath;
  final String? srtPath;
  final List<SegmentSummary> segments;
  final double estimatedYuan;

  /// JSON-encoded dry-run cost plan (i2v/kenburns segment counts, billed
  /// i2v seconds, `seconds * 0.15` yuan estimate); null otherwise.
  final String? plan;

  /// The failure message when [status] is [statusFailed].
  final String? error;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'content_id': contentId,
    'status': status,
    if (videoPath != null) 'video_path': videoPath,
    if (srtPath != null) 'srt_path': srtPath,
    'segments': <dynamic>[for (final s in segments) s.toJson()],
    'estimated_yuan': estimatedYuan,
    if (plan != null) 'plan': jsonDecode(plan!),
    if (error != null) 'error': error,
  };
}

/// The 00–06 pipeline as one resumable run (spec §4 执行契约 / §6).
///
/// Step order: state init + `meta.json` → ingest → classify → select →
/// script → tts → (dryRun stops here with the cost plan) → render →
/// compose. `state.save()` lands before and after every step; a step is
/// skipped when its artifact exists ([stepDone]) **and** state says
/// succeeded. classify/select/script artifacts are written by this
/// orchestrator (the steps themselves are pure); tts/render/compose keep
/// their own internal idempotency on top.
class VivaPipeline {
  VivaPipeline({
    required this.cfg,
    QwenClient? llm,
    TtsClient? tts,
    I2vClient? i2v,
    ImageUrlProvider? urls,
    http.Client? http,
    this.baseDir = 'pipeline_out',
    this.preferProvider = 'base64',
    this.onProgress,
  }) {
    _llm = llm;
    _tts = tts;
    _i2v = i2v;
    _urls = urls;
    _http = http;
  }

  final PipelineConfig cfg;

  /// Artifact root; runs land in `$baseDir/<contentId>/`.
  final String baseDir;

  /// Default [ImageUrlProvider] preference (`'base64'` | `'dashscope'` |
  /// `'oss'`), used only when no explicit `urls` provider was injected
  /// (CLI `--prefer-provider`).
  final String preferProvider;

  /// Human-readable progress sink (step transitions + render segment
  /// detail); the CLI prints these to stderr. Null in tests.
  final void Function(String message)? onProgress;

  /// Reports one progress line to the host.
  void _emitProgress(String message) => onProgress?.call(message);

  QwenClient? _llm;
  TtsClient? _tts;
  I2vClient? _i2v;
  ImageUrlProvider? _urls;
  http.Client? _http;

  /// Photo id → capture time, populated by the classify step (fresh run or
  /// artifact load) so select keeps its time distribution on reruns.
  final Map<String, DateTime?> _capturedById = <String, DateTime?>{};

  http.Client get _client => _http ??= http.Client();

  QwenClient get _qwen => _llm ??= QwenClient(
    apiKey: cfg.requireApiKey(),
    baseUrl: cfg.baseUrl,
    client: _client,
  );

  TtsClient get _ttsClient => _tts ??= TtsClient(
    apiKey: cfg.requireApiKey(),
    client: _client,
    host: cfg.apiHost,
  );

  // QwenClient/I2vClient pin their model params as private named fields, so
  // only the apiKey/baseUrl/client are configurable here; their defaults
  // match pipeline_config.json (Task 14 report notes this gap).
  I2vClient get _i2vClient =>
      _i2v ??= I2vClient(apiKey: cfg.requireApiKey(), client: _client, host: cfg.apiHost);

  ImageUrlProvider get _urlProvider =>
      _urls ??= pickProvider(prefer: preferProvider, cfg: cfg, client: _client);

  /// Runs the pipeline once; a [PipelineError] from any step becomes a
  /// `failed` result (the error already landed in `state.json`).
  Future<PipelineResult> run(PipelineInput input) async {
    final invalid = _contentIdProblem(input.contentId);
    if (invalid != null) return _failed(input, invalid.message);
    final work = Workdir(baseDir, input.contentId);
    final state = ContentState.load(work.dir);
    _initRun(input, work, state);
    _emitProgress('开始：${input.photos.length} 张照片，方言=${input.dialect}，content_id=${input.contentId}');
    try {
      _emitProgress('[00] 收集照片…');
      final ingested = await _ingest(input, work, state);
      _emitProgress('[01] 识别照片内容（${ingested.length} 张）…');
      final classified = await _classify(ingested, work, state);
      final selected = _select(classified, ingested, input, work, state);
      _emitProgress('[02] 已选 ${selected.length} 张');
      _emitProgress('[03] 撰写口播文案…');
      final script = await _script(selected, work, state);
      _emitProgress('[04] 合成方言配音（${script.segments.length} 段）…');
      final audios = await _synthesize(script, input, work, state);
      if (input.dryRun) {
        _emitProgress('dry-run：到此为止，返回成本预估');
        return _dryRun(input, selected, script, audios);
      }
      _emitProgress('[05] 渲染视频段（i2v 每段约 1–3 分钟，请耐心）…');
      await _render(script, audios, selected, work, state);
      _emitProgress('[06] 合成成片…');
      await _compose(script, audios, work, state);
      final result = _completed(input, work, state);
      _emitProgress(
        '完成：${result.videoPath}（预估 ¥${result.estimatedYuan.toStringAsFixed(2)}）',
      );
      return result;
    } on PipelineError catch (e) {
      _emitProgress('失败：${e.message}（详见 ${work.dir}/state.json）');
      return _failed(input, e.message);
    }
  }

  /// contentId is a trusted input except for path traversal: reject `/`,
  /// `\` and `..` (and empty) as fatal before any directory is touched.
  PipelineError? _contentIdProblem(String contentId) {
    final traversal =
        contentId.contains('/') ||
        contentId.contains('\\') ||
        contentId.contains('..');
    if (contentId.isEmpty || traversal) {
      return PipelineError(ErrorClass.fatal, 'invalid content_id: $contentId');
    }
    return null;
  }

  /// Run bookkeeping: `meta.json` is written once (params snapshot), state
  /// carries contentId/params and is saved before the first step.
  void _initRun(PipelineInput input, Workdir work, ContentState state) {
    state.contentId = input.contentId;
    state.params = <String, String>{
      'dialect': input.dialect,
      'count': '${input.count}',
      'dry_run': '${input.dryRun}',
    };
    _writeMetaOnce(input, work);
    state.save();
  }

  void _writeMetaOnce(PipelineInput input, Workdir work) {
    final meta = work.file(ArtifactPaths.meta);
    if (meta.existsSync()) return;
    _writeJson(work, ArtifactPaths.meta, <String, dynamic>{
      'content_id': input.contentId,
      'photos': input.photos,
      'dialect': input.dialect,
      'dialect_label': resolveDialect(input.dialect).label,
      'count': input.count,
      'dry_run': input.dryRun,
      'llm_model': cfg.llmModel,
      'tts_model': cfg.ttsModel,
      'i2v_model': cfg.i2vModel,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// 00 ingest — always executed (internally idempotent: existing URL
  /// copies are reused without HTTP); local-path photos are bridged into
  /// `00_inputs/` so render can resolve every photo by id there.
  Future<List<IngestedPhoto>> _ingest(
    PipelineInput input,
    Workdir work,
    ContentState state,
  ) async {
    final record = state.step('ingest');
    _beginStep(record, state);
    try {
      final ingested = await runIngest(
        photos: input.photos,
        work: work,
        client: _client,
      );
      _bridgeLocalPhotos(ingested, work);
      _endStep(record, state);
      return ingested;
    } on PipelineError catch (e) {
      throw _failStep(record, state, e);
    }
  }

  /// Copies a local-path photo to `00_inputs/<id>.<ext>` (mirroring
  /// ingest's `<seq>_<name>` scheme: the id is exactly that stem). URL
  /// photos already live there; an existing copy is reused as-is.
  void _bridgeLocalPhotos(List<IngestedPhoto> photos, Workdir work) {
    final inputsDir = work.dirOf(ArtifactPaths.inputsDir);
    for (final photo in photos) {
      if (photo.file.path.startsWith(inputsDir.path)) continue;
      final name = photo.file.path.split(Platform.pathSeparator).last;
      final dot = name.lastIndexOf('.');
      final ext = dot < 0 ? '' : name.substring(dot);
      final target = work.file('${ArtifactPaths.inputsDir}/${photo.id}$ext');
      try {
        if (target.existsSync()) continue;
        inputsDir.createSync(recursive: true);
        photo.file.copySync(target.path);
      } on FileSystemException catch (e) {
        throw PipelineError(
          ErrorClass.fatal,
          'cannot bridge photo ${photo.id}: $e',
        );
      }
    }
  }

  /// 01 classify — orchestrator-owned artifact `01_classify.json` (entries
  /// carry `captured_at` so reruns keep select's time distribution).
  Future<List<PhotoInfo>> _classify(
    List<IngestedPhoto> ingested,
    Workdir work,
    ContentState state,
  ) async {
    if (_skippable(work, state, 'classify', ArtifactPaths.classify)) {
      final loaded = _loadClassify(work);
      if (loaded != null) return loaded;
    }
    final record = state.step('classify');
    _beginStep(record, state);
    try {
      final photos = await runClassify(photos: ingested, llm: _qwen);
      _storeClassify(work, photos, ingested);
      _endStep(record, state);
      return photos;
    } on PipelineError catch (e) {
      throw _failStep(record, state, e);
    }
  }

  void _storeClassify(
    Workdir work,
    List<PhotoInfo> photos,
    List<IngestedPhoto> ingested,
  ) {
    final fileById = <String, IngestedPhoto>{for (final p in ingested) p.id: p};
    _capturedById
      ..clear()
      ..addEntries(
        ingested.map((p) => MapEntry<String, DateTime?>(p.id, p.capturedAt)),
      );
    _writeJson(work, ArtifactPaths.classify, <dynamic>[
      for (final info in photos)
        <String, dynamic>{
          'id': info.id,
          'has_person': info.hasPerson,
          'quality': info.quality,
          'motion_hint': info.motionHint,
          'caption': info.caption,
          'person_unknown': info.personUnknown,
          'captured_at': fileById[info.id]?.capturedAt?.toIso8601String(),
        },
    ]);
  }

  /// Loads the classify artifact; a missing/invalid payload returns null so
  /// the step re-executes (self-healing, mirroring the tts step).
  List<PhotoInfo>? _loadClassify(Workdir work) {
    final Object? decoded;
    try {
      decoded = jsonDecode(work.file(ArtifactPaths.classify).readAsStringSync());
    } on Exception {
      return null;
    }
    if (decoded is! List) return null;
    final photos = <PhotoInfo>[];
    _capturedById.clear();
    for (final item in decoded) {
      final info = _photoInfoFromJson(item);
      if (info == null) return null;
      photos.add(info.$1);
      _capturedById[info.$1.id] = info.$2;
    }
    return photos;
  }

  (PhotoInfo, DateTime?)? _photoInfoFromJson(Object? item) {
    if (item is! Map<String, dynamic>) return null;
    final id = item['id'];
    final hasPerson = item['has_person'];
    final quality = item['quality'];
    if (id is! String || hasPerson is! bool || quality is! num) return null;
    final captured = item['captured_at'];
    return (
      PhotoInfo(
        id: id,
        hasPerson: hasPerson,
        quality: quality.toInt(),
        motionHint: item['motion_hint'] is String
            ? item['motion_hint'] as String
            : '',
        caption: item['caption'] is String ? item['caption'] as String : '',
        personUnknown: item['person_unknown'] == true,
      ),
      captured is String ? DateTime.tryParse(captured) : null,
    );
  }

  /// 02 select — artifact `02_select.json` holds the selected ids in order.
  List<PhotoInfo> _select(
    List<PhotoInfo> classified,
    List<IngestedPhoto> ingested,
    PipelineInput input,
    Workdir work,
    ContentState state,
  ) {
    if (_skippable(work, state, 'select', ArtifactPaths.select)) {
      final loaded = _loadSelect(work, classified);
      if (loaded != null) return loaded;
    }
    final record = state.step('select');
    _beginStep(record, state);
    final selected = selectPhotos(
      all: classified,
      order: _withCapturedAt(ingested),
      count: input.count,
    );
    _writeJson(
      work,
      ArtifactPaths.select,
      <dynamic>[for (final p in selected) p.id],
    );
    _endStep(record, state);
    return selected;
  }

  /// Ingest rerun loses `capturedAt` for already-downloaded files; the
  /// classify artifact carries it, so patch the order list back.
  List<IngestedPhoto> _withCapturedAt(List<IngestedPhoto> ingested) => [
    for (final p in ingested)
      IngestedPhoto(
        id: p.id,
        file: p.file,
        capturedAt: p.capturedAt ?? _capturedById[p.id],
        source: p.source,
      ),
  ];

  List<PhotoInfo>? _loadSelect(Workdir work, List<PhotoInfo> classified) {
    final Object? decoded;
    try {
      decoded = jsonDecode(work.file(ArtifactPaths.select).readAsStringSync());
    } on Exception {
      return null;
    }
    if (decoded is! List) return null;
    final byId = <String, PhotoInfo>{for (final p in classified) p.id: p};
    final selected = <PhotoInfo>[];
    for (final id in decoded) {
      final info = id is String ? byId[id] : null;
      if (info == null) return null;
      selected.add(info);
    }
    return selected;
  }

  /// 03 script — orchestrator-owned artifact `03_script.json`.
  Future<VideoScript> _script(
    List<PhotoInfo> selected,
    Workdir work,
    ContentState state,
  ) async {
    if (_skippable(work, state, 'script', ArtifactPaths.script)) {
      final loaded = _loadScript(work);
      if (loaded != null) return loaded;
    }
    final record = state.step('script');
    _beginStep(record, state);
    try {
      final script = await runScript(selected: selected, llm: _qwen);
      _writeJson(work, ArtifactPaths.script, <String, dynamic>{
        'total_chars': script.totalChars,
        'segments': <dynamic>[
          for (final s in script.segments)
            <String, dynamic>{
              'photo': s.photoId,
              'line': s.line,
              'motion_prompt': s.motionPrompt,
            },
        ],
      });
      _endStep(record, state);
      return script;
    } on PipelineError catch (e) {
      throw _failStep(record, state, e);
    }
  }

  VideoScript? _loadScript(Workdir work) {
    final Object? decoded;
    try {
      decoded = jsonDecode(work.file(ArtifactPaths.script).readAsStringSync());
    } on Exception {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final raw = decoded['segments'];
    if (raw is! List) return null;
    final segments = <SegmentScript>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) return null;
      final photo = item['photo'];
      final line = item['line'];
      if (photo is! String || line is! String) return null;
      final motion = item['motion_prompt'];
      segments.add(
        SegmentScript(
          photoId: photo,
          line: line,
          motionPrompt: motion is String ? motion : null,
        ),
      );
    }
    final total = segments.fold<int>(0, (sum, s) => sum + s.line.length);
    return VideoScript(segments: segments, totalChars: total);
  }

  /// 04 tts — the step self-skips on a valid `durations.json`. The mute
  /// path bypasses TTS entirely with local silent tracks.
  Future<List<TtsAudio>> _synthesize(
    VideoScript script,
    PipelineInput input,
    Workdir work,
    ContentState state,
  ) {
    if (input.mute) return _silence(script, work, state);
    return runTtsStep(
      script: script,
      dialect: resolveDialect(input.dialect),
      cfg: cfg,
      tts: _ttsClient,
      work: work,
      state: state,
    );
  }

  /// `--mute`: per-segment silent wavs via ffmpeg (anullsrc, 24kHz mono),
  /// paced from line length (~4 chars/s, clamped 2–6s). `durations.json`
  /// is written so a rerun skips regeneration, and the tts step record is
  /// marked succeeded like a real synthesis.
  Future<List<TtsAudio>> _silence(
    VideoScript script,
    Workdir work,
    ContentState state,
  ) async {
    final reused = _silentFromDurations(script, work);
    if (reused != null) return reused;
    final record = state.step('tts');
    record.status = StepStatus.running;
    record.attempts += 1;
    record.t.add('start');
    work.dirOf(ArtifactPaths.audioDir).createSync(recursive: true);
    final audios = <TtsAudio>[];
    for (var i = 0; i < script.segments.length; i++) {
      final seconds = _silentSeconds(script.segments[i].line);
      final wav = work.file('${ArtifactPaths.audioDir}/seg_$i.wav');
      final tmp = File('${wav.path}.tmp');
      await runFfmpeg(silentWavArgs(seconds: seconds, out: tmp));
      tmp.renameSync(wav.path);
      audios.add(TtsAudio(wav: wav, seconds: seconds));
      _emitProgress('[04] 段 $i：静音 ${seconds.toStringAsFixed(0)}s（mute）');
    }
    _writeJson(work, ArtifactPaths.durations, [
      for (final audio in audios) audio.seconds,
    ]);
    record.status = StepStatus.succeeded;
    record.t.add('end');
    state.save();
    return audios;
  }

  /// Reuses a previous mute run's `durations.json` + wavs when present and
  /// complete for this script's segment count; null otherwise.
  List<TtsAudio>? _silentFromDurations(VideoScript script, Workdir work) {
    if (!stepDone(work, ArtifactPaths.durations)) return null;
    final Object? decoded =
        jsonDecode(work.file(ArtifactPaths.durations).readAsStringSync());
    if (decoded is! List || decoded.length != script.segments.length) {
      return null;
    }
    return <TtsAudio>[
      for (var i = 0; i < decoded.length; i++)
        TtsAudio(
          wav: work.file('${ArtifactPaths.audioDir}/seg_$i.wav'),
          seconds: (decoded[i] as num).toDouble(),
        ),
    ];
  }

  /// Narration pace ≈4 chars/s, clamped to [2, 6] seconds per segment.
  double _silentSeconds(String line) {
    final paced = (line.length / 4).ceil();
    if (paced < 2) return 2;
    if (paced > 6) return 6;
    return paced.toDouble();
  }

  /// 05 render — the step self-skips on `05_clips/status.json`.
  Future<void> _render(
    VideoScript script,
    List<TtsAudio> audios,
    List<PhotoInfo> selected,
    Workdir work,
    ContentState state,
  ) {
    return runRenderStep(
      scripts: script.segments,
      audios: audios,
      photos: selected,
      work: work,
      state: state,
      i2v: _i2vClient,
      urls: _urlProvider,
      cfg: cfg,
      onProgress: onProgress,
    );
  }

  /// 06 compose — the step self-skips on `06_final.mp4` + `06_final.srt`.
  Future<void> _compose(
    VideoScript script,
    List<TtsAudio> audios,
    Workdir work,
    ContentState state,
  ) async {
    await runComposeStep(
      work: work,
      state: state,
      scripts: script.segments,
      audios: audios,
    );
  }

  /// Dry-run plan (spec §4: stop after 04): per-segment measured audio
  /// seconds → i2v vs Ken Burns segment counts, billed seconds and the
  /// `i2vSeconds * 0.15` yuan estimate.
  PipelineResult _dryRun(
    PipelineInput input,
    List<PhotoInfo> selected,
    VideoScript script,
    List<TtsAudio> audios,
  ) {
    final byId = <String, PhotoInfo>{for (final p in selected) p.id: p};
    final summaries = <SegmentSummary>[];
    var i2vSeconds = 0;
    var i2vCount = 0;
    for (var i = 0; i < script.segments.length; i++) {
      final info = byId[script.segments[i].photoId];
      final personRoute = info == null || info.hasPerson || info.personUnknown;
      final durationS = _clampDuration(audios[i].seconds);
      if (!personRoute) {
        i2vCount++;
        i2vSeconds += durationS;
      }
      summaries.add(
        SegmentSummary(
          index: i,
          route: personRoute ? SegmentState.routeKenburns : SegmentState.routeI2v,
          durationS: durationS,
          status: 'planned',
        ),
      );
    }
    final estimate = i2vSeconds * CostInfo.yuanPerSecond;
    return PipelineResult(
      contentId: input.contentId,
      status: PipelineResult.statusDryRun,
      segments: summaries,
      estimatedYuan: estimate,
      plan: jsonEncode(<String, dynamic>{
        'i2v_segments': i2vCount,
        'kenburns_segments': summaries.length - i2vCount,
        'i2v_seconds': i2vSeconds,
        'estimated_yuan': estimate,
      }),
    );
  }

  /// `ceil(audio seconds)` clamped into `[minClipS, maxClipS]` (spec §4-05,
  /// same rule as the render step).
  int _clampDuration(double seconds) {
    final ceil = seconds.ceil();
    if (ceil < cfg.minClipS) return cfg.minClipS;
    return ceil > cfg.maxClipS ? cfg.maxClipS : ceil;
  }

  PipelineResult _completed(PipelineInput input, Workdir work, ContentState state) {
    return PipelineResult(
      contentId: input.contentId,
      status: PipelineResult.statusCompleted,
      videoPath: work.file(ArtifactPaths.finalVideo).path,
      srtPath: work.file(ArtifactPaths.finalSrt).path,
      estimatedYuan: state.cost.estimatedYuan,
      segments: <SegmentSummary>[
        for (final s in state.segments)
          SegmentSummary(
            index: s.i,
            route: s.route,
            durationS: s.durationS,
            status: s.status.name,
          ),
      ],
    );
  }

  PipelineResult _failed(PipelineInput input, String message) => PipelineResult(
    contentId: input.contentId,
    status: PipelineResult.statusFailed,
    segments: const <SegmentSummary>[],
    estimatedYuan: 0,
    error: message,
  );

  /// Step-level skip contract (spec §4): artifact present AND state
  /// succeeded. tts/render/compose additionally self-skip internally.
  bool _skippable(
    Workdir work,
    ContentState state,
    String name,
    String artifactRel,
  ) =>
      stepDone(work, artifactRel) &&
      state.step(name).status == StepStatus.succeeded;

  void _beginStep(StepState record, ContentState state) {
    record.status = StepStatus.running;
    record.attempts += 1;
    record.t.add('start');
    state.save();
  }

  void _endStep(StepState record, ContentState state) {
    record.status = StepStatus.succeeded;
    record.t.add('end');
    state.save();
  }

  PipelineError _failStep(
    StepState record,
    ContentState state,
    PipelineError e,
  ) {
    record.status = StepStatus.failed;
    record.error = e;
    state.save();
    return e;
  }

  /// Atomically publishes a JSON artifact (tmp write + rename), so a
  /// non-empty file seen by [stepDone] is always complete.
  void _writeJson(Workdir work, String rel, Object? payload) {
    final dest = work.file(rel);
    final tmp = File('${dest.path}.tmp');
    try {
      tmp.writeAsStringSync(jsonEncode(payload), flush: true);
      tmp.renameSync(dest.path);
    } on FileSystemException catch (e) {
      throw PipelineError(ErrorClass.fatal, 'cannot write $rel: $e');
    }
  }
}
