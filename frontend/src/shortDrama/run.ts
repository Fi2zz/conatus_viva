/// run 轮询 hook 与纯展示 helper；前端只读服务端状态，不自造进度。
import { useCallback, useEffect, useRef, useState } from "react";
import { dramaApi } from "./api";
import type { DramaRun, EstimateInput } from "./types";

const TERMINAL = new Set(["completed", "failed", "cancelled"]);

export function isTerminalRun(status: DramaRun["status"]): boolean {
  return TERMINAL.has(status);
}

export function runSummary(run: DramaRun): string {
  const finished = run.items.filter(
    (item) =>
      item.status === "succeeded" ||
      item.status === "skipped" ||
      item.status === "failed",
  ).length;
  const label =
    run.status === "running"
      ? "运行中"
      : run.status === "completed"
        ? "完成"
        : run.status === "failed"
          ? "失败"
          : "已取消";
  return `${label} · ${finished}/${run.items.length}`;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export interface UseDramaRun {
  run: DramaRun | null;
  busy: boolean;
  error: string;
  startStep: (
    step: "cast" | "frame" | "voice",
    input?: Omit<EstimateInput, "step">,
  ) => Promise<void>;
  startShot: (
    shotId: string,
    input?: { target?: "frame" | "clip" | "all"; force?: boolean; degrade?: boolean },
  ) => Promise<void>;
  cancel: () => Promise<void>;
  reset: () => void;
}

export function useDramaRun(
  seriesId: string,
  episodeId: string,
  onDone: () => void,
): UseDramaRun {
  const [run, setRun] = useState<DramaRun | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const alive = useRef(true);
  const done = useRef(onDone);

  useEffect(() => {
    done.current = onDone;
  }, [onDone]);

  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  const poll = useCallback(
    async (runId: string) => {
      while (alive.current) {
        const next = await dramaApi.getRun(seriesId, episodeId, runId);
        if (!alive.current) return;
        setRun(next);
        if (isTerminalRun(next.status)) {
          setBusy(false);
          done.current();
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
    },
    [seriesId, episodeId],
  );

  const begin = useCallback(
    async (request: () => Promise<{ run_id: string }>) => {
      setBusy(true);
      setError("");
      try {
        const started = await request();
        await poll(started.run_id);
      } catch (cause) {
        if (!alive.current) return;
        setBusy(false);
        setError(messageOf(cause));
      }
    },
    [poll],
  );

  const startStep = useCallback(
    (step: "cast" | "frame" | "voice", input: Omit<EstimateInput, "step"> = {}) =>
      begin(() => dramaApi.runStep(seriesId, episodeId, step, input)),
    [begin, seriesId, episodeId],
  );

  const startShot = useCallback(
    (
      shotId: string,
      input: { target?: "frame" | "clip" | "all"; force?: boolean; degrade?: boolean } = {},
    ) => begin(() => dramaApi.runShot(seriesId, episodeId, shotId, input)),
    [begin, seriesId, episodeId],
  );

  const cancel = useCallback(async () => {
    if (run === null) return;
    try {
      await dramaApi.cancelRun(seriesId, episodeId, run.run_id);
    } catch (cause) {
      if (alive.current) setError(messageOf(cause));
    }
  }, [run, seriesId, episodeId]);

  const reset = useCallback(() => {
    setRun(null);
    setBusy(false);
    setError("");
  }, []);

  return { run, busy, error, startStep, startShot, cancel, reset };
}
