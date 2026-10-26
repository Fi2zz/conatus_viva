import { renderToString } from "react-dom/server";
import { describe, expect, it } from "vitest";
import StageRouter from "./StageRouter";
import CanvasView from "./CanvasView";
import WorkbenchShell from "./WorkbenchShell";
import CastStage from "./stages/CastStage";
import FrameStage from "./stages/FrameStage";
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
  it("cast stage shows pending approval and actions", () => {
    const withAvatar: EpisodeBundle = {
      ...bundle,
      series: {
        ...bundle.series,
        cast: {
          erniu: {
            ...bundle.series.cast.erniu,
            avatar: {
              path: "cast/erniu/hash/image-01.png",
              source_hash: "sha256:hash",
              model: "wan2.7-image",
              cost_yuan: 0.2,
              approved: false,
            },
          },
        },
      },
    };
    const html = renderToString(
      <CastStage bundle={withAvatar} onBundle={noop} onReload={noop} />,
    );
    expect(html).toContain("待采用");
    expect(html).toContain("重新生成");
    expect(html).toContain("/api/drama/series/jietiao/assets/cast/erniu/hash/image-01.png");
  });

  it("frame stage renders timeline and per-shot actions", () => {
    const withArtifacts: EpisodeBundle = {
      ...bundle,
      state: {
        ...bundle.state,
        shots: {
          s01: {
            frame: {
              status: "succeeded",
              path: "assets/frames/s01/hash/image-01.png",
              source_hash: "sha256:frame",
              model: "wan2.7-image",
              cost_yuan: 0.2,
              duration_s: null,
              error: null,
            },
            clip: {
              status: "running",
              path: null,
              source_hash: null,
              model: null,
              cost_yuan: null,
              duration_s: null,
              error: null,
            },
            audio: {
              status: "pending",
              path: null,
              source_hash: null,
              model: null,
              cost_yuan: null,
              duration_s: null,
              error: null,
            },
          },
        },
      },
    };
    const html = renderToString(
      <FrameStage
        bundle={withArtifacts}
        selectedShotId="s01"
        onSelectShot={noop}
        onReload={noop}
      />,
    );
    expect(html).toContain("生成全部首帧");
    expect(html).toContain("降级为静帧");
    expect(html).toContain("assets/frames/s01/hash/image-01.png");
  });

  it("shows t2v route and hides the frame action for an establishing shot", () => {
    const withPlan: EpisodeBundle = {
      ...bundle,
      plan: {
        content_id: "ep07",
        title: "堂屋对峙",
        frame: { width: 1080, height: 1920 },
        i2v_generation: {
          model: "wan2.6-i2v-flash",
          resolution: "720P",
          width: 720,
          height: 1280,
        },
        budget_yuan: 20,
        price_yuan_per_second: 0.15,
        max_i2v_seconds: 0,
        shots: [
          {
            shot_id: "s01",
            kind: "establishing",
            route: "t2v",
            avatar: false,
            duration_s: 2,
            i2v_seconds: 0,
            cost_yuan: 0.84,
            downgrade_reason: null,
            framing: "全景",
            speaker: null,
            line: "",
            priority: "normal",
          },
        ],
        totals: {
          duration_s: 2,
          i2v_seconds: 0,
          estimated_yuan: 0.84,
          remaining_yuan: 20,
          total_remaining_yuan: 119.16,
        },
        counts: { kenburns: 0, micro: 0, i2v: 0, t2v: 1 },
        warnings: [],
      },
    };
    const html = renderToString(
      <FrameStage
        bundle={withPlan}
        selectedShotId="s01"
        onSelectShot={noop}
        onReload={noop}
      />,
    );
    expect(html).toContain("文生视频");
    expect(html).not.toContain("生成首帧");
    expect(html).toContain("t2v");
  });

  it("renders every stage without crashing", () => {    for (const step of STEP_ORDER) {
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

  it("renders shell and canvas", () => {    expect(
      renderToString(
        <WorkbenchShell
          bundle={bundle}
          seriesList={[
            {
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
              cast: {},
              episode_count: 1,
            },
          ]}
          episodes={[{ episode_id: "ep07", number: 7, title: "堂屋对峙" }]}
          onBundle={noop}
          onReload={noop}
          onSelectSeries={noop}
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
