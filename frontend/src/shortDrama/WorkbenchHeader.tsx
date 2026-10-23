/// 工作台顶栏：品牌、剧名、集选择、视图切换、预算与缓存。
import type { DramaSeries, EpisodeSummary } from "./types";
import { budgetPercent } from "./view";
import { formatYuan } from "./model";

interface Props {
  series: DramaSeries;
  episodes: EpisodeSummary[];
  episodeId: string;
  view: "prod" | "canvas";
  actualYuan: number;
  totalYuan: number;
  onEpisodeChange: (id: string) => void;
  onViewChange: (view: "prod" | "canvas") => void;
}

export default function WorkbenchHeader({
  series,
  episodes,
  episodeId,
  view,
  actualYuan,
  totalYuan,
  onEpisodeChange,
  onViewChange,
}: Props) {
  const pct = budgetPercent(actualYuan, totalYuan);
  return (
    <header className="sd-header">
      <div className="sd-brand">
        <span className="sd-mark" aria-hidden="true" />
        <div>
          <b>VIVA</b>
          <span>剧集控制台</span>
        </div>
      </div>

      <div className="sd-series">
        <h1>《{series.title}》</h1>
        <span className="sd-meta">
          竖屏 9:16 · {series.dialect} · {series.content_type} ·{" "}
          {series.planned_episodes} 集
        </span>
      </div>

      <label className="sd-ep">
        <span>EP</span>
        <select
          value={episodeId}
          onChange={(event) => onEpisodeChange(event.target.value)}
        >
          {episodes.map((episode) => (
            <option key={episode.episode_id} value={episode.episode_id}>
              {String(episode.number).padStart(2, "0")} · {episode.title}
            </option>
          ))}
        </select>
      </label>

      <div className="sd-seg" role="tablist" aria-label="视图切换">
        <button
          type="button"
          className={view === "prod" ? "on" : ""}
          onClick={() => onViewChange("prod")}
        >
          产线视图
        </button>
        <button
          type="button"
          className={view === "canvas" ? "on" : ""}
          onClick={() => onViewChange("canvas")}
        >
          画布视图
        </button>
      </div>

      <div className="sd-chip" title="本集实际成本 / 总预算">
        预算 <b>{formatYuan(actualYuan)}</b> / {formatYuan(totalYuan)}
        <span className="sd-bar">
          <i style={{ width: `${pct}%` }} />
        </span>
      </div>
      <div className="sd-chip" title="P1 不生成图片/视频/TTS，暂无缓存命中">
        缓存命中 <b>—</b>
      </div>
    </header>
  );
}
