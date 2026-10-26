import { describe, expect, it } from 'vitest'
import {
  costByRoute,
  formatSeconds,
  formatYuan,
  hookShots,
  routeLabel,
  timelineBlocks,
  type PlanShot,
} from './model'

function shot(partial: Partial<PlanShot> & { shot_id: string }): PlanShot {
  return {
    kind: 'action',
    route: 'i2v',
    avatar: false,
    duration_s: 1,
    i2v_seconds: 0,
    cost_yuan: 0,
    downgrade_reason: null,
    framing: '中景',
    speaker: null,
    line: '',
    priority: 'normal',
    ...partial,
  }
}

describe('hookShots', () => {
  const shots = [
    shot({ shot_id: 's1', duration_s: 1.0 }),
    shot({ shot_id: 's2', duration_s: 1.6 }),
    shot({ shot_id: 's3', duration_s: 0.5 }),
    shot({ shot_id: 's4', duration_s: 2.0 }),
  ]

  it('includes the 0.5s crossing shot that pushes past 3s', () => {
    expect(hookShots(shots).map((s) => s.shot_id)).toEqual(['s1', 's2', 's3'])
  })

  it('keeps the boundary shot when the total lands exactly on seconds', () => {
    const pair = [
      shot({ shot_id: 'a', duration_s: 1.5 }),
      shot({ shot_id: 'b', duration_s: 1.5 }),
    ]
    expect(hookShots(pair, 3).map((s) => s.shot_id)).toEqual(['a', 'b'])
  })

  it('honors a custom seconds argument', () => {
    expect(hookShots(shots, 2).map((s) => s.shot_id)).toEqual(['s1', 's2'])
  })

  it('returns [] for empty input', () => {
    expect(hookShots([], 3)).toEqual([])
  })
})

describe('timelineBlocks', () => {
  it('computes cumulative starts and width = duration_s', () => {
    const shots = [
      shot({ shot_id: 'a', duration_s: 1.0 }),
      shot({ shot_id: 'b', duration_s: 2.5 }),
    ]
    expect(timelineBlocks(shots)).toEqual([
      { shot: shots[0], start: 0, width: 1.0 },
      { shot: shots[1], start: 1.0, width: 2.5 },
    ])
  })
})

describe('costByRoute', () => {
  it('sums by route and defaults missing routes to zero', () => {
    const shots = [
      shot({ shot_id: 'a', route: 'kenburns', cost_yuan: 0.5 }),
      shot({ shot_id: 'b', route: 'i2v', cost_yuan: 1.0 }),
      shot({ shot_id: 'c', route: 'i2v', cost_yuan: 1.25 }),
    ]
    expect(costByRoute(shots)).toEqual({ kenburns: 0.5, micro: 0, i2v: 2.25, t2v: 0 })
  })

  it('returns all three keys with zero defaults for empty input', () => {
    expect(costByRoute([])).toEqual({ kenburns: 0, micro: 0, i2v: 0, t2v: 0 })
  })
})

describe('routeLabel', () => {
  it('maps every route to a Chinese label', () => {
    expect(routeLabel('kenburns')).toBe('静帧推拉')
    expect(routeLabel('micro')).toBe('局部微动')
    expect(routeLabel('i2v')).toBe('图生视频')
    expect(routeLabel('t2v')).toBe('文生视频')
  })
})

describe('formatYuan', () => {
  it('prefixes ¥ with two decimals', () => {
    expect(formatYuan(0)).toBe('¥0.00')
    expect(formatYuan(3.456)).toBe('¥3.46')
  })
})

describe('formatSeconds', () => {
  it('appends s with one decimal', () => {
    expect(formatSeconds(2)).toBe('2.0s')
    expect(formatSeconds(3.2)).toBe('3.2s')
  })
})
