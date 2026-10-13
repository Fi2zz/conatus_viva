import { useState, useEffect, useCallback, useRef } from 'react'
import './App.css'

interface Dialect {
  code: string
  label: string
  instruction: string
}

interface T2vConfig {
  yuan_per_second: number
  duration_min: number
  duration_max: number
}

interface RunStatus {
  id: string
  status: 'running' | 'completed' | 'failed'
  logs: string[]
  video_path?: string
  error?: string
}

const DEFAULT_T2V: T2vConfig = {
  yuan_per_second: 0.15,
  duration_min: 2,
  duration_max: 30,
}

function App() {
  const [dialects, setDialects] = useState<Dialect[]>([])
  const [t2v, setT2v] = useState<T2vConfig>(DEFAULT_T2V)
  const [duration, setDuration] = useState(5)
  const [dialect, setDialect] = useState('')
  const [theme, setTheme] = useState('')
  const [run, setRun] = useState<RunStatus | null>(null)
  const [polling, setPolling] = useState(false)
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null)

  useEffect(() => {
    fetch('/api/dialects')
      .then((r) => r.json())
      .then((d) => {
        setDialects(d.dialects ?? [])
        if (d.t2v) setT2v(d.t2v)
        if (d.dialects?.length) setDialect(d.dialects[0].code)
      })
      .catch((e) => console.error('Failed to load dialects:', e))
  }, [])

  const stopPolling = useCallback(() => {
    if (pollRef.current) {
      clearInterval(pollRef.current)
      pollRef.current = null
    }
    setPolling(false)
  }, [])

  useEffect(() => () => stopPolling(), [stopPolling])

  const pollRun = useCallback(
    (id: string) => {
      pollRef.current = setInterval(async () => {
        try {
          const res = await fetch(`/api/t2v/${id}`)
          const data: RunStatus = await res.json()
          setRun(data)
          if (data.status !== 'running') stopPolling()
        } catch (e) {
          console.error('Poll failed:', e)
          stopPolling()
        }
      }, 1000)
    },
    [stopPolling],
  )

  const estimate = duration * t2v.yuan_per_second

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!theme.trim()) {
      alert('请先输入主题文字')
      return
    }
    const ok = window.confirm(
      `预估费用 ¥${estimate.toFixed(2)}（以实际账单为准），确认生成？`,
    )
    if (!ok) return

    const res = await fetch('/api/t2v', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ duration, dialect, theme: theme.trim() }),
    })
    const data = await res.json()
    if (!res.ok) {
      alert(data.error || '提交失败')
      return
    }
    setRun({ id: data.id, status: 'running', logs: ['任务已提交...'] })
    setPolling(true)
    pollRun(data.id)
  }

  return (
    <div className="app">
      <header>
        <h1>方言配音主讲人</h1>
        <p className="subtitle">
          填主题、选方言、定时长，生成带卡通主讲人（左下角）的方言口播视频
        </p>
      </header>

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
          <select value={dialect} onChange={(e) => setDialect(e.target.value)}>
            {dialects.map((d) => (
              <option key={d.code} value={d.code}>
                {d.label}
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
          <span className="value">（以实际账单为准）</span>
        </div>

        <button type="submit" disabled={polling}>
          {polling ? '生成中...' : '生成视频'}
        </button>
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

          {run.status === 'completed' && (
            <>
              <video
                className="preview"
                controls
                src={`/api/t2v/${run.id}/video`}
              />
              <div className="downloads">
                <a
                  href={`/api/t2v/${run.id}/video`}
                  download
                  className="btn"
                >
                  下载视频
                </a>
              </div>
            </>
          )}
        </section>
      )}
    </div>
  )
}

export default App
