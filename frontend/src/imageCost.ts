/** 图片费用预估：与 Dart 侧 generation_models.dart 的档位规则保持一致。 */

export type PriceTable = Record<string, number>

/**
 * 尺寸 → 价格档位。像素尺寸按面积判定（与百炼 `qima_*_1k/2k` 口径一致），
 * 无法解析时保守按 `2K` 估算。
 */
export function priceTierFor(size: string | null): '1K' | '2K' | '4K' {
  if (!size) return '2K'
  if (size === '1K' || size === '2K' || size === '4K') return size

  const parts = size.split('*')
  if (parts.length !== 2) return '2K'
  const width = Number(parts[0])
  const height = Number(parts[1])
  if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0) {
    return '2K'
  }

  const area = width * height
  if (area <= 2_250_000) return '1K'
  if (area <= 4_194_304) return '2K'
  return '4K'
}

/** 指定档位单价；档位缺失时回落到最便宜档，空表返回 0。 */
export function unitPrice(prices: PriceTable, size: string | null): number {
  const tier = priceTierFor(size)
  const exact = prices[tier]
  if (typeof exact === 'number') return exact
  const values = Object.values(prices).filter((v) => typeof v === 'number')
  if (values.length === 0) return 0
  return Math.min(...values)
}

/** 图片预估 = 张数 × 单价。 */
export function estimateImageCost(prices: PriceTable, size: string | null, n: number): number {
  return unitPrice(prices, size) * Math.max(0, n)
}
