import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../errors.dart';
import '../ffmpeg.dart';

/// One synthesized narration track: [wav] is already persisted on disk and
/// [seconds] is its ffprobe-measured duration.
class TtsAudio {
  const TtsAudio({required this.wav, required this.seconds});

  /// The wav file — always stored locally before this instance escapes
  /// (spec §3: 音频 URL 24 小时有效，先转存本地再继续).
  final File wav;

  /// ffprobe-measured duration in seconds (`mediaDurationSeconds`).
  final double seconds;
}

/// DashScope SpeechSynthesizer client for the 04 tts step (spec §4「04 tts」).
///
/// Request body (brief contract + Global Constraints): `model`, an `input`
/// object `{text, voice, format: 'wav', sample_rate: 24000}` where `text`
/// carries the `[very slowly]` control prefix (spec §4-04), plus the
/// instruction parameter — **the param name follows the model family**:
/// `instruction` for `qwen-audio-*`, `instructions` otherwise.
///
/// Reply handling: the non-streaming API answers with a JSON envelope whose
/// `output.audio.url` is an audio file valid for 24h (spec §3). The URL is
/// downloaded and stored before [synth] returns; a reply whose bytes *are*
/// the audio (`audio/*` content type or a RIFF/`{` body) is stored directly.
///
/// Error mapping (spec §6 错误分类与重试, mirrors the QwenClient patterns):
/// - 408 / 429 / 5xx / network failure / an unusable reply → transient,
///   retried once with 1s backoff inside [synth];
/// - 401 / 400 and any other non-2xx status → fatal, fail fast without
///   consuming retries.
class TtsClient {
  TtsClient({required this._apiKey, http.Client? client})
    : _client = client ?? http.Client();

  /// Native speech-synthesis endpoint — the https counterpart of the
  /// `wss://` realtime API (pinned by the brief for every TTS model).
  static const String endpoint =
      'https://dashscope.aliyuncs.com/api/v1/services/audio/tts/SpeechSynthesizer';

  /// Control tag prefix slowing narration down (spec §4-04). Tags enter the
  /// TTS text only, never the subtitles (spec §4-06).
  static const String slowPrefix = '[very slowly]';

  /// Backoff before the single transient retry of one [synth] call.
  static const Duration _retryDelay = Duration(seconds: 1);

  final String _apiKey;
  final http.Client _client;

  /// Waits between retries. Tests replace this with a no-op so the suite
  /// never waits out the real backoff.
  Future<void> Function(Duration delay) sleep = _realSleep;

  static Future<void> _realSleep(Duration delay) => Future<void>.delayed(delay);

  /// Synthesizes [text] once and returns the stored wav with its measured
  /// duration.
  ///
  /// [voiceId] wins over [fallbackVoice]; a [ErrorClass.transient] failure
  /// is retried once, then rethrown — callers (runTtsStep) own the
  /// dialect → mandarin degradation on top of this.
  Future<TtsAudio> synth({
    required String text,
    required String model,
    String? voiceId,
    String? fallbackVoice,
    required String instruction,
  }) async {
    final voice = voiceId ?? fallbackVoice;
    for (var attempt = 0; ; attempt++) {
      try {
        return await _synthOnce(
          text: text,
          model: model,
          voice: voice,
          instruction: instruction,
        );
      } on PipelineError catch (e) {
        if (e.cls != ErrorClass.transient || attempt >= 1) rethrow;
        await sleep(_retryDelay);
      }
    }
  }

  Future<TtsAudio> _synthOnce({
    required String text,
    required String model,
    required String? voice,
    required String instruction,
  }) async {
    final bytes = await _requestAudio(
      text: text,
      model: model,
      voice: voice,
      instruction: instruction,
    );
    return _store(bytes);
  }

  /// One request/reply cycle (no retry): POST the synthesis body, resolve
  /// the reply to raw audio bytes.
  Future<List<int>> _requestAudio({
    required String text,
    required String model,
    required String? voice,
    required String instruction,
  }) async {
    final http.Response response;
    try {
      response = await _client.post(
        Uri.parse(endpoint),
        headers: <String, String>{
          'Authorization': 'Bearer $_apiKey',
          'content-type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{
          'model': model,
          'input': <String, dynamic>{
            'text': '$slowPrefix$text',
            'voice': voice,
            'format': 'wav',
            'sample_rate': 24000,
          },
          // Global Constraints: param name follows the model family.
          if (model.startsWith('qwen-audio'))
            'instruction': instruction
          else
            'instructions': instruction,
        }),
      );
    } on http.ClientException catch (e) {
      throw PipelineError(ErrorClass.transient, 'TTS network error: $e');
    } on IOException catch (e) {
      throw PipelineError(ErrorClass.transient, 'TTS network error: $e');
    } on TimeoutException catch (e) {
      throw PipelineError(ErrorClass.transient, 'TTS timeout: $e');
    }
    if (response.statusCode != 200) throw _statusError(response);

    final audio = await _audioFrom(response);
    if (audio.isEmpty) {
      throw PipelineError(ErrorClass.transient, 'TTS reply carried no audio');
    }
    return audio;
  }

  /// Resolves a 200 reply to audio bytes: a JSON envelope hands back a 24h
  /// `output.audio.url` which is downloaded immediately (spec §3/§4 — the
  /// bytes must be on disk before anything downstream runs), anything else
  /// is taken as the audio itself.
  Future<List<int>> _audioFrom(http.Response response) async {
    if (!_looksLikeJson(response)) return response.bodyBytes;

    final url = _audioUrl(response.bodyBytes);
    final http.Response download;
    try {
      download = await _client.get(Uri.parse(url));
    } on FormatException catch (e) {
      throw PipelineError(ErrorClass.transient, 'TTS audio url invalid: $e');
    } on http.ClientException catch (e) {
      throw PipelineError(ErrorClass.transient, 'TTS download error: $e');
    } on IOException catch (e) {
      throw PipelineError(ErrorClass.transient, 'TTS download error: $e');
    }
    if (download.statusCode != 200) throw _statusError(download);
    return download.bodyBytes;
  }

  /// A JSON reply is declared by its content type; the leading `{` check
  /// covers replies that omit it.
  static bool _looksLikeJson(http.Response response) {
    for (final entry in response.headers.entries) {
      if (entry.key.toLowerCase() == 'content-type' &&
          entry.value.toLowerCase().contains('json')) {
        return true;
      }
    }
    return response.bodyBytes.isNotEmpty && response.bodyBytes.first == 0x7B;
  }

  /// `output.audio.url` of the non-streaming envelope (falling back to a
  /// top-level `audio.url`). A JSON reply without one is transient — a
  /// truncated gateway envelope is worth one more attempt.
  static String _audioUrl(List<int> body) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
    } on FormatException catch (e) {
      throw PipelineError(ErrorClass.transient, 'TTS reply is not JSON: $e');
    }
    String? url;
    if (decoded is Map<String, dynamic>) {
      final output = decoded['output'];
      final audio = output is Map ? output['audio'] : decoded['audio'];
      if (audio is Map && audio['url'] is String) {
        url = audio['url'] as String;
      }
    }
    if (url == null || url.isEmpty) {
      throw PipelineError(
        ErrorClass.transient,
        'TTS reply carries no audio url',
      );
    }
    return url;
  }

  /// Classified by status first (spec §6): 408/429/5xx are transient, every
  /// other non-2xx (401 bad key, 400 bad params) fails fast as fatal.
  static PipelineError _statusError(http.Response response) {
    final status = response.statusCode;
    final detail = _errorDetail(response);
    if (status == 408 || status == 429 || status >= 500) {
      return PipelineError(ErrorClass.transient, 'TTS HTTP $status: $detail');
    }
    return PipelineError(ErrorClass.fatal, 'TTS HTTP $status: $detail');
  }

  /// The provider's error message when the body carries one, else the
  /// (truncated) raw body — this text lands in `state.json`.
  static String _errorDetail(http.Response response) {
    final raw = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
    if (raw.isEmpty) return '<empty body>';
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic> && error['message'] is String) {
          return error['message'] as String;
        }
        if (error is String) return error;
        if (decoded['message'] is String) return decoded['message'] as String;
      }
    } on FormatException {
      // Non-JSON error body (e.g. an HTML gateway page) — fall through.
    }
    return raw.length > 300 ? '${raw.substring(0, 300)}…' : raw;
  }

  /// Persists [bytes] to a fresh temp file (write + rename) and measures it
  /// with ffprobe — the bytes never sit only in memory.
  ///
  /// An unusable reply body (junk bytes the server may still fix next time)
  /// is transient; a local disk failure is fatal (it will not self-heal).
  Future<TtsAudio> _store(List<int> bytes) async {
    final Directory dir;
    final File wav;
    try {
      dir = Directory.systemTemp.createTempSync('conatus_tts_');
      final part = File('${dir.path}/audio.wav.tmp');
      part.writeAsBytesSync(bytes, flush: true);
      wav = part.renameSync('${dir.path}/audio.wav');
    } on FileSystemException catch (e) {
      throw PipelineError(ErrorClass.fatal, 'cannot store audio: $e');
    }
    final double seconds;
    try {
      seconds = await mediaDurationSeconds(wav);
    } on FfmpegException catch (e) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {
        // Best-effort temp cleanup — never mask the original failure.
      }
      throw PipelineError(ErrorClass.transient, 'unusable audio: $e');
    }
    return TtsAudio(wav: wav, seconds: seconds);
  }
}
