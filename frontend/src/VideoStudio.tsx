import { useEffect, useState } from 'react'
import CostGate from './CostGate'
import { downloadFile } from './download'
import {
  readPickedFiles,
  validatePicked,
  type PickedFile,
  type PreviewImage,
  type RefImage,
} from './imagePicker'
import { ImageLightbox, PickedImageGrid } from './pickImages'
import { unitPriceForTier } from './imageCost'
import { useImagePicker } from './useImagePicker'
import { estimateVideoCost } from './videoCost'
import { useJob, type JobBase } from './useJob'

export type VideoMode = 't2v' | 'i2v'

interface VideoModelDto {
  id: string
  label: string
  modes?: VideoMode[]
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

/**
 * 通用视频生成页。`t2v` 是纯提示词文生视频，`i2v` 以一张首帧图片 +
 * 可选运动提示词生成；两者共用任务轮询、计费口径与成片预览。
 */
export default function VideoStudio({ mode }: { mode: VideoMode }) {
  const imageToVideo = mode === 'i2v'
  const [models, setModels] = useState<VideoModelDto[]>([])
  const [modelId, setModelId] = useState('')
  const [prompt, setPrompt] = useState('')
  const [firstFrame, setFirstFrame] = useState<RefImage | null>(null)
  const [preview, setPreview] = useState<PreviewImage | null>(null)
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
        const list: VideoModelDto[] = (data.video ?? []).filter((m: VideoModelDto) =>
          (m.modes ?? []).includes(mode),
        )
        setModels(list)
        if (list.length === 0) return
        setModelId(list[0].id)
        setResolution(list[0].resolutions.includes('720P') ? '720P' : list[0].resolutions[0])
        setDuration((d) => Math.min(Math.max(d, list[0].duration_min), list[0].duration_max))
      })
      .catch((e) => console.error('Failed to load video models:', e))
  }, [mode])

  const job = useJob<VideoJobDto>(jobId, videoJobUrl)
  const model = models.find((m) => m.id === modelId)
  const price = model ? unitPriceForTier(model.prices, resolution) : 0
  const estimate = model ? estimateVideoCost(model.prices, resolution, duration) : 0
  const completed = job?.status === 'completed'
  const polling = job?.status === 'running'

  const applyFirstFrame = (files: PickedFile[]) => {
    if (files.length === 0) return
    const result = validatePicked(files[0])
    if (typeof result === 'string') {
      setFormError(result)
      return
    }
    setFirstFrame(result)
    setFormError('')
  }

  const { openPicker, picker } = useImagePicker((files, error) => {
    if (error) {
      setFormError(`选择图片失败：${error}`)
      return
    }
    applyFirstFrame(files)
  })

  const addFirstFrame = async (files: FileList) => {
    applyFirstFrame(await readPickedFiles(files))
  }

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
    if (imageToVideo && !firstFrame) {
      setFormError('请先选择首帧图片')
      return
    }
    if (!imageToVideo && !prompt.trim()) {
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
          mode,
          prompt: prompt.trim(),
          resolution,
          duration,
          audio,
          ...(imageToVideo ? { image: firstFrame!.dataUrl } : { ratio }),
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

          {imageToVideo && (
            <div className="field">
              <label>
                首帧图片 <span className="value">（PNG / JPEG / WebP，单张 ≤10MB）</span>
              </label>
              <PickedImageGrid
                images={firstFrame ? [firstFrame] : []}
                max={1}
                addLabel="选择图片"
                onAdd={() => openPicker(false)}
                onRemove={() => setFirstFrame(null)}
                onPreview={setPreview}
                onDropFiles={(files) => void addFirstFrame(files)}
              />
              <p className="value ref-hint">
                画面从这张图开始，提示词描述希望发生的运动；点击缩略图可放大预览。
              </p>
            </div>
          )}

          <div className="field">
            <label>
              提示词
              {imageToVideo && <span className="value">（可选，描述画面运动）</span>}
            </label>
            <textarea
              rows={4}
              placeholder={
                imageToVideo
                  ? '例如：镜头缓慢推进，人物轻轻转头，光影流动'
                  : '例如：一只猫在草地上奔跑，电影感，逆光'
              }
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

          {imageToVideo ? (
            <div className="field">
              <label>
                宽高比 <span className="value">adaptive（跟随首帧图片）</span>
              </label>
            </div>
          ) : (
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
          )}

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

          {picker}
        </form>

        {job && (
          <section className="result">
            <h2>运行状态</h2>
            <div className={`status ${job.status}`}>{job.status}</div>
            {job.error && <div className="error">错误：{job.error}</div>}
            {job.status === 'failed' && (
              <p className="value">
                超时或失败时任务可能仍在运行，请先到百炼控制台核对，避免重复提交产生二次计费。
              </p>
            )}
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
                <button
                  type="button"
                  className="btn"
                  onClick={() => {
                    void downloadFile(`/api/videos/${job.id}/video`, 'video.mp4').catch((e) =>
                      setFormError(`${e}`),
                    )
                  }}
                >
                  下载视频
                </button>
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

      <ImageLightbox preview={preview} onClose={() => setPreview(null)} />
    </div>
  )
}
