import { useEffect, useState } from 'react'
import CostGate from './CostGate'
import { downloadFile } from './download'
import { estimateImageCost, unitPrice } from './imageCost'
import {
  readPickedFiles,
  validatePicked,
  type PickedFile,
  type PreviewImage,
  type RefImage,
} from './imagePicker'
import { ImageLightbox, PickedImageGrid } from './pickImages'
import { useImagePicker } from './useImagePicker'
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

interface EditItem {
  id: string
  prompt: string
  image: RefImage | null
  refs: RefImage[]
}

type PickTarget = { itemId: string; field: 'image' | 'refs' } | null

const MODE_LABELS: Record<ImageModeName, string> = {
  t2i: '文生图',
  i2i: '图生图·编辑',
  series: '系列图',
}

const MAX_EDIT_ITEMS = 20

let itemSeq = 0
function newEditItem(): EditItem {
  itemSeq += 1
  return { id: `item-${itemSeq}`, prompt: '', image: null, refs: [] }
}

function imageJobUrl(id: string): string {
  return `/api/images/${id}`
}

function imageFileUrl(id: string, index: number): string {
  return `/api/images/${id}/${index}`
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
  const [editItems, setEditItems] = useState<EditItem[]>(() => [newEditItem()])
  const [pickTarget, setPickTarget] = useState<PickTarget>(null)
  const [preview, setPreview] = useState<PreviewImage | null>(null)
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

  // wan2.7 pro 的 4K 只在「文生图、非组图」下可用；其余组合提前隐藏，避免确认后 400。
  const availableSizes = (model?.sizes ?? []).filter(
    (s) => s !== '4K' || (model?.id.endsWith('-pro') && mode === 't2i'),
  )
  const unit = model ? unitPrice(model.prices, size || null) : 0
  const estimate = model
    ? estimateImageCost(model.prices, size || null, mode === 'i2i' ? editItems.length : n)
    : 0
  const completed = job?.status === 'completed'
  const polling = job?.status === 'running'
  const maxItemRefs = Math.max(0, (model?.max_ref_images ?? 1) - 1)

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

  const applyRefs = (target: PickTarget, picked: PickedFile[]) => {
    setFormError('')
    const items: RefImage[] = []
    for (const file of picked) {
      const result = validatePicked(file)
      if (typeof result === 'string') {
        setFormError(result)
        return
      }
      items.push(result)
    }
    if (items.length === 0) return

    if (!target) {
      const max = model?.max_ref_images ?? 0
      if (refs.length + items.length > max) {
        setFormError(`参考图最多 ${max} 张`)
        return
      }
      setRefs([...refs, ...items])
      return
    }

    if (target.field === 'image') {
      const image = items[0]
      setEditItems((prev) =>
        prev.map((item) => (item.id === target.itemId ? { ...item, image } : item)),
      )
      return
    }

    const item = editItems.find((i) => i.id === target.itemId)
    if (!item) return
    if (item.refs.length + items.length > maxItemRefs) {
      setFormError(`每条最多 ${maxItemRefs} 张参考图（被编辑图片占 1 个位置）`)
      return
    }
    setEditItems((prev) =>
      prev.map((i) =>
        i.id === target.itemId ? { ...i, refs: [...i.refs, ...items] } : i,
      ),
    )
  }

  const { openPicker: openNativePicker, picker } = useImagePicker((files, error) => {
    if (error) {
      setFormError(`选择图片失败：${error}`)
      return
    }
    applyRefs(pickTarget, files)
    setPickTarget(null)
  })

  const openPicker = (target: PickTarget) => {
    setPickTarget(target)
    openNativePicker(target === null || target.field === 'refs')
  }

  const addFiles = async (target: PickTarget, files: FileList) => {
    applyRefs(target, await readPickedFiles(files))
  }

  const updateItem = (id: string, patch: Partial<EditItem>) => {
    setEditItems((prev) => prev.map((item) => (item.id === id ? { ...item, ...patch } : item)))
  }

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    if (mode === 'i2i') {
      for (const [index, item] of editItems.entries()) {
        if (!item.prompt.trim()) {
          setFormError(`第 ${index + 1} 条缺少提示词`)
          return
        }
        if (!item.image) {
          setFormError(`第 ${index + 1} 条缺少被编辑的图片`)
          return
        }
      }
    } else if (!prompt.trim()) {
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
    const seedValue = seed.trim() ? Number(seed) : undefined
    const body =
      mode === 'i2i'
        ? {
            model: model.id,
            mode,
            size: size || undefined,
            seed: seedValue,
            items: editItems.map((item) => ({
              prompt: item.prompt.trim(),
              image: item.image!.dataUrl,
              refs: item.refs.map((r) => r.dataUrl),
            })),
          }
        : {
            model: model.id,
            mode,
            prompt: prompt.trim(),
            negative_prompt: negative.trim() || undefined,
            size: size || undefined,
            n,
            seed: seedValue,
            ...(mode === 't2i' ? {} : { refs: refs.map((r) => r.dataUrl) }),
          }
    try {
      const res = await fetch('/api/images', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
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

          {mode === 'i2i' ? (
            <div className="edit-items">
              {editItems.map((item, index) => (
                <section className="edit-item" key={item.id}>
                  <header className="edit-item-head">
                    <span>第 {index + 1} 条</span>
                    {editItems.length > 1 && (
                      <button
                        type="button"
                        className="btn-ghost"
                        onClick={() => setEditItems(editItems.filter((i) => i.id !== item.id))}
                      >
                        删除
                      </button>
                    )}
                  </header>

                  <div className="field">
                    <label>提示词</label>
                    <textarea
                      rows={3}
                      placeholder="描述这一条要改成什么样，例如：把背景换成海边黄昏"
                      value={item.prompt}
                      onChange={(e) => updateItem(item.id, { prompt: e.target.value })}
                    />
                  </div>

                  <div className="field">
                    <label>
                      被编辑的图片 <span className="value">（1 张）</span>
                    </label>
                    <PickedImageGrid
                      images={item.image ? [item.image] : []}
                      max={1}
                      addLabel="选择图片"
                      onAdd={() => openPicker({ itemId: item.id, field: 'image' })}
                      onRemove={() => updateItem(item.id, { image: null })}
                      onPreview={setPreview}
                      onDropFiles={(files) => void addFiles({ itemId: item.id, field: 'image' }, files)}
                    />
                  </div>

                  <div className="field">
                    <label>
                      参考图 <span className="value">（可选，最多 {maxItemRefs} 张）</span>
                    </label>
                    <PickedImageGrid
                      images={item.refs}
                      max={maxItemRefs}
                      addLabel="添加参考图"
                      onAdd={() => openPicker({ itemId: item.id, field: 'refs' })}
                      onRemove={(i) =>
                        updateItem(item.id, { refs: item.refs.filter((_, idx) => idx !== i) })
                      }
                      onPreview={setPreview}
                      onDropFiles={(files) => void addFiles({ itemId: item.id, field: 'refs' }, files)}
                    />
                  </div>
                </section>
              ))}

              <button
                type="button"
                className="btn-ghost add-item"
                disabled={editItems.length >= MAX_EDIT_ITEMS}
                onClick={() => setEditItems([...editItems, newEditItem()])}
              >
                ＋ 添加一条（{editItems.length}/{MAX_EDIT_ITEMS}）
              </button>
            </div>
          ) : (
            <>
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

              {mode === 'series' && (model?.max_ref_images ?? 0) > 0 && (
                <div className="field">
                  <label>
                    参考图{' '}
                    <span className="value">
                      （已选 {refs.length}/{model?.max_ref_images}，单张 ≤10MB）
                    </span>
                  </label>
                  <PickedImageGrid
                    images={refs}
                    max={model?.max_ref_images ?? 0}
                    addLabel="添加 / 拖入"
                    onAdd={() => openPicker(null)}
                    onRemove={(i) => setRefs(refs.filter((_, idx) => idx !== i))}
                    onPreview={setPreview}
                    onDropFiles={(files) => void addFiles(null, files)}
                  />
                  <p className="value ref-hint">点击缩略图可放大预览，支持把图片直接拖进这个区域。</p>
                </div>
              )}
            </>
          )}

          {mode === 'i2i' && (
            <>
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
            </>
          )}

          <div className="estimate">
            预估费用 <strong>¥{estimate.toFixed(2)}</strong>
            <span className="value">
              （单价 ¥{unit.toFixed(2)}/张 × {mode === 'i2i' ? editItems.length : n} 张，以实际账单为准）
            </span>
          </div>

          {formError && <div className="form-error">{formError}</div>}

          {confirming ? (
            <CostGate
              estimate={estimate}
              detail={`单价 ¥${unit.toFixed(2)}/张 × ${mode === 'i2i' ? editItems.length : n} 张`}
              onCancel={() => setConfirming(false)}
              onConfirm={() => void confirmAndGenerate()}
            />
          ) : (
            <button type="submit" disabled={submitting || polling}>
              {polling ? '生成中...' : '生成图片'}
            </button>
          )}

          {picker}
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
                  <button
                    key={r.index}
                    type="button"
                    className="image-thumb"
                    aria-label={`预览第 ${r.index} 张`}
                    onClick={() =>
                      setPreview({
                        src: imageFileUrl(job.id, r.index),
                        name: `image-${String(r.index).padStart(2, '0')}.png`,
                      })
                    }
                  >
                    <img src={imageFileUrl(job.id, r.index)} alt={`生成图 ${r.index}`} />
                  </button>
                ))}
              </div>
              <div className="downloads">
                {job.results.filter((r) => r.ok !== false).map((r) => (
                  <button
                    key={r.index}
                    type="button"
                    className="btn"
                    onClick={() => {
                      void downloadFile(
                        imageFileUrl(job.id, r.index),
                        `image-${String(r.index).padStart(2, '0')}.png`,
                      ).catch((e) => setFormError(`${e}`))
                    }}
                  >
                    下载第 {r.index} 张
                  </button>
                ))}
              </div>
              {job.results.some((r) => r.ok === false) && (
                <div className="error">部分图片失败，可重新生成或到百炼控制台下载。</div>
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

      <ImageLightbox preview={preview} onClose={() => setPreview(null)} />
    </div>
  )
}
