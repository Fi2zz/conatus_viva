/// `/api/drama/*` 客户端；前端只经本地 HTTP 访问后端。
import type {
  DramaEpisode,
  DramaEstimate,
  DramaRun,
  DramaSeries,
  DramaSeriesSummary,
  EpisodeBundle,
  EpisodeSummary,
  EstimateInput,
  StoryExtractResult,
  Storyboard,
  StoryboardDraftResult,
} from "./types";

export interface CreateSeriesInput {
  series_id: string;
  title: string;
  dialect: string;
  planned_episodes: number;
  total_budget_yuan: number;
  i2v_budget_yuan: number;
}

export interface CreateEpisodeInput {
  episode_id?: string;
  title: string;
  number?: number;
}

export class DramaApiError extends Error {
  readonly status: number;
  readonly code?: string;
  readonly details?: unknown;

  constructor(status: number, message: string, code?: string, details?: unknown) {
    super(message);
    this.name = "DramaApiError";
    this.status = status;
    this.code = code;
    this.details = details;
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(path, init);
  } catch (error) {
    throw new DramaApiError(0, `网络错误：${String(error)}`, "network");
  }
  const text = await response.text();
  let payload: unknown = null;
  try {
    payload = text === "" ? null : JSON.parse(text);
  } catch {
    payload = null;
  }
  if (!response.ok) {
    const body = payload as
      | { error?: unknown; code?: unknown; details?: unknown }
      | null;
    const message =
      typeof body?.error === "string"
        ? body.error
        : `请求失败（HTTP ${response.status}）`;
    throw new DramaApiError(
      response.status,
      message,
      typeof body?.code === "string" ? body.code : undefined,
      body?.details,
    );
  }
  return payload as T;
}

function json(method: string, body: unknown): RequestInit {
  return {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  };
}

function base(seriesId: string, episodeId?: string): string {
  const series = `/api/drama/series/${encodeURIComponent(seriesId)}`;
  return episodeId === undefined
    ? series
    : `${series}/episodes/${encodeURIComponent(episodeId)}`;
}

export const dramaApi = {
  listSeries(): Promise<{ series: DramaSeriesSummary[] }> {
    return request("/api/drama/series");
  },

  createSeries(input: CreateSeriesInput): Promise<{ series: DramaSeries }> {
    return request("/api/drama/series", json("POST", input));
  },

  getSeries(
    id: string,
  ): Promise<{ series: DramaSeries; episodes: EpisodeSummary[] }> {
    return request(`/api/drama/series/${encodeURIComponent(id)}`);
  },

  updateSeries(
    id: string,
    series: DramaSeries,
  ): Promise<{ series: DramaSeries; episodes: EpisodeSummary[] }> {
    return request(
      `/api/drama/series/${encodeURIComponent(id)}`,
      json("PUT", { series }),
    );
  },

  createEpisode(
    seriesId: string,
    input: CreateEpisodeInput,
  ): Promise<{ episode: DramaEpisode }> {
    return request(`${base(seriesId)}/episodes`, json("POST", input));
  },

  getEpisode(seriesId: string, episodeId: string): Promise<EpisodeBundle> {
    return request(base(seriesId, episodeId));
  },

  updateEpisode(
    seriesId: string,
    episodeId: string,
    episode: DramaEpisode,
  ): Promise<EpisodeBundle> {
    return request(base(seriesId, episodeId), json("PUT", { episode }));
  },

  saveStoryboard(
    seriesId: string,
    episodeId: string,
    storyboard: Storyboard,
  ): Promise<EpisodeBundle> {
    return request(
      `${base(seriesId, episodeId)}/storyboard`,
      json("PUT", { storyboard }),
    );
  },

  replan(seriesId: string, episodeId: string): Promise<EpisodeBundle> {
    return request(
      `${base(seriesId, episodeId)}/plan`,
      json("POST", {}),
    );
  },

  estimate(
    seriesId: string,
    episodeId: string,
    input: EstimateInput,
  ): Promise<DramaEstimate> {
    return request(`${base(seriesId, episodeId)}/estimate`, json("POST", input));
  },

  runStep(
    seriesId: string,
    episodeId: string,
    step: "cast" | "frame",
    input: Omit<EstimateInput, "step"> = {},
  ): Promise<{ run_id: string }> {
    return request(
      `${base(seriesId, episodeId)}/steps/${step}:run`,
      json("POST", input),
    );
  },

  runShot(
    seriesId: string,
    episodeId: string,
    shotId: string,
    input: { target?: "frame" | "clip" | "all"; force?: boolean; degrade?: boolean } = {},
  ): Promise<{ run_id: string }> {
    return request(
      `${base(seriesId, episodeId)}/shots/${encodeURIComponent(shotId)}:run`,
      json("POST", input),
    );
  },

  getRun(seriesId: string, episodeId: string, runId: string): Promise<DramaRun> {
    return request(
      `${base(seriesId, episodeId)}/runs/${encodeURIComponent(runId)}`,
    );
  },

  cancelRun(
    seriesId: string,
    episodeId: string,
    runId: string,
  ): Promise<{ status: string }> {
    return request(
      `${base(seriesId, episodeId)}/runs/${encodeURIComponent(runId)}:cancel`,
      json("POST", {}),
    );
  },

  extractStory(
    seriesId: string,
    episodeId: string,
    text?: string,
  ): Promise<StoryExtractResult> {
    return request(
      `${base(seriesId, episodeId)}/story:extract`,
      json("POST", text === undefined ? {} : { text }),
    );
  },

  draftStoryboard(
    seriesId: string,
    episodeId: string,
  ): Promise<StoryboardDraftResult> {
    return request(
      `${base(seriesId, episodeId)}/storyboard:draft`,
      json("POST", {}),
    );
  },
};
