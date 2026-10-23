/// 空态入口：没有剧 / 没有集时的创建表单。
import { useEffect, useState } from "react";
import { DramaApiError, dramaApi } from "./api";
import type { DramaEpisode, DramaSeries } from "./types";

interface DialectOption {
  code: string;
  label: string;
  name?: string;
}

function useDialects(): DialectOption[] {
  const [dialects, setDialects] = useState<DialectOption[]>([]);
  useEffect(() => {
    let cancelled = false;
    fetch("/api/dialects")
      .then((response) => response.json())
      .then((data: { dialects?: DialectOption[] }) => {
        if (!cancelled) setDialects(data.dialects ?? []);
      })
      .catch((error) => console.error("Failed to load dialects:", error));
    return () => {
      cancelled = true;
    };
  }, []);
  return dialects;
}

function errorMessage(error: unknown): string {
  if (error instanceof DramaApiError) return error.message;
  return String(error);
}

function SeriesForm({ onCreated }: { onCreated: (series: DramaSeries) => void }) {
  const dialects = useDialects();
  const [seriesId, setSeriesId] = useState("");
  const [title, setTitle] = useState("");
  const [dialect, setDialect] = useState("");
  const [planned, setPlanned] = useState("1");
  const [total, setTotal] = useState("120");
  const [i2v, setI2v] = useState("20");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const effectiveDialect = dialect || dialects[0]?.code || "mandarin";

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    setError("");
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(seriesId)) {
      setError("剧 ID 只能包含字母、数字、下划线和短横线（1–64 位）");
      return;
    }
    if (title.trim() === "") {
      setError("请填写剧名");
      return;
    }
    const totalValue = Number(total);
    const i2vValue = Number(i2v);
    if (!Number.isFinite(totalValue) || totalValue <= 0) {
      setError("总预算必须是有限正数");
      return;
    }
    if (!Number.isFinite(i2vValue) || i2vValue <= 0) {
      setError("i2v 预算必须是有限正数");
      return;
    }
    setBusy(true);
    try {
      const result = await dramaApi.createSeries({
        series_id: seriesId.trim(),
        title: title.trim(),
        dialect: effectiveDialect,
        planned_episodes: Number(planned) || 1,
        total_budget_yuan: totalValue,
        i2v_budget_yuan: i2vValue,
      });
      onCreated(result.series);
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="sd-entry">
      <div className="sd-entry-card">
        <header>
          <span>新建剧</span>
          <h2>先把剧集骨架立起来</h2>
          <p>剧 ID 会作为目录名；角色、节拍和分集在故事/分镜工序里补。</p>
        </header>
        <form onSubmit={(event) => void submit(event)}>
          <label>
            剧 ID
            <input
              value={seriesId}
              onChange={(event) => setSeriesId(event.target.value)}
              placeholder="jietiao"
            />
          </label>
          <label>
            剧名
            <input
              value={title}
              onChange={(event) => setTitle(event.target.value)}
              placeholder="借条"
            />
          </label>
          <label>
            方言
            <select
              value={effectiveDialect}
              onChange={(event) => setDialect(event.target.value)}
            >
              {dialects.length === 0 && <option value="mandarin">普通话</option>}
              {dialects.map((option) => (
                <option key={option.code} value={option.code}>
                  {option.name ?? option.label}
                </option>
              ))}
            </select>
          </label>
          <div className="sd-entry-row">
            <label>
              计划集数
              <input
                type="number"
                min={1}
                value={planned}
                onChange={(event) => setPlanned(event.target.value)}
              />
            </label>
            <label>
              总预算（元）
              <input
                type="number"
                min={0.01}
                step={0.01}
                value={total}
                onChange={(event) => setTotal(event.target.value)}
              />
            </label>
            <label>
              i2v 预算（元）
              <input
                type="number"
                min={0.01}
                step={0.01}
                value={i2v}
                onChange={(event) => setI2v(event.target.value)}
              />
            </label>
          </div>
          {error !== "" && <div className="sd-entry-error">{error}</div>}
          <button type="submit" disabled={busy}>
            {busy ? "创建中…" : "创建剧"}
          </button>
        </form>
      </div>
    </div>
  );
}

function EpisodeForm({
  seriesId,
  onCreated,
}: {
  seriesId: string;
  onCreated: (episode: DramaEpisode) => void;
}) {
  const [episodeId, setEpisodeId] = useState("ep01");
  const [title, setTitle] = useState("");
  const [number, setNumber] = useState("1");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    setError("");
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(episodeId)) {
      setError("集 ID 只能包含字母、数字、下划线和短横线（1–64 位）");
      return;
    }
    if (title.trim() === "") {
      setError("请填写集标题");
      return;
    }
    setBusy(true);
    try {
      const result = await dramaApi.createEpisode(seriesId, {
        episode_id: episodeId.trim(),
        title: title.trim(),
        number: Number(number) || 1,
      });
      onCreated(result.episode);
    } catch (cause) {
      setError(errorMessage(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="sd-entry">
      <div className="sd-entry-card">
        <header>
          <span>新建集</span>
          <h2>这一集叫什么</h2>
          <p>创建后会从剧级节拍模板复制一份可编辑的节拍表。</p>
        </header>
        <form onSubmit={(event) => void submit(event)}>
          <div className="sd-entry-row">
            <label>
              集 ID
              <input
                value={episodeId}
                onChange={(event) => setEpisodeId(event.target.value)}
                placeholder="ep01"
              />
            </label>
            <label>
              集数
              <input
                type="number"
                min={1}
                value={number}
                onChange={(event) => setNumber(event.target.value)}
              />
            </label>
          </div>
          <label>
            标题
            <input
              value={title}
              onChange={(event) => setTitle(event.target.value)}
              placeholder="堂屋对峙"
            />
          </label>
          {error !== "" && <div className="sd-entry-error">{error}</div>}
          <button type="submit" disabled={busy}>
            {busy ? "创建中…" : "创建集"}
          </button>
        </form>
      </div>
    </div>
  );
}

type Props =
  | { mode: "series"; onCreated: (series: DramaSeries) => void }
  | { mode: "episode"; seriesId: string; onCreated: (episode: DramaEpisode) => void };

export default function EntryForms(props: Props) {
  if (props.mode === "series") return <SeriesForm onCreated={props.onCreated} />;
  return <EpisodeForm seriesId={props.seriesId} onCreated={props.onCreated} />;
}
