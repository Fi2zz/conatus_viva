/// 方言配音主讲人工具（从 App.tsx 提取，行为保持不变）。
///
/// P1 只作为工作台「声音」工序里的通用工具；逐句配音在 P3 接入。
import { useCallback, useEffect, useRef, useState } from "react";

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

interface Props {
  initialTheme?: string;
  contextLabel?: string;
}

export default function SpeakerStudio({
  initialTheme = "",
  contextLabel,
}: Props) {
  const [dialects, setDialects] = useState<Dialect[]>([]);
  const [t2v, setT2v] = useState<T2vConfig>(DEFAULT_T2V);
  const [duration, setDuration] = useState(5);
  const [dialect, setDialect] = useState("");
  const [theme, setTheme] = useState(initialTheme);
  const [run, setRun] = useState<RunStatus | null>(null);
  const [polling, setPolling] = useState(false);
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
  const unitPrice = Number(t2v.yuan_per_second.toFixed(4));

  const handleSubmit = (event: React.FormEvent) => {
    event.preventDefault();
    if (!theme.trim()) {
      setFormError("请先输入主题文字");
      return;
    }
    setFormError("");
    setConfirming(true);
  };

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
    <div className="layout">
      <div className="col-left">
        <form onSubmit={handleSubmit} className="form">
          {contextLabel !== undefined && contextLabel !== "" && (
            <p className="value">{contextLabel}</p>
          )}
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
              onChange={(event) => setDuration(Number(event.target.value))}
            />
          </div>

          <div className="field">
            <label>方言类型</label>
            <select value={dialect} onChange={(event) => setDialect(event.target.value)}>
              {dialects.map((item) => (
                <option key={item.code} value={item.code}>
                  {item.name ?? item.label}
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
              onChange={(event) => setTheme(event.target.value)}
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
                （单价 ¥{unitPrice}/秒 × {duration} 秒，以实际账单为准），确认生成？
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
              {run.logs.map((log, index) => (
                <div key={index} className="log-line">
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
              <video className="preview" controls src={`/api/t2v/${run.id}/video`} />
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
  );
}
