/// 可编辑分镜表：只负责展示与回调，校验在 storyboard.ts。
import type { Plan, ShotKind, ShotPriority } from "./model";
import { formatYuan } from "./model";
import {
  addShot,
  moveShot,
  removeShot,
  type ShotDraft,
  type StoryboardDraft,
} from "./storyboard";

const KIND_LABELS: Record<ShotKind, string> = {
  speak_off: "画外音",
  insert: "插入",
  listen_face: "反应·听",
  action: "动作",
  establishing: "定场",
};

const PRIORITY_LABELS: Record<ShotPriority, string> = {
  hook: "钩子",
  turn: "反转",
  payoff: "回收",
  normal: "普通",
};

interface Props {
  draft: StoryboardDraft;
  onChange: (draft: StoryboardDraft) => void;
  plan: Plan | null;
  disabled?: boolean;
  onSelectShot?: (id: string) => void;
}

export default function StoryboardTable({
  draft,
  onChange,
  plan,
  disabled = false,
  onSelectShot,
}: Props) {
  const update = (id: string, patch: Partial<ShotDraft>) => {
    onChange({
      ...draft,
      shots: draft.shots.map((shot) =>
        shot.id === id ? { ...shot, ...patch } : shot,
      ),
    });
  };

  return (
    <div className="sd-table-wrap">
      <table className="sd-table">
        <thead>
          <tr>
            <th>镜号</th>
            <th>类型</th>
            <th>景别</th>
            <th>角色</th>
            <th>台词</th>
            <th>时长</th>
            <th>优先级</th>
            <th>成本</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {draft.shots.map((shot, index) => {
            const planShot = plan?.shots.find((item) => item.shot_id === shot.id);
            return (
              <tr
                key={shot.id === "" ? `row-${index}` : shot.id}
                onClick={() => onSelectShot?.(shot.id)}
              >
                <td>
                  <input
                    className="sd-cell-id"
                    value={shot.id}
                    disabled={disabled}
                    onChange={(event) => update(shot.id, { id: event.target.value })}
                  />
                </td>
                <td>
                  <select
                    value={shot.kind}
                    disabled={disabled}
                    onChange={(event) =>
                      update(shot.id, { kind: event.target.value as ShotKind })
                    }
                  >
                    {(Object.keys(KIND_LABELS) as ShotKind[]).map((kind) => (
                      <option key={kind} value={kind}>
                        {KIND_LABELS[kind]}
                      </option>
                    ))}
                  </select>
                </td>
                <td>
                  <input
                    value={shot.framing}
                    disabled={disabled}
                    onChange={(event) =>
                      update(shot.id, { framing: event.target.value })
                    }
                  />
                </td>
                <td>
                  <select
                    value={shot.speaker}
                    disabled={disabled}
                    onChange={(event) =>
                      update(shot.id, { speaker: event.target.value })
                    }
                  >
                    <option value="">—</option>
                    {Object.entries(draft.cast).map(([id, member]) => (
                      <option key={id} value={id}>
                        {member.name || id}
                      </option>
                    ))}
                  </select>
                </td>
                <td>
                  <input
                    className="sd-cell-line"
                    value={shot.line}
                    disabled={disabled}
                    onChange={(event) => update(shot.id, { line: event.target.value })}
                  />
                </td>
                <td>
                  <input
                    className="sd-cell-duration"
                    value={shot.duration}
                    disabled={disabled}
                    placeholder="自动"
                    onChange={(event) =>
                      update(shot.id, { duration: event.target.value })
                    }
                  />
                </td>
                <td>
                  <select
                    value={shot.priority}
                    disabled={disabled}
                    onChange={(event) =>
                      update(shot.id, {
                        priority: event.target.value as ShotPriority,
                      })
                    }
                  >
                    {(Object.keys(PRIORITY_LABELS) as ShotPriority[]).map(
                      (priority) => (
                        <option key={priority} value={priority}>
                          {PRIORITY_LABELS[priority]}
                        </option>
                      ),
                    )}
                  </select>
                </td>
                <td className="mono sd-cell-cost">
                  {planShot ? formatYuan(planShot.cost_yuan) : "—"}
                </td>
                <td className="sd-row-actions">
                  <button
                    type="button"
                    disabled={disabled || index === 0}
                    title="上移"
                    onClick={(event) => {
                      event.stopPropagation();
                      onChange(moveShot(draft, shot.id, -1));
                    }}
                  >
                    ↑
                  </button>
                  <button
                    type="button"
                    disabled={disabled || index === draft.shots.length - 1}
                    title="下移"
                    onClick={(event) => {
                      event.stopPropagation();
                      onChange(moveShot(draft, shot.id, 1));
                    }}
                  >
                    ↓
                  </button>
                  <button
                    type="button"
                    disabled={disabled}
                    title="删除"
                    onClick={(event) => {
                      event.stopPropagation();
                      onChange(removeShot(draft, shot.id));
                    }}
                  >
                    ×
                  </button>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <button
        type="button"
        className="sd-btn ghost"
        disabled={disabled}
        onClick={() => onChange(addShot(draft))}
      >
        ＋ 添加镜头
      </button>
    </div>
  );
}
