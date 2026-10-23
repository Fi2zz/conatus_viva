import { unitPriceForTier, type PriceTable } from './imageCost'

/**
 * 视频预估 = 分辨率档单价 × 秒数。
 *
 * 文生视频与首帧图生视频同口径：只按输出秒数计费，首帧图不产生输入秒数。
 */
export function estimateVideoCost(
  prices: PriceTable,
  resolution: string,
  durationS: number,
): number {
  return unitPriceForTier(prices, resolution) * Math.max(0, durationS)
}
