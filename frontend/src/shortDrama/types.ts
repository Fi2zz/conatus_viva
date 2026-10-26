/// 短剧工作台后端 wire 类型（snake_case，与 Dart toJson 对齐）。
///
/// 这里只放类型，不放计算；计划单复用 `model.ts` 的 `Plan`。
import type { Plan, ShotKind, ShotPriority } from "./model";

export type StepKey =
  | "split"
  | "story"
  | "cast"
  | "board"
  | "frame"
  | "voice"
  | "edit"
  | "pack";

export type StepStatus =
  | "pending"
  | "running"
  | "succeeded"
  | "failed"
  | "stale"
  | "skipped"
  | "interrupted";

export interface StepView {
  key: StepKey;
  status: StepStatus;
  cost_yuan: number;
  summary: string;
  detail: string;
  wired: boolean;
}

export interface DramaBeat {
  id: string;
  label: string;
  summary: string;
  target_s?: number | null;
  weight?: number | null;
}

export interface DramaCastAvatar {
  path: string;
  source_hash: string;
  model: string;
  cost_yuan: number;
  approved: boolean;
}

export interface DramaCastMember {
  name: string;
  description: string;
  voice_id: string | null;
  dialect: string | null;
  avatar: DramaCastAvatar | null;
}

export interface DramaSeries {
  series_id: string;
  title: string;
  logline: string;
  dialect: string;
  frame: string;
  content_type: string;
  planned_episodes: number;
  defaults: {
    total_budget_yuan: number;
    i2v_budget_yuan: number;
    max_i2v_seconds: number;
    cast_image_model: string;
    frame_image_model: string;
    clip_video_model: string;
    t2v_model: string;
    resolution: string;
  };
  beat_template: DramaBeat[];
  cast: Record<string, DramaCastMember>;
}

export interface DramaSeriesSummary extends DramaSeries {
  episode_count: number;
}

export interface DramaEpisode {
  series_id: string;
  episode_id: string;
  number: number;
  title: string;
  source: { kind: string; text: string };
  story: {
    logline: string;
    synopsis: string;
    beats: DramaBeat[];
    source_hash: string | null;
    prompt_version: number;
    model: string | null;
  };
  settings: {
    dialect: string;
    frame: string;
    total_budget_yuan: number;
    i2v_budget_yuan: number;
    max_i2v_seconds: number;
    target_duration_s: number;
  };
}

export interface EpisodeSummary {
  episode_id: string;
  number: number;
  title: string;
}

export interface StoryboardShot {
  id: string;
  kind: ShotKind;
  framing: string;
  speaker: string | null;
  line: string;
  duration_s: number | null;
  priority: ShotPriority;
  prop: string | null;
  motion: string | null;
  visual: string | null;
}

export interface Storyboard {
  content_id: string;
  title: string;
  dialect: string | null;
  frame: string;
  budget_yuan: number;
  cast: Record<
    string,
    { name: string; voice_id?: string | null; dialect?: string | null }
  >;
  shots: StoryboardShot[];
}

export interface EpisodeState {
  series_id: string;
  episode_id: string;
  storyboard_hash: string | null;
  plan_hash: string | null;
  steps: Record<
    string,
    { status: StepStatus; attempts: number; error: string | null }
  >;
  shots: Record<string, DramaShotState>;
  active_run: string | null;
  cost: { actual_yuan: number; estimated_remaining_yuan: number };
  warnings: string[];
}

export interface DramaArtifact {
  status: StepStatus;
  path: string | null;
  source_hash: string | null;
  model: string | null;
  cost_yuan: number | null;
  duration_s: number | null;
  error: string | null;
}

export interface DramaShotState {
  frame: DramaArtifact;
  clip: DramaArtifact;
  audio: DramaArtifact;
}

export interface EpisodeBundle {
  series: DramaSeries;
  episode: DramaEpisode;
  storyboard: Storyboard | null;
  plan: Plan | null;
  state: EpisodeState;
  steps: StepView[];
  capabilities: Record<string, boolean>;
}

export interface DramaEstimate {
  items: Array<{
    kind: string;
    id: string;
    model: string;
    quantity: number;
    unit: string;
    price_yuan: number;
    subtotal_yuan: number;
    estimated: boolean;
  }>;
  total_estimated_yuan: number;
  i2v_estimated_yuan: number;
  unpriced: Array<{ kind: string; id: string; reason: string }>;
  budget: {
    total_yuan: number;
    actual_yuan: number;
    remaining_yuan: number;
    i2v_total_yuan: number;
    i2v_actual_yuan: number;
    i2v_remaining_yuan: number;
  };
}

export interface EstimateInput {
  step: "story" | "storyboard" | "cast" | "frame";
  cast_ids?: string[];
  shot_ids?: string[];
  target?: "frame" | "clip" | "all";
  force?: boolean;
}

export interface DramaRunItem {
  id: string;
  kind: string;
  status: StepStatus;
  path: string | null;
  cost_yuan: number | null;
  error: string | null;
}

export interface DramaRun {
  run_id: string;
  status: "running" | "completed" | "failed" | "cancelled";
  step: "cast" | "frame";
  items: DramaRunItem[];
  logs: string[];
  actual_yuan: number;
  error: string | null;
}

export interface StoryExtractResult {
  logline: string;
  synopsis: string;
  source_hash: string;
  beats: DramaBeat[];
  cast_new: Record<string, DramaCastMember>;
  cast_updates: Record<string, DramaCastMember>;
  warnings: string[];
}

export interface StoryboardDraftResult {
  storyboard: Storyboard;
  warnings: string[];
}
