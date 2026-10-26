/// 投放包清单：记录成片、字幕、封面与成本，纯数据构建。
library;

Map<String, Object?> buildPackageManifest({
  required String contentId,
  required String title,
  required double durationS,
  required int shotCount,
  required double actualYuan,
  required List<Map<String, Object?>> files,
  required String createdAt,
}) => <String, Object?>{
  'content_id': contentId,
  'title': title,
  'duration_s': durationS,
  'shot_count': shotCount,
  'actual_yuan': actualYuan,
  'files': files,
  'created_at': createdAt,
};
