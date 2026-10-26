import { describe, expect, it } from "vitest";
import { episodeAssetUrl, seriesAssetUrl } from "./asset";
import { isTerminalRun, runSummary } from "./run";
import type { DramaRun } from "./types";

describe("asset urls", () => {
  it("encodes every path segment", () => {
    expect(
      episodeAssetUrl(
        "s 1",
        "e/1",
        "assets/frames/s01/sha/image-01.png",
      ),
    ).toBe(
      "/api/drama/series/s%201/episodes/e%2F1/assets/frames/s01/sha/image-01.png",
    );
    expect(seriesAssetUrl("s 1", "cast/erniu/sha/image-01.png")).toBe(
      "/api/drama/series/s%201/assets/cast/erniu/sha/image-01.png",
    );
  });
});

describe("run helpers", () => {
  it("knows terminal statuses", () => {
    expect(isTerminalRun("completed")).toBe(true);
    expect(isTerminalRun("failed")).toBe(true);
    expect(isTerminalRun("cancelled")).toBe(true);
    expect(isTerminalRun("running")).toBe(false);
  });

  it("summarizes progress", () => {
    const run = {
      run_id: "r1",
      status: "running",
      step: "frame",
      items: [
        { id: "s01", kind: "frame", status: "succeeded" },
        { id: "s02", kind: "frame", status: "running" },
      ],
      logs: [],
      actual_yuan: 0.2,
      error: null,
    } as unknown as DramaRun;
    expect(runSummary(run)).toContain("1/2");
  });
});
