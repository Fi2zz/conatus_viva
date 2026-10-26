/// 工作台三栏壳体：顶栏 / 工序栏 / 舞台 / 检视 / 底栏。
import { useState } from "react";
import type { EpisodeBundle, DramaSeriesSummary, EpisodeSummary, StepKey } from "./types";
import { findStep } from "./view";
import { hookShots } from "./model";
import WorkbenchHeader from "./WorkbenchHeader";
import StepRail from "./StepRail";
import StageRouter from "./StageRouter";
import CanvasView from "./CanvasView";
import Inspector from "./Inspector";
import FooterMeters from "./FooterMeters";
import EntryForms from "./EntryForms";

interface Props {
  bundle: EpisodeBundle;
  seriesList: DramaSeriesSummary[];
  episodes: EpisodeSummary[];
  onBundle: (bundle: EpisodeBundle) => void;
  onReload: () => void;
  onSelectSeries: (id: string) => void;
  onSelectEpisode: (id: string) => void;
}

export default function WorkbenchShell({
  bundle,
  seriesList,
  episodes,
  onBundle,
  onReload,
  onSelectSeries,
  onSelectEpisode,
}: Props) {
  const [step, setStep] = useState<StepKey>("split");
  const [view, setView] = useState<"prod" | "canvas">("prod");
  const [creating, setCreating] = useState<"series" | "episode" | null>(null);
  const [selectedShotId, setSelectedShotId] = useState<string | null>(
    bundle.storyboard?.shots[0]?.id ?? null,
  );

  const shots = bundle.storyboard?.shots ?? [];
  const effectiveShotId =
    selectedShotId !== null && shots.some((shot) => shot.id === selectedShotId)
      ? selectedShotId
      : (shots[0]?.id ?? null);
  const selectedShot =
    shots.find((shot) => shot.id === effectiveShotId) ?? null;
  const selectedShotState =
    selectedShot === null
      ? null
      : (bundle.state.shots[selectedShot.id] ?? null);
  const planShot =
    bundle.plan?.shots.find((shot) => shot.shot_id === selectedShot?.id) ?? null;
  const stepView = findStep(bundle.steps, step) ?? {
    key: step,
    status: "pending" as const,
    cost_yuan: 0,
    summary: "未接入",
    detail: "",
    wired: false,
  };
  const hookCount = bundle.plan === null ? 0 : hookShots(bundle.plan.shots).length;

  return (
    <div className="short-drama">
      <WorkbenchHeader
        series={bundle.series}
        seriesList={seriesList}
        episodes={episodes}
        episodeId={bundle.episode.episode_id}
        view={view}
        actualYuan={bundle.state.cost.actual_yuan}
        totalYuan={bundle.episode.settings.total_budget_yuan}
        onSeriesChange={onSelectSeries}
        onEpisodeChange={onSelectEpisode}
        onViewChange={setView}
        onCreateSeries={() => setCreating("series")}
        onCreateEpisode={() => setCreating("episode")}
      />
      <main className="sd-main">
        <StepRail steps={bundle.steps} selected={step} onSelect={setStep} />
        {view === "prod" ? (
          <div className="sd-stage-wrap">
            <StageRouter
              step={step}
              bundle={bundle}
              selectedShotId={effectiveShotId}
              onBundle={onBundle}
              onReload={onReload}
              onSelectShot={setSelectedShotId}
            />
          </div>
        ) : (
          <CanvasView
            steps={bundle.steps}
            selected={step}
            onSelect={(key) => {
              setStep(key);
              setView("prod");
            }}
          />
        )}
        <Inspector
          step={stepView}
          shot={selectedShot}
          planShot={planShot}
          shotState={selectedShotState}
          seriesId={bundle.series.series_id}
          episodeId={bundle.episode.episode_id}
        />
      </main>
      <FooterMeters
        actualYuan={bundle.state.cost.actual_yuan}
        totalYuan={bundle.episode.settings.total_budget_yuan}
        shotCount={shots.length}
        hookCount={hookCount}
      />
      {creating !== null && (
        <div className="sd-modal" role="dialog" aria-modal="true">
          <div className="sd-modal-card">
            <button
              type="button"
              className="sd-modal-close"
              onClick={() => setCreating(null)}
              title="关闭"
            >
              ×
            </button>
            {creating === "series" ? (
              <EntryForms
                mode="series"
                onCreated={(series) => {
                  setCreating(null);
                  onSelectSeries(series.series_id);
                }}
              />
            ) : (
              <EntryForms
                mode="episode"
                seriesId={bundle.series.series_id}
                onCreated={(episode) => {
                  setCreating(null);
                  onSelectEpisode(episode.episode_id);
                }}
              />
            )}
          </div>
        </div>
      )}
    </div>
  );
}
