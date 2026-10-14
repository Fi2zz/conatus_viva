import { useEffect, useState } from 'react'
import {
  billedSeconds,
  estimateCost,
  isApplicable,
  parseEditModels,
  type EditModel,
} from './editCost'

const RESOLUTIONS = ['720P', '1080P'] as const
type Resolution = (typeof RESOLUTIONS)[number]

/// Read-only cost comparison for the three video-edit models. Data (prices,
/// limits, billing mode) comes from `GET /api/edit-models`; the arithmetic is
/// the pure module `editCost.ts`. Neither calls 百炼 nor touches an mp4.
export default function EditCostEstimator() {
  const [models, setModels] = useState<EditModel[] | null>(null)
  const [error, setError] = useState('')
  const [inputS, setInputS] = useState(5)
  const [resolution, setResolution] = useState<Resolution>('720P')
  const [reloadKey, setReloadKey] = useState(0)

  useEffect(() => {
    fetch('/api/edit-models')
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        return r.json()
      })
      .then(parseEditModels)
      .then(setModels)
      .catch((e) => {
        console.error('Failed to load edit models:', e)
        setError('加载编辑模型定价失败，请重试')
      })
  }, [reloadKey])

  if (error) {
    return (
      <div className="form">
        <div className="form-error">{error}</div>
        <button
          type="button"
          className="btn-ghost"
          onClick={() => {
            setError('')
            setReloadKey((k) => k + 1)
          }}
        >
          重试
        </button>
      </div>
    )
  }

  if (!models) {
    return <div className="form value">正在加载编辑模型定价…</div>
  }

  return (
    <div className="edit-cost">
      <div className="form">
        <h2>视频编辑成本</h2>
        <p className="subtitle">
          输入素材时长与分辨率，横向对比三个编辑模型的预估费用（不发起生成）。
        </p>

        <div className="field">
          <label>
            素材时长 <span className="value">{inputS} 秒</span>
          </label>
          <input
            type="range"
            min={1}
            max={60}
            step={1}
            value={inputS}
            onChange={(e) => setInputS(Number(e.target.value))}
          />
        </div>

        <div className="field">
          <label>分辨率</label>
          <select
            value={resolution}
            onChange={(e) => setResolution(e.target.value as Resolution)}
          >
            {RESOLUTIONS.map((r) => (
              <option key={r} value={r}>
                {r}
              </option>
            ))}
          </select>
        </div>
      </div>

      <table className="edit-table">
        <thead>
          <tr>
            <th>模型</th>
            <th>计费口径</th>
            <th>计费秒数</th>
            <th>预估费用</th>
            <th>免费额度</th>
          </tr>
        </thead>
        <tbody>
          {models.map((m) => {
            const applicable = isApplicable(m, inputS)
            const cost = estimateCost(m, inputS, resolution)
            return (
              <tr key={m.id} className={applicable ? '' : 'unavailable'}>
                <td>
                  <div className="model-name">{m.name}</div>
                  <div className="value">{m.id}</div>
                </td>
                <td>{m.billing === 'output' ? '仅输出' : '输入+输出'}</td>
                <td>{applicable ? `${billedSeconds(m, inputS)} 秒` : '—'}</td>
                <td>
                  {!applicable
                    ? `该模型输入需 ${m.input_min_s}–${m.input_max_s}s`
                    : cost === undefined
                      ? '不支持'
                      : `¥${cost.toFixed(2)}`}
                </td>
                <td>{m.free_quota_s} 秒</td>
              </tr>
            )
          })}
        </tbody>
      </table>

      <p className="value">
        以实际账单为准。单价与计费口径见
        docs/万相视频生成与编辑成本核算_v1.0.md
      </p>
    </div>
  )
}
