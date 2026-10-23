import { useState, useEffect, useCallback, useRef } from "react";
import EditCostEstimator from "./EditCostEstimator";
import ImageStudio from "./ImageStudio";
import ShortDrama from "./ShortDrama";
import VideoStudio from "./VideoStudio";
import "./App.css";

interface Dialect {
  code: string;
  label: string;
  name?: string;
  instruction: string;
}

interface T2vConfig {
  yuan_per_second: number;
  duration_min: number;
  duration_max: number;
}

interface RunStatus {
  id: string;
  status: "running" | "completed" | "failed";
  logs: string[];
  video_path?: string;
  error?: string;
}

const DEFAULT_T2V: T2vConfig = {
  // wan3.0-video 720P 限时 7 折实价（原价 0.6）；服务端 /api/dialects 会覆盖。
  yuan_per_second: 0.42,
  duration_min: 2,
  duration_max: 30,
};

function App() {
  const [mode, setMode] = useState<
    "image" | "video" | "i2v" | "speaker" | "edit-cost" | "short-drama"
  >("image");
  const [dialects, setDialects] = useState<Dialect[]>([]);
  const [t2v, setT2v] = useState<T2vConfig>(DEFAULT_T2V);
  const [duration, setDuration] = useState(5);
  const [dialect, setDialect] = useState("");
  const [theme, setTheme] = useState("");
  const [run, setRun] = useState<RunStatus | null>(null);
  const [polling, setPolling] = useState(false);
  // In-page confirmation: the app is hosted in a WKWebView that silently
  // drops window.confirm/alert, so the cost gate is rendered, not native.
  const [confirming, setConfirming] = useState(false);
  const [formError, setFormError] = useState("");
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    fetch("/api/dialects")
      .then((r) => r.json())
      .then((d) => {
        setDialects(d.dialects ?? []);
        if (d.t2v) setT2v(d.t2v);
        if (d.dialects?.length) setDialect(d.dialects[0].code);
      })
      .catch((e) => console.error("Failed to load dialects:", e));
  }, []);

  const stopPolling = useCallback(() => {
    if (pollRef.current) {
      clearInterval(pollRef.current);
      pollRef.current = null;
    }
    setPolling(false);
  }, []);

  useEffect(() => () => stopPolling(), [stopPolling]);

  const pollRun = useCallback(
    (id: string) => {
      pollRef.current = setInterval(async () => {
        try {
          const res = await fetch(`/api/t2v/${id}`);
          const data: RunStatus = await res.json();
          setRun(data);
          if (data.status !== "running") stopPolling();
        } catch (e) {
          console.error("Poll failed:", e);
          stopPolling();
        }
      }, 1000);
    },
    [stopPolling],
  );

  const estimate = duration * t2v.yuan_per_second;
  // Trim float noise (e.g. 0.7339238) for the on-screen unit price.
  const unitPrice = Number(t2v.yuan_per_second.toFixed(4));

  // Step 1: validate, then show the in-page cost confirmation.
  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!theme.trim()) {
      setFormError("请先输入主题文字");
      return;
    }
    setFormError("");
    setConfirming(true);
  };

  // Step 2: the user confirmed — actually start the paid generation.
  const confirmAndGenerate = async () => {
    setConfirming(false);
    try {
      const res = await fetch("/api/t2v", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ duration, dialect, theme: theme.trim() }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        setFormError(data.error || `提交失败（HTTP ${res.status}）`);
        return;
      }
      setRun({ id: data.id, status: "running", logs: ["任务已提交..."] });
      setPolling(true);
      pollRun(data.id);
    } catch (err) {
      setFormError(`提交失败：${err}`);
    }
  };

  const completed = run?.status === "completed";

  return (
    <div className="app">
      <header>
        <h1>Viva 创作台</h1>
        <p className="subtitle">图片合成、视频合成与方言配音主讲人</p>
      </header>

      <nav className="mode-tabs">
        <button
          type="button"
          className={mode === "image" ? "tab active" : "tab"}
          onClick={() => setMode("image")}
        >
          图片合成
        </button>
        <button
          type="button"
          className={mode === "video" ? "tab active" : "tab"}
          onClick={() => setMode("video")}
        >
          文生视频
        </button>
        <button
          type="button"
          className={mode === "i2v" ? "tab active" : "tab"}
          onClick={() => setMode("i2v")}
        >
          图生视频
        </button>
        <button
          type="button"
          className={mode === "speaker" ? "tab active" : "tab"}
          onClick={() => setMode("speaker")}
        >
          方言配音主讲人
        </button>
        <button
          type="button"
          className={mode === "edit-cost" ? "tab active" : "tab"}
          onClick={() => setMode("edit-cost")}
        >
          视频编辑成本
        </button>
        <button
          type="button"
          className={mode === "short-drama" ? "tab active" : "tab"}
          onClick={() => setMode("short-drama")}
        >
          短剧工作台
        </button>
      </nav>

      {mode === "image" && <ImageStudio />}

      {mode === "video" && <VideoStudio mode="t2v" />}

      {mode === "i2v" && <VideoStudio mode="i2v" />}

      {mode === "speaker" && (
        <div className="layout">
          <div className="col-left">
            <form onSubmit={handleSubmit} className="form">
              <div className="field">
                <label>
                  时长 <span className="value">{duration} 秒</span>
                </label>
                <input
                  type="range"
                  min={t2v.duration_min}
                  max={t2v.duration_max}
                  step={1}
                  value={duration}
                  onChange={(e) => setDuration(Number(e.target.value))}
                />
              </div>

              <div className="field">
                <label>方言类型</label>
                <select
                  value={dialect}
                  onChange={(e) => setDialect(e.target.value)}
                >
                  {dialects.map((d) => (
                    <option key={d.code} value={d.code}>
                      {d.name ?? d.label}
                    </option>
                  ))}
                </select>
              </div>

              <div className="field">
                <label>主题文字</label>
                <textarea
                  rows={3}
                  placeholder="例如：今天给大家讲讲河南的美食"
                  value={theme}
                  onChange={(e) => setTheme(e.target.value)}
                />
              </div>

              <div className="estimate">
                预估费用 <strong>¥{estimate.toFixed(2)}</strong>
                <span className="value">
                  （单价 ¥{unitPrice}/秒 × {duration} 秒，以实际账单为准）
                </span>
              </div>

              {formError && <div className="form-error">{formError}</div>}

              {confirming ? (
                <div className="confirm">
                  <div className="confirm-text">
                    预估费用 <strong>¥{estimate.toFixed(2)}</strong>
                    （单价 ¥{unitPrice}/秒 × {duration}{" "}
                    秒，以实际账单为准），确认生成？
                  </div>
                  <div className="confirm-actions">
                    <button
                      type="button"
                      className="btn-ghost"
                      onClick={() => setConfirming(false)}
                    >
                      取消
                    </button>
                    <button
                      type="button"
                      className="btn-primary"
                      onClick={confirmAndGenerate}
                    >
                      确认生成
                    </button>
                  </div>
                </div>
              ) : (
                <button type="submit" disabled={polling}>
                  {polling ? "生成中..." : "生成视频"}
                </button>
              )}
            </form>

            {run && (
              <section className="result">
                <h2>运行状态</h2>
                <div className={`status ${run.status}`}>{run.status}</div>

                {run.error && <div className="error">错误：{run.error}</div>}

                <div className="logs">
                  {run.logs.map((log, i) => (
                    <div key={i} className="log-line">
                      {log}
                    </div>
                  ))}
                </div>
              </section>
            )}
          </div>

          <aside className="col-right">
            <div className="video-card">
              <h2>成片预览</h2>
              {completed && run ? (
                <>
                  <video
                    className="preview"
                    controls
                    src={`/api/t2v/${run.id}/video`}
                  />
                  <div className="downloads">
                    <a href={`/api/t2v/${run.id}/video`} className="btn">
                      下载视频
                    </a>
                  </div>
                </>
              ) : (
                <div className="video-placeholder">
                  {run?.status === "running"
                    ? "生成中，请稍候…"
                    : "生成后在这里预览与下载"}
                </div>
              )}
            </div>
          </aside>
        </div>
      )}

      {mode === "edit-cost" && <EditCostEstimator />}

      {mode === "short-drama" && <ShortDrama />}
    </div>
  );
}

export default App;
