import { useEffect, useState } from 'react'
import CostGate from './CostGate'
import { unitPriceForTier } from './imageCost'
import { useJob, type JobBase } from './useJob'

interface VideoModelDto {
  id: string
  label: string
  resolutions: string[]
  prices: Record<string, number>
  duration_min: number
  duration_max: number
  supports_audio: boolean
}

interface VideoJobDto extends JobBase {
  cost?: number
  video_path?: string
}

const RATIOS = ['adaptive', '16:9', '9:16', '1:1']

function videoJobUrl(id: string): string {
  return `/api/videos/${id}`
}

export default function TextToVideo() {
  const [models, setModels] = useState<VideoModelDto[]>([])
  const [modelId, setModelId] = useState('')
  const [prompt, setPrompt] = useState('')
  const [resolution, setResolution] = useState('720P')
  const [ratio, setRatio] = useState('adaptive')
  const [duration, setDuration] = useState(5)
  const [audio, setAudio] = useState(true)
  const [confirming, setConfirming] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState('')
  const [jobId, setJobId] = useState<string | null>(null)

  useEffect(() => {
    fetch('/api/models')
      .then((r) => r.json())
      .then((data) => {
        const list: VideoModelDto[] = data.video ?? []
        setModels(list)
        if (list.length === 0) return
        setModelId(list[0].id)
        setResolution(list[0].resolutions.includes('720P') ? '720P' : list[0].resolutions[0])
        setDuration((d) => Math.min(Math.max(d, list[0].duration_min), list[0].duration_max))
      })
      .catch((e) => console.error('Failed to load video models:', e))
  }, [])

  const job = useJob<VideoJobDto>(jobId, videoJobUrl)
  const model = models.find((m) => m.id === modelId)
  const price = model ? unitPriceForTier(model.prices, resolution) : 0
  const estimate = price * duration
  const completed = job?.status === 'completed'
  const polling = job?.status === 'running'

  const selectModel = (id: string) => {
    const next = models.find((m) => m.id === id)
    if (!next) return
    setModelId(id)
    if (!next.resolutions.includes(resolution)) setResolution(next.resolutions[0])
    setDuration((d) => Math.min(Math.max(d, next.duration_min), next.duration_max))
    setConfirming(false)
  }

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (!prompt.trim()) {
      setFormError('请先输入提示词')
      return
    }
    setFormError('')
    setConfirming(true)
  }

  const confirmAndGenerate = async () => {
    if (!model) return
    setConfirming(false)
    setSubmitting(true)
    try {
      const res = await fetch('/api/videos', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: model.id,
          prompt: prompt.trim(),
          resolution,
          ratio,
          duration,
          audio,
        }),
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok) {
        setFormError(data.error || `提交失败（HTTP ${res.status}）`)
        return
      }
      setJobId(data.id)
    } catch (err) {
      setFormError(`提交失败：${err}`)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div className="layout">
      <div className="col-left">
        <form onSubmit={handleSubmit} className="form">
          <div className="field">
            <label>模型</label>
            <select value={modelId} onChange={(e) => selectModel(e.target.value)}>
              {models.map((m) => (
                <option key={m.id} value={m.id}>
                  {m.label}
                </option>
              ))}
            </select>
          </div>

          <div className="field">
            <label>提示词</label>
            <textarea
              rows={4}
              placeholder="例如：一只猫在草地上奔跑，电影感，逆光"
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
            />
          </div>

          <div className="field">
            <label>分辨率</label>
            <select value={resolution} onChange={(e) => setResolution(e.target.value)}>
              {(model?.resolutions ?? []).map((r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ))}
            </select>
          </div>

          <div className="field">
            <label>宽高比</label>
            <select value={ratio} onChange={(e) => setRatio(e.target.value)}>
              {RATIOS.map((r) => (
                <option key={r} value={r}>
                  {r}
                </option>
              ))}
            </select>
          </div>

          <div className="field">
            <label>
              时长 <span className="value">{duration} 秒</span>
            </label>
            <input
              type="range"
              min={model?.duration_min ?? 2}
              max={model?.duration_max ?? 30}
              step={1}
              value={duration}
              onChange={(e) => setDuration(Number(e.target.value))}
            />
          </div>

          {model?.supports_audio && (
            <div className="field">
              <label>
                <input
                  type="checkbox"
                  checked={audio}
                  onChange={(e) => setAudio(e.target.checked)}
                />{' '}
                保留原生音频
              </label>
            </div>
          )}

          <div className="estimate">
            预估费用 <strong>¥{estimate.toFixed(2)}</strong>
            <span className="value">
              （单价 ¥{price.toFixed(2)}/秒 × {duration} 秒，以实际账单为准）
            </span>
          </div>

          {formError && <div className="form-error">{formError}</div>}

          {confirming ? (
            <CostGate
              estimate={estimate}
              detail={`单价 ¥${price.toFixed(2)}/秒 × ${duration} 秒`}
              onCancel={() => setConfirming(false)}
              onConfirm={() => void confirmAndGenerate()}
            />
          ) : (
            <button type="submit" disabled={submitting || polling}>
              {polling ? '生成中...' : '生成视频'}
            </button>
          )}
        </form>

        {job && (
          <section className="result">
            <h2>运行状态</h2>
            <div className={`status ${job.status}`}>{job.status}</div>
            {job.error && <div className="error">错误：{job.error}</div>}
            <div className="logs">
              {job.logs.map((log, i) => (
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
          {completed && job ? (
            <>
              <video className="preview" controls src={`/api/videos/${job.id}/video`} />
              <div className="downloads">
                <a href={`/api/videos/${job.id}/video`} className="btn">
                  下载视频
                </a>
              </div>
              {typeof job.cost === 'number' && (
                <p className="value">本次计费 ¥{job.cost.toFixed(2)}（以实际账单为准）</p>
              )}
            </>
          ) : (
            <div className="video-placeholder">
              {job?.status === 'running' ? '生成中，请稍候…' : '生成后在这里预览与下载'}
            </div>
          )}
        </div>
      </aside>
    </div>
  )
}
