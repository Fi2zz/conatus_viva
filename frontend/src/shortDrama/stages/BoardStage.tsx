/// 分镜工序：可编辑表格、LLM 草稿、保存并重算计划单。
import { useState } from "react";
import { DramaApiError, dramaApi } from "../api";
import type {
  DramaEstimate,
  EpisodeBundle,
  Storyboard,
} from "../types";
import {
  draftToStoryboard,
  emptyShotDraft,
  storyboardToDraft,
  validateStoryboardDraft,
  type StoryboardDraft,
} from "../storyboard";
import StoryboardTable from "../StoryboardTable";
import PlanSummary from "../PlanSummary";
import DramaCostGate from "../DramaCostGate";

interface Props {
  bundle: EpisodeBundle;
  onBundle: (bundle: EpisodeBundle) => void;
  onReload: () => void;
  onSelectShot: (id: string) => void;
}

function messageOf(error: unknown): string {
  if (error instanceof DramaApiError) return error.message;
  if (error instanceof Error) return error.message;
  return String(error);
}

function castOf(bundle: EpisodeBundle): Storyboard["cast"] {
  return Object.fromEntries(
    Object.entries(bundle.series.cast).map(([id, member]) => [
      id,
      {
        name: member.name,
        voice_id: member.voice_id,
        dialect: member.dialect,
      },
    ]),
  );
}

function initialDraft(bundle: EpisodeBundle): StoryboardDraft {
  if (bundle.storyboard !== null) return storyboardToDraft(bundle.storyboard);
  return {
    content_id: bundle.episode.episode_id,
    title: bundle.episode.title,
    dialect: bundle.episode.settings.dialect,
    frame: bundle.episode.settings.frame,
    budget_yuan: bundle.episode.settings.i2v_budget_yuan,
    cast: castOf(bundle),
    shots: [emptyShotDraft(1)],
  };
}

export default function BoardStage({
  bundle,
  onBundle,
  onReload,
  onSelectShot,
}: Props) {
  const [draft, setDraft] = useState<StoryboardDraft>(() => initialDraft(bundle));
  const [warnings, setWarnings] = useState<string[]>([]);
  const [estimate, setEstimate] = useState<DramaEstimate | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  const askDraft = async () => {
    setBusy(true);
    setError("");
    try {
      const next = await dramaApi.estimate(
        bundle.series.series_id,
        bundle.episode.episode_id,
        ["storyboard"],
      );
      setEstimate(next);
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setBusy(false);
    }
  };

  const runDraft = async () => {
    setEstimate(null);
    setBusy(true);
    setError("");
    try {
      const result = await dramaApi.draftStoryboard(
        bundle.series.series_id,
        bundle.episode.episode_id,
      );
      setDraft(storyboardToDraft(result.storyboard));
      setWarnings(result.warnings);
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setBusy(false);
    }
  };

  const save = async () => {
    setError("");
    const errors = validateStoryboardDraft(draft);
    if (errors.length > 0) {
      setError(errors.join("；"));
      return;
    }
    setBusy(true);
    try {
      const next = await dramaApi.saveStoryboard(
        bundle.series.series_id,
        bundle.episode.episode_id,
        draftToStoryboard(draft),
      );
      onBundle(next);
      onReload();
    } catch (cause) {
      setError(messageOf(cause));
    } finally {
      setBusy(false);
    }
  };

  return (
    <section className="sd-stage">
      <header className="sd-stage-head">
        <div>
          <h2>04 分镜 · 计划单</h2>
          <p>保存后由服务端确定性生成计划单；生成草稿不会自动落盘。</p>
        </div>
        <span className="sd-pill">{draft.shots.length} 镜</span>
      </header>

      <div className="sd-panel">
        <h3>分镜表</h3>
        <StoryboardTable
          draft={draft}
          plan={bundle.plan}
          disabled={busy}
          onChange={setDraft}
          onSelectShot={onSelectShot}
        />
        <div className="sd-actions">
          <button
            type="button"
            className="sd-btn ghost"
            disabled={busy}
            onClick={() => void askDraft()}
          >
            生成分镜草稿
          </button>
          <button
            type="button"
            className="sd-btn primary"
            disabled={busy}
            onClick={() => void save()}
          >
            {busy ? "保存中…" : "保存并重算"}
          </button>
        </div>
        {warnings.length > 0 && (
          <ul className="sd-warnings">
            {warnings.map((warning) => (
              <li key={warning}>{warning}</li>
            ))}
          </ul>
        )}
        {error !== "" && <div className="sd-alert">{error}</div>}
      </div>

      <PlanSummary
        plan={bundle.plan}
        i2vBudgetYuan={bundle.episode.settings.i2v_budget_yuan}
        totalBudgetYuan={bundle.episode.settings.total_budget_yuan}
        actualYuan={bundle.state.cost.actual_yuan}
      />

      {estimate !== null && (
        <DramaCostGate
          estimate={estimate}
          busy={busy}
          onCancel={() => setEstimate(null)}
          onConfirm={() => void runDraft()}
        />
      )}
    </section>
  );
}
