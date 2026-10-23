import { describe, expect, it } from 'vitest'
import { estimateVideoCost } from './videoCost'

describe('estimateVideoCost', () => {
  it('multiplies the resolution unit price by seconds', () => {
    expect(estimateVideoCost({ '720P': 0.42 }, '720P', 5)).toBeCloseTo(2.1)
  })

  it('falls back to the cheapest tier for an unknown resolution', () => {
    expect(estimateVideoCost({ '480P': 0.21, '720P': 0.42 }, '1080P', 10)).toBeCloseTo(2.1)
  })

  it('treats a negative duration as zero', () => {
    expect(estimateVideoCost({ '720P': 0.42 }, '720P', -5)).toBe(0)
  })
})
