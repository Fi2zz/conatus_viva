import { describe, expect, it } from 'vitest'
import {
  billedSeconds,
  estimateCost,
  isApplicable,
  outputSeconds,
  parseEditModels,
  resolutionPrice,
  type EditModel,
} from './editCost'

const wan: EditModel = {
  id: 'wan2.7-videoedit', name: '万相2.7-视频编辑', billing: 'input_output',
  input_min_s: 2, input_max_s: 10, output: { mode: 'same_as_input' },
  resolutions: [{ label: '720P', yuan_per_second: 0.6 }, { label: '1080P', yuan_per_second: 1.0 }],
  free_quota_s: 50, note: '',
}
const hh: EditModel = {
  id: 'happyhorse-1.0-video-edit', name: 'HappyHorse', billing: 'input_output',
  input_min_s: 3, input_max_s: 60, output: { mode: 'min', value: 15 },
  resolutions: [{ label: '720P', yuan_per_second: 0.9 }, { label: '1080P', yuan_per_second: 1.6 }],
  free_quota_s: 10, note: '',
}
const vace: EditModel = {
  id: 'wanx2.1-vace-plus', name: 'VACE', billing: 'output',
  input_min_s: 0, input_max_s: 5, output: { mode: 'fixed', value: 5 },
  resolutions: [{ label: '720P', yuan_per_second: 0.7 }],
  free_quota_s: 50, note: '',
}

describe('outputSeconds', () => {
  it('same_as_input mirrors the input', () => expect(outputSeconds(wan, 8)).toBe(8))
  it('min caps at the value', () => expect(outputSeconds(hh, 60)).toBe(15))
  it('min keeps small inputs', () => expect(outputSeconds(hh, 3)).toBe(3))
  it('fixed ignores the input', () => expect(outputSeconds(vace, 4)).toBe(5))
})

describe('billedSeconds', () => {
  it('input+output doubles', () => expect(billedSeconds(wan, 5)).toBe(10))
  it('output-only ignores input', () => expect(billedSeconds(vace, 4)).toBe(5))
  it('happyhorse truncates output before adding', () => expect(billedSeconds(hh, 60)).toBe(75))
})

describe('isApplicable is inclusive', () => {
  it('wan at min/max', () => {
    expect(isApplicable(wan, 2)).toBe(true)
    expect(isApplicable(wan, 10)).toBe(true)
    expect(isApplicable(wan, 1)).toBe(false)
    expect(isApplicable(wan, 11)).toBe(false)
  })
  it('vace at 0 and 5', () => {
    expect(isApplicable(vace, 0)).toBe(true)
    expect(isApplicable(vace, 5)).toBe(true)
    expect(isApplicable(vace, 6)).toBe(false)
  })
})

describe('resolutionPrice', () => {
  it('reads by label', () => expect(resolutionPrice(wan, '1080P')).toBe(1.0))
  it('vace has no 1080P', () => expect(resolutionPrice(vace, '1080P')).toBeUndefined())
})

describe('estimateCost', () => {
  it('wan 5s @720P', () => expect(estimateCost(wan, 5, '720P')).toBeCloseTo(6.0))
  it('vace 4s @720P (output only)', () => expect(estimateCost(vace, 4, '720P')).toBeCloseTo(3.5))
  it('out-of-range duration → undefined', () =>
    expect(estimateCost(wan, 11, '720P')).toBeUndefined())
  it('missing resolution → undefined', () =>
    expect(estimateCost(vace, 4, '1080P')).toBeUndefined())
})

describe('parseEditModels', () => {
  it('returns the catalog list', () =>
    expect(parseEditModels({ edit_models: [wan] })).toEqual([wan]))
  it('throws when edit_models[] is missing (e.g. a 404/500 error body)', () =>
    expect(() => parseEditModels({ error: 'not found' })).toThrow())
  it('throws on a non-object payload', () =>
    expect(() => parseEditModels(null)).toThrow())
})
