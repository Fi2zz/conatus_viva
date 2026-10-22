import { describe, expect, it } from 'vitest'
import { estimateImageCost, priceTierFor, unitPrice } from './imageCost'

describe('priceTierFor', () => {
  it('maps pixel sizes by area', () => {
    expect(priceTierFor(null)).toBe('2K')
    expect(priceTierFor('1024*1024')).toBe('1K')
    expect(priceTierFor('2048*2048')).toBe('2K')
    expect(priceTierFor('4096*4096')).toBe('4K')
    expect(priceTierFor('abc')).toBe('2K')
  })
})

describe('unitPrice', () => {
  it('falls back to the cheapest tier', () => {
    expect(unitPrice({ '1K': 0.2, '2K': 0.5 }, '4K')).toBe(0.2)
    expect(unitPrice({}, '2K')).toBe(0)
  })

  it('uses the exact tier when present', () => {
    expect(unitPrice({ '2K': 0.5, '4K': 1 }, '4K')).toBe(1)
  })
})

describe('estimateImageCost', () => {
  it('multiplies unit price by image count', () => {
    expect(estimateImageCost({ '2K': 0.5 }, '2K', 4)).toBe(2)
  })
})
