/// 工序舞台路由：把当前 step 映射到对应舞台组件。
import type { EpisodeBundle, StepKey } from "./types";
import SplitStage from "./stages/SplitStage";
import StoryStage from "./stages/StoryStage";
import CastStage from "./stages/CastStage";
import BoardStage from "./stages/BoardStage";
import FrameStage from "./stages/FrameStage";
import VoiceStage from "./stages/VoiceStage";
import EditStage from "./stages/EditStage";
import PackStage from "./stages/PackStage";

export interface StageRouterProps {
  step: StepKey;
  bundle: EpisodeBundle;
  selectedShotId: string | null;
  onBundle: (bundle: EpisodeBundle) => void;
  onReload: () => void;
  onSelectShot: (id: string | null) => void;
}

export default function StageRouter(props: StageRouterProps) {
  const { bundle, onBundle, onReload, onSelectShot } = props;
  switch (props.step) {
    case "split":
      return (
        <SplitStage
          key={bundle.episode.episode_id}
          bundle={bundle}
          onBundle={onBundle}
          onReload={onReload}
        />
      );
    case "story":
      return (
        <StoryStage
          key={bundle.episode.episode_id}
          bundle={bundle}
          onReload={onReload}
        />
      );
    case "cast":
      return <CastStage bundle={bundle} />;
    case "board":
      return (
        <BoardStage
          key={bundle.episode.episode_id}
          bundle={bundle}
          onBundle={onBundle}
          onReload={onReload}
          onSelectShot={(id) => onSelectShot(id)}
        />
      );
    case "frame":
      return <FrameStage bundle={bundle} />;
    case "voice":
      return <VoiceStage bundle={bundle} />;
    case "edit":
      return <EditStage />;
    case "pack":
      return <PackStage />;
  }
}
