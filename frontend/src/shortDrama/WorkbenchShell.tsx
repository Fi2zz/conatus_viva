/// 工作台三栏壳体：顶栏 / 工序栏 / 舞台 / 检视 / 底栏。
import { useState } from "react";
import type { EpisodeBundle, EpisodeSummary, StepKey } from "./types";
import { findStep } from "./view";
import { hookShots } from "./model";
import WorkbenchHeader from "./WorkbenchHeader";
import StepRail from "./StepRail";
import StageRouter from "./StageRouter";
import CanvasView from "./CanvasView";
import Inspector from "./Inspector";
import FooterMeters from "./FooterMeters";

interface Props {
  bundle: EpisodeBundle;
  episodes: EpisodeSummary[];
  onBundle: (bundle: EpisodeBundle) => void;
  onReload: () => void;
  onSelectEpisode: (id: string) => void;
}

export default function WorkbenchShell({
  bundle,
  episodes,
  onBundle,
  onReload,
  onSelectEpisode,
}: Props) {
  const [step, setStep] = useState<StepKey>("split");
  const [view, setView] = useState<"prod" | "canvas">("prod");
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
        episodes={episodes}
        episodeId={bundle.episode.episode_id}
        view={view}
        actualYuan={bundle.state.cost.actual_yuan}
        totalYuan={bundle.episode.settings.total_budget_yuan}
        onEpisodeChange={onSelectEpisode}
        onViewChange={setView}
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
        <Inspector step={stepView} shot={selectedShot} planShot={planShot} />
      </main>
      <FooterMeters
        actualYuan={bundle.state.cost.actual_yuan}
        totalYuan={bundle.episode.settings.total_budget_yuan}
        shotCount={shots.length}
        hookCount={hookCount}
      />
    </div>
  );
}
