import { useEffect, useRef, useState } from 'react'
import CostGate from './CostGate'
import { estimateImageCost, unitPrice } from './imageCost'
import { useJob, type JobBase } from './useJob'

type ImageModeName = 't2i' | 'i2i' | 'series'

interface ImageModelDto {
  id: string
  label: string
  family: 'qwen3' | 'wan27' | 'zImage'
  modes: ImageModeName[]
  max_images: number
  max_ref_images: number
  supports_negative_prompt: boolean
  sizes: string[]
  prices: Record<string, number>
}

interface ImageJobDto extends JobBase {
  results?: Array<{ index: number; path: string; ok?: boolean; error?: string }>
  cost?: number
}

interface RefImage {
  name: string
  dataUrl: string
}

const MODE_LABELS: Record<ImageModeName, string> = {
  t2i: '文生图',
  i2i: '图生图·编辑',
  series: '系列图',
}

const MAX_REF_BYTES = 10 * 1024 * 1024
const ACCEPTED_REF_TYPES = ['image/png', 'image/jpeg', 'image/webp']

function imageJobUrl(id: string): string {
  return `/api/images/${id}`
}

function imageFileUrl(id: string, index: number): string {
  return `/api/images/${id}/${index}`
}

function readAsDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result))
    reader.onerror = () => reject(reader.error ?? new Error('读取图片失败'))
    reader.readAsDataURL(file)
  })
}

export default function ImageStudio() {
  const [models, setModels] = useState<ImageModelDto[]>([])
  const [modelId, setModelId] = useState('')
  const [mode, setMode] = useState<ImageModeName>('t2i')
  const [prompt, setPrompt] = useState('')
  const [negative, setNegative] = useState('')
  const [size, setSize] = useState('')
  const [n, setN] = useState(1)
  const [seed, setSeed] = useState('')
  const [refs, setRefs] = useState<RefImage[]>([])
  const [preview, setPreview] = useState<RefImage | null>(null)
  const [dragging, setDragging] = useState(false)
  const dragDepth = useRef(0)
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [confirming, setConfirming] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState('')
  const [jobId, setJobId] = useState<string | null>(null)

  useEffect(() => {
    fetch('/api/models')
      .then((r) => r.json())
      .then((data) => {
        const list: ImageModelDto[] = data.image ?? []
        setModels(list)
        if (list.length === 0) return
        const preferred = list.find((m) => m.id === data.image_default_model) ?? list[0]
        setModelId(preferred.id)
        setMode(preferred.modes[0] ?? 't2i')
      })
      .catch((e) => console.error('Failed to load models:', e))
  }, [])

  const job = useJob<ImageJobDto>(jobId, imageJobUrl)
  const model = models.find((m) => m.id === modelId)

  useEffect(() => {
    if (!preview) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setPreview(null)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [preview])

  // wan2.7 pro 的 4K 只在「文生图、非组图」下可用；其余组合提前隐藏，避免确认后 400。
  const availableSizes = (model?.sizes ?? []).filter(
    (s) => s !== '4K' || (model?.id.endsWith('-pro') && mode === 't2i'),
  )
  const estimate = model ? estimateImageCost(model.prices, size || null, n) : 0
  const price = model ? unitPrice(model.prices, size || null) : 0
  const completed = job?.status === 'completed'
  const polling = job?.status === 'running'

  const selectModel = (id: string) => {
    const next = models.find((m) => m.id === id)
    if (!next) return
    setModelId(id)
    if (!next.modes.includes(mode)) setMode(next.modes[0] ?? 't2i')
    setN((current) => Math.min(current, next.max_images))
    if (size && !next.sizes.includes(size)) setSize('')
    if (next.max_ref_images === 0) setRefs([])
    setConfirming(false)
  }

  const addRefs = async (files: FileList | null) => {
    if (!files || !model) return
    setFormError('')
    const next: RefImage[] = []
    for (const file of Array.from(files)) {
      if (!ACCEPTED_REF_TYPES.includes(file.type)) {
        setFormError(`${file.name} 仅支持 PNG / JPEG / WebP`)
        return
      }
      if (file.size > MAX_REF_BYTES) {
        setFormError(`${file.name} 超过 10MB`)
        return
      }
      next.push({ name: file.name, dataUrl: await readAsDataUrl(file) })
    }
    const merged = [...refs, ...next]
    if (merged.length > model.max_ref_images) {
      setFormError(`参考图最多 ${model.max_ref_images} 张`)
      return
    }
    setRefs(merged)
  }

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (!prompt.trim()) {
      setFormError('请先输入提示词')
      return
    }
    if (mode === 'i2i' && refs.length === 0) {
      setFormError('图生图至少需要 1 张参考图')
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
      const res = await fetch('/api/images', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          model: model.id,
          mode,
          prompt: prompt.trim(),
          negative_prompt: negative.trim() || undefined,
          size: size || undefined,
          n,
          seed: seed.trim() ? Number(seed) : undefined,
          ...(mode === 't2i' ? {} : { refs: refs.map((r) => r.dataUrl) }),
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
            <label>生成方式</label>
            <div className="mode-tabs sub-tabs">
              {(model?.modes ?? []).map((m) => (
                <button
                  key={m}
                  type="button"
                  className={mode === m ? 'tab active' : 'tab'}
                  onClick={() => {
                    setMode(m)
                    setN((current) => Math.min(current, m === 'series' ? 12 : (model?.max_images ?? 1)))
                    setConfirming(false)
                  }}
                >
                  {MODE_LABELS[m]}
                </button>
              ))}
            </div>
          </div>

          <div className="field">
            <label>提示词</label>
            <textarea
              rows={3}
              placeholder="例如：冬日北京的都市街景，水墨风格，暖光灯笼"
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
            />
          </div>

          {model?.supports_negative_prompt && (
            <div className="field">
              <label>
                反向提示词 <span className="value">（可选）</span>
              </label>
              <textarea
                rows={2}
                placeholder="不希望出现的元素，例如：低清晰度、肢体畸形"
                value={negative}
                onChange={(e) => setNegative(e.target.value)}
              />
            </div>
          )}

          <div className="field">
            <label>尺寸</label>
            <select value={size} onChange={(e) => setSize(e.target.value)}>
              <option value="">自动（由模型推荐）</option>
              {availableSizes.map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </select>
          </div>

          <div className="field">
            <label>
              张数 <span className="value">{n} 张</span>
              {mode === 'series' && <span className="value">（最多 n 张，实际由模型决定）</span>}
            </label>
            <input
              type="range"
              min={1}
              max={mode === 'series' ? 12 : (model?.max_images ?? 1)}
              step={1}
              value={n}
              onChange={(e) => setN(Number(e.target.value))}
            />
          </div>

          <div className="field">
            <label>
              种子 <span className="value">（可选，可复现）</span>
            </label>
            <input
              type="number"
              min={0}
              placeholder="留空由服务端随机"
              value={seed}
              onChange={(e) => setSeed(e.target.value)}
            />
          </div>

          {mode !== 't2i' && (model?.max_ref_images ?? 0) > 0 && (
            <div className="field">
              <label>
                参考图{' '}
                <span className="value">
                  （已选 {refs.length}/{model?.max_ref_images}，单张 ≤10MB）
                </span>
              </label>
              <div
                className={dragging ? 'ref-grid dragging' : 'ref-grid'}
                onDragEnter={(e) => {
                  e.preventDefault()
                  dragDepth.current += 1
                  setDragging(true)
                }}
                onDragOver={(e) => e.preventDefault()}
                onDragLeave={() => {
                  dragDepth.current -= 1
                  if (dragDepth.current <= 0) {
                    dragDepth.current = 0
                    setDragging(false)
                  }
                }}
                onDrop={(e) => {
                  e.preventDefault()
                  dragDepth.current = 0
                  setDragging(false)
                  void addRefs(e.dataTransfer.files)
                }}
              >
                {refs.map((ref, i) => (
                  <div className="ref-tile" key={`${ref.name}-${i}`}>
                    <button
                      type="button"
                      className="ref-preview"
                      aria-label={`预览 ${ref.name}`}
                      onClick={() => setPreview(ref)}
                    >
                      <img src={ref.dataUrl} alt={ref.name} title={ref.name} />
                    </button>
                    <button
                      type="button"
                      className="ref-remove"
                      aria-label={`移除 ${ref.name}`}
                      onClick={() => setRefs(refs.filter((_, idx) => idx !== i))}
                    >
                      ×
                    </button>
                  </div>
                ))}
                {refs.length < (model?.max_ref_images ?? 0) && (
                  <button
                    type="button"
                    className="ref-add"
                    aria-label="添加参考图"
                    onClick={() => fileInputRef.current?.click()}
                  >
                    <span>+</span>
                    <small>添加 / 拖入</small>
                  </button>
                )}
              </div>
              <p className="value ref-hint">点击缩略图可放大预览，支持把图片直接拖进这个区域。</p>
              <input
                ref={fileInputRef}
                className="ref-input"
                type="file"
                accept={ACCEPTED_REF_TYPES.join(',')}
                multiple
                onChange={(e) => {
                  void addRefs(e.target.files)
                  e.target.value = ''
                }}
              />
            </div>
          )}

          <div className="estimate">
            预估费用 <strong>¥{estimate.toFixed(2)}</strong>
            <span className="value">
              （单价 ¥{price.toFixed(2)}/张 × {n} 张，以实际账单为准）
            </span>
          </div>

          {formError && <div className="form-error">{formError}</div>}

          {confirming ? (
            <CostGate
              estimate={estimate}
              detail={`单价 ¥${price.toFixed(2)}/张 × ${n} 张`}
              onCancel={() => setConfirming(false)}
              onConfirm={() => void confirmAndGenerate()}
            />
          ) : (
            <button type="submit" disabled={submitting || polling}>
              {polling ? '生成中...' : '生成图片'}
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
          <h2>生成结果</h2>
          {completed && job?.results?.some((r) => r.ok !== false) ? (
            <>
              <div className="image-grid">
                {job.results.filter((r) => r.ok !== false).map((r) => (
                  <a key={r.index} href={imageFileUrl(job.id, r.index)} download>
                    <img src={imageFileUrl(job.id, r.index)} alt={`生成图 ${r.index}`} />
                  </a>
                ))}
              </div>
              <div className="downloads">
                {job.results.filter((r) => r.ok !== false).map((r) => (
                  <a
                    key={r.index}
                    href={imageFileUrl(job.id, r.index)}
                    className="btn"
                    download
                  >
                    下载第 {r.index} 张
                  </a>
                ))}
              </div>
              {job.results.some((r) => r.ok === false) && (
                <div className="error">部分图片下载失败，可重新生成或到百炼控制台下载。</div>
              )}
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

      {preview && (
        <div
          className="ref-lightbox"
          role="dialog"
          aria-modal="true"
          aria-label={`预览 ${preview.name}`}
          onClick={() => setPreview(null)}
        >
          <img
            src={preview.dataUrl}
            alt={preview.name}
            onClick={(e) => e.stopPropagation()}
          />
          <button
            type="button"
            className="ref-lightbox-close"
            aria-label="关闭预览"
            onClick={() => setPreview(null)}
          >
            ×
          </button>
        </div>
      )}
    </div>
  )
}
