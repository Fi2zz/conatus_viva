/// Error taxonomy for the pipeline (spec §6「错误分类与重试」).
enum ErrorClass {
  /// Network timeout / 5xx / rate limit — retry ×2 with exponential backoff.
  transient,

  /// IP or content audit rejection (e.g. `DataInspectionFailed`) — never
  /// retry; the segment degrades to Ken Burns.
  auditReject,

  /// Interrupted run whose persisted `task_id` may still be polled (<24h) —
  /// resume polling instead of resubmitting.
  staleTask,

  /// Unrecoverable (bad key, invalid params, budget exceeded) — fail fast
  /// without consuming retries.
  fatal,
}

/// Stable snake_case names used in `state.json`
/// (`transient`, `audit_reject`, `stale_task`, `fatal`).
String errorClassName(ErrorClass cls) {
  switch (cls) {
    case ErrorClass.transient:
      return 'transient';
    case ErrorClass.auditReject:
      return 'audit_reject';
    case ErrorClass.staleTask:
      return 'stale_task';
    case ErrorClass.fatal:
      return 'fatal';
  }
}

/// Inverse of [errorClassName]; throws [ArgumentError] on an unknown name
/// (callers treat that as a corrupt state file).
ErrorClass errorClassFromName(String name) {
  switch (name) {
    case 'transient':
      return ErrorClass.transient;
    case 'audit_reject':
      return ErrorClass.auditReject;
    case 'stale_task':
      return ErrorClass.staleTask;
    case 'fatal':
      return ErrorClass.fatal;
    default:
      throw ArgumentError('unknown error class: $name');
  }
}

/// A classified pipeline error. Thrown (or recorded in `state.json`) so the
/// rerun table in spec §6 can pick the right recovery strategy from [cls].
class PipelineError implements Exception {
  const PipelineError(this.cls, this.message, {this.remoteCode});

  final ErrorClass cls;
  final String message;

  /// Provider-side code when one exists (e.g. DashScope `code`).
  final String? remoteCode;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'class': errorClassName(cls),
    'msg': message,
    if (remoteCode != null) 'code': remoteCode,
  };

  static PipelineError fromJson(Map<String, dynamic> json) {
    final cls = json['class'];
    final msg = json['msg'];
    final code = json['code'];
    if (cls is! String || msg is! String) {
      throw const FormatException('error object must have string class/msg');
    }
    return PipelineError(
      errorClassFromName(cls),
      msg,
      remoteCode: code is String ? code : null,
    );
  }

  @override
  String toString() =>
      'PipelineError(${errorClassName(cls)}): $message'
      '${remoteCode == null ? '' : ' (code: $remoteCode)'}';
}
