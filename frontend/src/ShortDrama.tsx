/// 短剧工作台入口：拉取剧集列表 → 当前剧/集 → 三栏壳体。
import { useCallback, useEffect, useRef, useState } from "react";
import "./shortDrama/ShortDrama.css";
import { dramaApi } from "./shortDrama/api";
import type {
  DramaSeriesSummary,
  EpisodeBundle,
  EpisodeSummary,
} from "./shortDrama/types";
import EntryForms from "./shortDrama/EntryForms";
import WorkbenchShell from "./shortDrama/WorkbenchShell";

function messageOf(error: unknown): string {
  if (error instanceof Error) return error.message;
  return String(error);
}

export default function ShortDrama() {
  const [seriesList, setSeriesList] = useState<DramaSeriesSummary[]>([]);
  const [seriesId, setSeriesId] = useState("");
  const [episodes, setEpisodes] = useState<EpisodeSummary[]>([]);
  const [episodeId, setEpisodeId] = useState("");
  const [bundle, setBundle] = useState<EpisodeBundle | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const requestSeq = useRef(0);

  const loadAll = useCallback(
    async (preferSeries?: string, preferEpisode?: string) => {
      const seq = ++requestSeq.current;
      setLoading(true);
      setError("");
      try {
        const list = await dramaApi.listSeries();
        if (seq !== requestSeq.current) return;
        setSeriesList(list.series);
        if (list.series.length === 0) {
          setSeriesId("");
          setEpisodes([]);
          setEpisodeId("");
          setBundle(null);
          return;
        }
        const series =
          list.series.find((item) => item.series_id === preferSeries) ??
          list.series[0];
        setSeriesId(series.series_id);

        const detail = await dramaApi.getSeries(series.series_id);
        if (seq !== requestSeq.current) return;
        setEpisodes(detail.episodes);
        if (detail.episodes.length === 0) {
          setEpisodeId("");
          setBundle(null);
          return;
        }
        const episode =
          detail.episodes.find(
            (item) => item.episode_id === preferEpisode,
          ) ?? detail.episodes[0];
        setEpisodeId(episode.episode_id);

        const next = await dramaApi.getEpisode(
          series.series_id,
          episode.episode_id,
        );
        if (seq !== requestSeq.current) return;
        setBundle(next);
      } catch (cause) {
        if (seq === requestSeq.current) setError(messageOf(cause));
      } finally {
        if (seq === requestSeq.current) setLoading(false);
      }
    },
    [],
  );

  useEffect(() => {
    queueMicrotask(() => void loadAll());
  }, [loadAll]);

  const reload = () => void loadAll(seriesId, episodeId);
  const selectEpisode = (id: string) => {
    setEpisodeId(id);
    void loadAll(seriesId, id);
  };

  if (loading) {
    return (
      <div className="short-drama sd-center">
        <div className="sd-status">正在加载剧集…</div>
      </div>
    );
  }

  if (error !== "") {
    return (
      <div className="short-drama sd-center">
        <div className="sd-error">
          <p>{error}</p>
          <button type="button" className="sd-btn-mini" onClick={reload}>
            重试
          </button>
        </div>
      </div>
    );
  }

  if (seriesList.length === 0) {
    return (
      <div className="short-drama">
        <EntryForms
          mode="series"
          onCreated={(series) => void loadAll(series.series_id)}
        />
      </div>
    );
  }

  if (episodes.length === 0) {
    const current = seriesList.find((item) => item.series_id === seriesId);
    return (
      <div className="short-drama">
        <div className="sd-entry-title">
          《{current?.title ?? seriesId}》还没有分集
        </div>
        <EntryForms
          mode="episode"
          seriesId={seriesId}
          onCreated={(episode) => void loadAll(seriesId, episode.episode_id)}
        />
      </div>
    );
  }

  if (bundle === null) {
    return (
      <div className="short-drama sd-center">
        <div className="sd-status">正在加载本集…</div>
      </div>
    );
  }

  return (
    <WorkbenchShell
      bundle={bundle}
      seriesList={seriesList}
      episodes={episodes}
      onBundle={setBundle}
      onReload={reload}
      onSelectSeries={(id) => void loadAll(id)}
      onSelectEpisode={selectEpisode}
    />
  );
}
