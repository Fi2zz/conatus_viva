/// 可编辑分镜草稿 ↔ 后端 Storyboard wire。
///
/// 组件只持有字符串输入；这里负责把空串 / 数字转换回 wire，并在保存前
/// 做必填、唯一、枚举与时长校验。所有错误文案是中文，直接展示给用户。
import type {
  Storyboard,
  StoryboardShot,
} from "./types";
import type { ShotKind, ShotPriority } from "./model";

export interface ShotDraft {
  id: string;
  kind: ShotKind;
  framing: string;
  speaker: string;
  line: string;
  duration: string;
  priority: ShotPriority;
  prop: string;
  motion: string;
  visual: string;
}

export interface StoryboardDraft {
  content_id: string;
  title: string;
  dialect: string;
  frame: string;
  budget_yuan: number;
  cast: Storyboard["cast"];
  shots: ShotDraft[];
}

const SHOT_KINDS: ShotKind[] = [
  "speak_off",
  "insert",
  "listen_face",
  "action",
  "establishing",
];

const PRIORITIES: ShotPriority[] = ["hook", "turn", "payoff", "normal"];

function nullable(value: string): string | null {
  const trimmed = value.trim();
  return trimmed === "" ? null : trimmed;
}

function draftShot(shot: StoryboardShot): ShotDraft {
  return {
    id: shot.id,
    kind: shot.kind,
    framing: shot.framing,
    speaker: shot.speaker ?? "",
    line: shot.line,
    duration: shot.duration_s === null ? "" : shot.duration_s.toFixed(1),
    priority: shot.priority,
    prop: shot.prop ?? "",
    motion: shot.motion ?? "",
    visual: shot.visual ?? "",
  };
}

export function storyboardToDraft(board: Storyboard): StoryboardDraft {
  return {
    content_id: board.content_id,
    title: board.title,
    dialect: board.dialect ?? "",
    frame: board.frame,
    budget_yuan: board.budget_yuan,
    cast: { ...board.cast },
    shots: board.shots.map(draftShot),
  };
}

export function draftToStoryboard(draft: StoryboardDraft): Storyboard {
  return {
    content_id: draft.content_id,
    title: draft.title.trim(),
    dialect: nullable(draft.dialect),
    frame: draft.frame,
    budget_yuan: draft.budget_yuan,
    cast: draft.cast,
    shots: draft.shots.map((shot) => {
      const duration = shot.duration.trim();
      return {
        id: shot.id.trim(),
        kind: shot.kind,
        framing: shot.framing.trim(),
        speaker: nullable(shot.speaker),
        line: shot.line,
        duration_s: duration === "" ? null : Number(duration),
        priority: shot.priority,
        prop: nullable(shot.prop),
        motion: nullable(shot.motion),
        visual: nullable(shot.visual),
      };
    }),
  };
}

export function validateStoryboardDraft(draft: StoryboardDraft): string[] {
  const errors: string[] = [];
  if (draft.shots.length === 0) {
    errors.push("分镜表至少需要 1 个镜头");
  }
  const seen = new Set<string>();
  draft.shots.forEach((shot, index) => {
    const id = shot.id.trim();
    if (id === "") {
      errors.push("镜号不能为空");
    } else if (seen.has(id)) {
      errors.push(`镜号重复：${id}`);
    } else {
      seen.add(id);
    }
    const raw = shot.duration.trim();
    if (raw !== "") {
      const value = Number(raw);
      if (!Number.isFinite(value) || value <= 0) {
        errors.push(`第 ${index + 1} 镜时长必须是有限正数`);
      }
    }
    if (!SHOT_KINDS.includes(shot.kind)) {
      errors.push(`第 ${index + 1} 镜类型无效`);
    }
    if (!PRIORITIES.includes(shot.priority)) {
      errors.push(`第 ${index + 1} 镜优先级无效`);
    }
  });
  return errors;
}

export function emptyShotDraft(index: number): ShotDraft {
  return {
    id: `s${String(index).padStart(2, "0")}`,
    kind: "speak_off",
    framing: "unknown",
    speaker: "",
    line: "",
    duration: "",
    priority: "normal",
    prop: "",
    motion: "",
    visual: "",
  };
}

export function addShot(draft: StoryboardDraft): StoryboardDraft {
  const used = new Set(draft.shots.map((shot) => shot.id.trim()));
  let index = draft.shots.length + 1;
  while (used.has(`s${String(index).padStart(2, "0")}`)) index += 1;
  return { ...draft, shots: [...draft.shots, emptyShotDraft(index)] };
}

export function removeShot(
  draft: StoryboardDraft,
  id: string,
): StoryboardDraft {
  return {
    ...draft,
    shots: draft.shots.filter((shot) => shot.id.trim() !== id),
  };
}

export function moveShot(
  draft: StoryboardDraft,
  id: string,
  delta: -1 | 1,
): StoryboardDraft {
  const index = draft.shots.findIndex((shot) => shot.id.trim() === id);
  const target = index + delta;
  if (index < 0 || target < 0 || target >= draft.shots.length) return draft;
  const shots = [...draft.shots];
  const [item] = shots.splice(index, 1);
  shots.splice(target, 0, item);
  return { ...draft, shots };
}
