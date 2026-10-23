import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import StageRouter from "./StageRouter";
import CanvasView from "./CanvasView";
import WorkbenchShell from "./WorkbenchShell";
import { STEP_ORDER } from "./view";
import type { EpisodeBundle, StepView } from "./types";

const steps: StepView[] = STEP_ORDER.map((key) => ({
  key,
  status: "pending",
  cost_yuan: 0,
  summary: "待处理",
  detail: "",
  wired: key === "split" || key === "story" || key === "board",
}));

const bundle: EpisodeBundle = {
  series: {
    series_id: "jietiao",
    title: "借条",
    logline: "一张旧借条",
    dialect: "河南",
    frame: "1080x1920",
    content_type: "manju",
    planned_episodes: 80,
    defaults: {
      total_budget_yuan: 120,
      i2v_budget_yuan: 20,
      max_i2v_seconds: 0,
      cast_image_model: "wan2.7-image",
      frame_image_model: "wan2.7-image",
      clip_video_model: "wan2.6-i2v-flash",
      t2v_model: "wan3.0-video",
      resolution: "720P",
    },
    beat_template: [],
    cast: {
      erniu: {
        name: "二舅",
        description: "五十岁",
        voice_id: null,
        dialect: "河南",
        avatar: null,
      },
    },
  },
  episode: {
    series_id: "jietiao",
    episode_id: "ep07",
    number: 7,
    title: "堂屋对峙",
    source: { kind: "story", text: "二舅闯进堂屋" },
    story: {
      logline: "二舅逼债",
      synopsis: "小满翻出第二张借条",
      beats: [{ id: "hook", label: "钩子", summary: "借条拍桌" }],
      source_hash: "sha256:x",
      prompt_version: 1,
      model: "qwen3.8-flash",
    },
    settings: {
      dialect: "河南",
      frame: "1080x1920",
      total_budget_yuan: 120,
      i2v_budget_yuan: 20,
      max_i2v_seconds: 0,
      target_duration_s: 90,
    },
  },
  storyboard: {
    content_id: "ep07",
    title: "堂屋对峙",
    dialect: "河南",
    frame: "1080x1920",
    budget_yuan: 20,
    cast: { erniu: { name: "二舅" } },
    shots: [
      {
        id: "s01",
        kind: "speak_off",
        framing: "over_shoulder",
        speaker: "erniu",
        line: "你欠我的，今天该还了。",
        duration_s: 3,
        priority: "hook",
        prop: "借条",
        motion: "缓慢推近",
        visual: "堂屋逆光",
      },
    ],
  },
  plan: null,
  state: {
    series_id: "jietiao",
    episode_id: "ep07",
    storyboard_hash: "sha256:x",
    plan_hash: null,
    steps: {},
    shots: {},
    active_run: null,
    cost: { actual_yuan: 0, estimated_remaining_yuan: 0 },
    warnings: [],
  },
  steps,
  capabilities: { cast: false, frame: false, voice: false, edit: false, pack: false },
};

const noop = () => undefined;

describe("workbench smoke render", () => {
  it("renders every stage without crashing", () => {
    for (const step of STEP_ORDER) {
      const html = renderToString(
        <StageRouter
          step={step}
          bundle={bundle}
          selectedShotId="s01"
          onBundle={noop}
          onReload={noop}
          onSelectShot={noop}
        />,
      );
      expect(html.length).toBeGreaterThan(0);
    }
  });

  it("renders shell and canvas", () => {
    expect(
      renderToString(
        <WorkbenchShell
          bundle={bundle}
          episodes={[{ episode_id: "ep07", number: 7, title: "堂屋对峙" }]}
          onBundle={noop}
          onReload={noop}
          onSelectEpisode={noop}
        />,
      ),
    ).toContain("剧集控制台");
    expect(
      renderToString(
        <CanvasView steps={steps} selected="split" onSelect={noop} />,
      ),
    ).toContain("工序状态来自本地 state");
  });
});
