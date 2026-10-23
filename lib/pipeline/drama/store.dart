/// 短剧剧集文件存储（纯 Dart，无 Flutter 依赖）。
///
/// 目录布局：
/// ```
/// <root>/series/<series_id>/series.json
/// <root>/series/<series_id>/episodes/<episode_id>/{episode,storyboard,plan,state}.json
/// ```
/// 所有 JSON 写入都先写 `<file>.tmp` 再 rename，避免半截文件；读取缺失
/// 文件抛 [FileSystemException]（`state` 除外，缺失返回空状态）。
library;

import 'dart:convert';
import 'dart:io';

import '../errors.dart';
import '../storyboard.dart';
import 'episode.dart';
import 'ids.dart';
import 'json.dart';
import 'series.dart';
import 'state.dart';

/// 剧集文件存储。
class DramaStore {
  DramaStore({required String rootDir})
    : rootDir = Directory(rootDir).absolute.path;

  /// 剧集根目录（通常 `pipeline_out/drama`）。
  final String rootDir;

  static const String seriesFileName = 'series.json';
  static const String episodeFileName = 'episode.json';
  static const String storyboardFileName = 'storyboard.json';
  static const String planFileName = 'plan.json';
  static const String stateFileName = 'state.json';

  String get _seriesRoot => '$rootDir/series';

  /// `<root>/series/<id>`。
  String seriesDir(String seriesId) {
    requireDramaId(seriesId, 'series_id');
    return '$_seriesRoot/$seriesId';
  }

  /// `<root>/series/<sid>/episodes/<eid>`。
  String episodeDir(String seriesId, String episodeId) {
    requireDramaId(episodeId, 'episode_id');
    return '${seriesDir(seriesId)}/episodes/$episodeId';
  }

  List<DramaSeries> listSeries() {
    final dir = Directory(_seriesRoot);
    if (!dir.existsSync()) return const <DramaSeries>[];
    final entries = dir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final out = <DramaSeries>[];
    for (final entry in entries) {
      try {
        out.add(readSeries(_basename(entry.path)));
      } on Object {
        // 单个损坏的剧不应拖垮整个列表。
      }
    }
    return out;
  }

  DramaSeries createSeries(DramaSeries series) {
    final dir = Directory(seriesDir(series.seriesId));
    if (dir.existsSync()) throw StateError('series_exists');
    dir.createSync(recursive: true);
    _writeJson('${dir.path}/$seriesFileName', series.toJson());
    return series;
  }

  DramaSeries readSeries(String seriesId) {
    final json = _readJson('${seriesDir(seriesId)}/$seriesFileName');
    return DramaSeries.fromJson(json);
  }

  void writeSeries(DramaSeries series) {
    _writeJson('${seriesDir(series.seriesId)}/$seriesFileName', series.toJson());
  }

  void deleteSeries(String seriesId) {
    final dir = Directory(seriesDir(seriesId));
    if (!dir.existsSync()) {
      throw FileSystemException('series not found', dir.path);
    }
    dir.deleteSync(recursive: true);
  }

  List<DramaEpisode> listEpisodes(String seriesId) {
    final dir = Directory('${seriesDir(seriesId)}/episodes');
    if (!dir.existsSync()) return const <DramaEpisode>[];
    final entries = dir.listSync().whereType<Directory>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final out = <DramaEpisode>[];
    for (final entry in entries) {
      try {
        out.add(readEpisode(seriesId, _basename(entry.path)));
      } on Object {
        // 单个损坏的集不应拖垮剧详情。
      }
    }
    return out;
  }

  DramaEpisode createEpisode(DramaEpisode episode) {
    // 先确认剧存在；缺失会抛 FileSystemException。
    readSeries(episode.seriesId);
    final dir = Directory(episodeDir(episode.seriesId, episode.episodeId));
    if (dir.existsSync()) throw StateError('episode_exists');
    dir.createSync(recursive: true);
    _writeJson('${dir.path}/$episodeFileName', episode.toJson());
    return episode;
  }

  DramaEpisode readEpisode(String seriesId, String episodeId) {
    final json = _readJson('${episodeDir(seriesId, episodeId)}/$episodeFileName');
    return DramaEpisode.fromJson(json);
  }

  void writeEpisode(DramaEpisode episode) {
    _writeJson(
      '${episodeDir(episode.seriesId, episode.episodeId)}/$episodeFileName',
      episode.toJson(),
    );
  }

  void deleteEpisode(String seriesId, String episodeId) {
    final dir = Directory(episodeDir(seriesId, episodeId));
    if (!dir.existsSync()) {
      throw FileSystemException('episode not found', dir.path);
    }
    dir.deleteSync(recursive: true);
  }

  Storyboard? readStoryboard(String seriesId, String episodeId) {
    final json = _readJsonOrNull(
      '${episodeDir(seriesId, episodeId)}/$storyboardFileName',
    );
    return json == null ? null : Storyboard.fromJson(json);
  }

  void writeStoryboard(
    String seriesId,
    String episodeId,
    Storyboard storyboard,
  ) {
    if (storyboard.contentId != episodeId) {
      throw ArgumentError.value(
        storyboard.contentId,
        'storyboard.content_id',
        'must equal episode id $episodeId',
      );
    }
    _writeJson(
      '${episodeDir(seriesId, episodeId)}/$storyboardFileName',
      storyboard.toJson(),
    );
  }

  Map<String, Object?>? readPlanJson(String seriesId, String episodeId) =>
      _readJsonOrNull('${episodeDir(seriesId, episodeId)}/$planFileName');

  void writePlanJson(
    String seriesId,
    String episodeId,
    Map<String, Object?> plan,
  ) {
    _writeJson('${episodeDir(seriesId, episodeId)}/$planFileName', plan);
  }

  DramaEpisodeState readState(String seriesId, String episodeId) {
    final json = _readJsonOrNull(
      '${episodeDir(seriesId, episodeId)}/$stateFileName',
    );
    if (json == null) return DramaEpisodeState.empty(seriesId, episodeId);
    return DramaEpisodeState.fromJson(json);
  }

  void writeState(
    String seriesId,
    String episodeId,
    DramaEpisodeState state,
  ) {
    if (state.seriesId != seriesId || state.episodeId != episodeId) {
      throw ArgumentError('state ids do not match $seriesId/$episodeId');
    }
    _writeJson('${episodeDir(seriesId, episodeId)}/$stateFileName', state.toJson());
  }

  /// 解析集目录下的相对资源路径；拒绝绝对路径、`..` 与逃逸。
  File assetFile(String seriesId, String episodeId, String relativePath) {
    if (relativePath.isEmpty ||
        relativePath.startsWith('/') ||
        relativePath.startsWith('\\') ||
        relativePath.contains('\\')) {
      throw ArgumentError.value(relativePath, 'relativePath', 'unsafe path');
    }
    final root = Directory(episodeDir(seriesId, episodeId)).absolute.path;
    final resolved = Uri.file('$root/$relativePath').normalizePath().toFilePath();
    if (resolved != root && !resolved.startsWith('$root/')) {
      throw ArgumentError.value(relativePath, 'relativePath', 'path escape');
    }
    return File(resolved);
  }

  Map<String, Object?> _readJson(String path) {
    final decoded = jsonDecode(File(path).readAsStringSync());
    return asJsonMap(decoded, path);
  }

  Map<String, Object?>? _readJsonOrNull(String path) {
    final file = File(path);
    if (!file.existsSync()) return null;
    return _readJson(path);
  }

  void _writeJson(String path, Map<String, Object?> json) {
    final file = File(path);
    file.parent.createSync(recursive: true);
    final text = '${const JsonEncoder.withIndent('  ').convert(json)}\n';
    final tmp = File('$path.tmp');
    try {
      tmp.writeAsStringSync(text, flush: true);
      tmp.renameSync(path);
    } on FileSystemException {
      rethrow;
    } on Object catch (e) {
      throw PipelineError(ErrorClass.fatal, '写入失败 $path：$e');
    }
  }

  String _basename(String path) {
    final parts = path.split(Platform.pathSeparator);
    return parts.isEmpty ? path : parts.last;
  }
}
