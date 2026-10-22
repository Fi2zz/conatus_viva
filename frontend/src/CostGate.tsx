import type { ReactElement } from 'react'

interface Props {
  estimate: number
  detail: string
  onConfirm: () => void
  onCancel: () => void
}

/**
 * In-page cost confirmation bar.
 *
 * The app runs inside a WKWebView that silently drops window.confirm/alert, so
 * the paid-generation gate is rendered rather than native.
 */
export default function CostGate({ estimate, detail, onConfirm, onCancel }: Props): ReactElement | null {
  if (estimate <= 0) return null
  return (
    <div className="confirm">
      <div className="confirm-text">
        预估费用 <strong>¥{estimate.toFixed(2)}</strong>（{detail}，以实际账单为准），确认生成？
      </div>
      <div className="confirm-actions">
        <button type="button" className="btn-ghost" onClick={onCancel}>
          取消
        </button>
        <button type="button" className="btn-primary" onClick={onConfirm}>
          确认生成
        </button>
      </div>
    </div>
  )
}
