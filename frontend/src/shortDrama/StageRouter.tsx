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
  switch (props.step) {
    case "split":
      return <SplitStage bundle={props.bundle} />;
    case "story":
      return <StoryStage bundle={props.bundle} />;
    case "cast":
      return <CastStage bundle={props.bundle} />;
    case "board":
      return <BoardStage bundle={props.bundle} />;
    case "frame":
      return <FrameStage bundle={props.bundle} />;
    case "voice":
      return <VoiceStage bundle={props.bundle} />;
    case "edit":
      return <EditStage />;
    case "pack":
      return <PackStage />;
  }
}
