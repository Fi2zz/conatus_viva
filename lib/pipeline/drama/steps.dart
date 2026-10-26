/// 8 个短剧工序的 wire 映射与状态推导（纯函数）。
///
/// 状态只从 `series` / `episode` / `storyboard` / `plan` / `state` 推导；
/// 前端不自己编状态。未接入工序由 [wired] 集合标记，UI 显示「未接入」。
library;

import '../render_plan.dart';
import '../storyboard.dart';
import 'episode.dart';
import 'hash.dart';
import 'hashes.dart';
import 'plan_view.dart';
import 'series.dart';
import 'state.dart';

/// 工序枚举；wire name 与原型一致。
enum DramaStep { split, story, cast, board, frame, voice, edit, pack }

/// 工序顺序（左栏 / 画布 / bundle 都按这个顺序）。
const List<DramaStep> kDramaStepOrder = <DramaStep>[
  DramaStep.split,
  DramaStep.story,
  DramaStep.cast,
  DramaStep.board,
  DramaStep.frame,
  DramaStep.voice,
  DramaStep.edit,
  DramaStep.pack,
];

/// P1 已接线的工序；其余返回 501 / 显示「未接入」。
const Set<DramaStep> kP1WiredSteps = <DramaStep>{
  DramaStep.split,
  DramaStep.story,
  DramaStep.board,
};

/// P2 已接线的工序（cast + frame）。
const Set<DramaStep> kDramaWiredSteps = <DramaStep>{
  DramaStep.split,
  DramaStep.story,
  DramaStep.cast,
  DramaStep.board,
  DramaStep.frame,
};

/// `DramaStep` → wire key。
String dramaStepKey(DramaStep step) => step.name;

/// wire key → `DramaStep`；未知返回 null。
DramaStep? dramaStepFromKey(String key) {
  for (final step in DramaStep.values) {
    if (step.name == key) return step;
  }
  return null;
}

/// 计划单输入 hash：分镜表 + 本集设置。
String dramaPlanHash({
  required Storyboard storyboard,
  required DramaEpisode episode,
}) => dramaHash(<String, Object?>{
  'storyboard': storyboard.toJson(),
  'settings': episode.settings.toJson(),
});

/// 一个工序的展示视图。
class DramaStepView {
  const DramaStepView({
    required this.key,
    required this.status,
    required this.costYuan,
    required this.summary,
    required this.detail,
    required this.wired,
  });

  final DramaStep key;
  final DramaStatus status;
  final double costYuan;
  final String summary;
  final String detail;
  final bool wired;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': dramaStepKey(key),
    'status': status.name,
    'cost_yuan': costYuan,
    'summary': summary,
    'detail': detail,
    'wired': wired,
  };
}

/// 从真实产物与状态推导 8 个工序。
List<DramaStepView> deriveDramaSteps({
  required DramaSeries series,
  required DramaEpisode episode,
  required Storyboard? storyboard,
  required Map<String, Object?>? planJson,
  required DramaEpisodeState state,
  required Set<DramaStep> wired,
}) {
  final shots = storyboard?.shots ?? const <Shot>[];
  final hasBoard = shots.isNotEmpty;
  final plan = planJson == null ? null : DramaPlanView(planJson);

  final referencedSpeakers = <String>{
    for (final shot in shots)
      if (shot.speaker != null && shot.speaker!.trim().isNotEmpty) shot.speaker!,
  };
  final approvedCast = referencedSpeakers
      .where((id) => series.cast[id]?.avatar?.approved == true)
      .length;
  final lineShots = <Shot>[
    for (final shot in shots)
      if (shot.line.trim().isNotEmpty &&
          shot.speaker != null &&
          shot.speaker!.trim().isNotEmpty)
        shot,
  ];
  final doneAudio = lineShots
      .where((shot) => state.shots[shot.id]?.audio.status == DramaStatus.succeeded)
      .length;

  const castSize = '1K';
  final castModel = series.defaults.castImageModel;
  final castHashes = <String, String>{
    for (final id in referencedSpeakers)
      if (series.cast[id] != null)
        id: dramaCastHash(
          member: series.cast[id]!,
          model: castModel,
          size: castSize,
        ),
  };
  final castStale = referencedSpeakers.any((id) {
    final avatar = series.cast[id]?.avatar;
    return avatar != null &&
        avatar.approved &&
        castHashes[id] != null &&
        avatar.sourceHash != castHashes[id];
  });
  final castCost = referencedSpeakers.fold<double>(
    0,
    (sum, id) => sum + (series.cast[id]?.avatar?.costYuan ?? 0),
  );

  final frameModel = series.defaults.frameImageModel;
  final clipModel = series.defaults.clipVideoModel;
  final resolution = series.defaults.resolution;
  var doneClips = 0;
  var frameStale = false;
  var frameCost = 0.0;
  if (plan != null) {
    for (final shot in shots) {
      final avatar = shot.speaker == null
          ? null
          : series.cast[shot.speaker]?.avatar;
      final avatarHash = avatar != null && avatar.approved
          ? avatar.sourceHash
          : null;
      final frameHash = dramaFrameHash(
        shot: shot,
        castAvatarHash: avatarHash,
        model: frameModel,
        size: castSize,
      );
      final route = plan.routeFor(shot.id);
      final i2vSeconds = route == ShotRoute.i2v
          ? plan.i2vSecondsFor(shot.id)
          : 0;
      final t2vModel = series.defaults.t2vModel;
      final clipHash = dramaClipHash(
        shot: shot,
        frameHash: frameHash,
        route: route.name,
        model: route == ShotRoute.i2v
            ? clipModel
            : (route == ShotRoute.t2v ? t2vModel : 'ffmpeg'),
        resolution: resolution,
        i2vSeconds: i2vSeconds,
      );
      final degradedHash = route == ShotRoute.i2v
          ? dramaClipHash(
              shot: shot,
              frameHash: frameHash,
              route: ShotRoute.kenburns.name,
              model: 'ffmpeg',
              resolution: resolution,
              i2vSeconds: 0,
            )
          : null;
      final shotState = state.shots[shot.id];
      final frameArtifact = shotState?.frame;
      final clipArtifact = shotState?.clip;
      if (route != ShotRoute.t2v &&
          frameArtifact != null &&
          frameArtifact.status == DramaStatus.succeeded &&
          frameArtifact.sourceHash != frameHash) {
        frameStale = true;
      }
      final clipCurrent = clipArtifact != null &&
          clipArtifact.status == DramaStatus.succeeded &&
          (clipArtifact.sourceHash == clipHash ||
              (degradedHash != null &&
                  clipArtifact.sourceHash == degradedHash));
      if (clipArtifact != null &&
          clipArtifact.status == DramaStatus.succeeded &&
          !clipCurrent) {
        frameStale = true;
      }
      if (clipCurrent) {
        doneClips += 1;
      }
      frameCost += (frameArtifact?.costYuan ?? 0) + (clipArtifact?.costYuan ?? 0);
    }
  }

  DramaStatus derived(DramaStep step) {
    switch (step) {
      case DramaStep.split:
        final text = episode.source.text;
        final hashOk = episode.story.sourceHash == dramaHash(<String, Object?>{'text': text});
        return text.trim().isNotEmpty && episode.story.beats.isNotEmpty && hashOk
            ? DramaStatus.succeeded
            : DramaStatus.pending;
      case DramaStep.story:
        return episode.story.logline.trim().isNotEmpty &&
                episode.story.synopsis.trim().isNotEmpty &&
                series.cast.isNotEmpty
            ? DramaStatus.succeeded
            : DramaStatus.pending;
      case DramaStep.cast:
        if (!hasBoard) return DramaStatus.pending;
        if (referencedSpeakers.isEmpty) return DramaStatus.succeeded;
        if (castStale) return DramaStatus.stale;
        return approvedCast == referencedSpeakers.length
            ? DramaStatus.succeeded
            : DramaStatus.pending;
      case DramaStep.board:
        if (!hasBoard || planJson == null) return DramaStatus.pending;
        return state.planHash == dramaPlanHash(storyboard: storyboard!, episode: episode)
            ? DramaStatus.succeeded
            : DramaStatus.pending;
      case DramaStep.frame:
        if (!hasBoard || plan == null) return DramaStatus.pending;
        if (doneClips == shots.length) return DramaStatus.succeeded;
        if (frameStale) return DramaStatus.stale;
        return DramaStatus.pending;
      case DramaStep.voice:
        if (!hasBoard) return DramaStatus.pending;
        if (lineShots.isEmpty) return DramaStatus.skipped;
        return doneAudio == lineShots.length ? DramaStatus.succeeded : DramaStatus.pending;
      case DramaStep.edit:
      case DramaStep.pack:
        return DramaStatus.pending;
    }
  }

  DramaStatus effective(DramaStep step) {
    final run = state.steps[dramaStepKey(step)];
    if (run != null && run.status == DramaStatus.running) {
      return DramaStatus.running;
    }
    final next = derived(step);
    if (next == DramaStatus.succeeded) return next;
    if (run != null &&
        (run.status == DramaStatus.failed ||
            run.status == DramaStatus.interrupted)) {
      return run.status;
    }
    return next;
  }

  String summary(DramaStep step) {
    switch (step) {
      case DramaStep.split:
        return '${episode.story.beats.length} 拍';
      case DramaStep.story:
        return '${series.cast.length} 角色';
      case DramaStep.cast:
        return '$approvedCast/${referencedSpeakers.length} 角色';
      case DramaStep.board:
        return '${shots.length} 镜';
      case DramaStep.frame:
        return '$doneClips/${shots.length} 镜';
      case DramaStep.voice:
        return '$doneAudio/${lineShots.length} 句';
      case DramaStep.edit:
        return wired.contains(step) ? '待接入' : '未接入';
      case DramaStep.pack:
        return wired.contains(step) ? '待接入' : '未接入';
    }
  }

  return <DramaStepView>[
    for (final step in kDramaStepOrder)
      DramaStepView(
        key: step,
        status: effective(step),
        costYuan: switch (step) {
          DramaStep.cast => castCost,
          DramaStep.frame => frameCost,
          _ => 0.0,
        },
        summary: summary(step),
        detail: state.steps[dramaStepKey(step)]?.error ?? '',
        wired: wired.contains(step),
      ),
  ];
}

/// 从既有 [RenderPlan] 生成 `plan.json` 的 wire map（纯展示用）。
Map<String, Object?> planToJson(RenderPlan plan) => plan.toJson();
