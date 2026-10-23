import { describe, expect, it } from 'vitest'
import { STEP_ORDER, budgetPercent, findStep, stepStatusLabel } from './view'
import type { StepView } from './types'

function step(patch: Partial<StepView> = {}): StepView {
  return {
    key: 'split',
    status: 'pending',
    cost_yuan: 0,
    summary: '',
    detail: '',
    wired: true,
    ...patch,
  }
}

describe('budgetPercent', () => {
  it('clamps and handles zero total', () => {
    expect(budgetPercent(50, 100)).toBe(50)
    expect(budgetPercent(150, 100)).toBe(100)
    expect(budgetPercent(-1, 100)).toBe(0)
    expect(budgetPercent(1, 0)).toBe(0)
  })
})

describe('stepStatusLabel', () => {
  it('prioritizes unwired', () => {
    expect(stepStatusLabel(step({ wired: false }))).toBe('未接入')
  })

  it('maps every status', () => {
    expect(stepStatusLabel(step({ status: 'pending' }))).toBe('待处理')
    expect(stepStatusLabel(step({ status: 'running' }))).toBe('运行中')
    expect(stepStatusLabel(step({ status: 'succeeded' }))).toBe('完成')
    expect(stepStatusLabel(step({ status: 'failed' }))).toBe('失败')
    expect(stepStatusLabel(step({ status: 'stale' }))).toBe('已过期')
    expect(stepStatusLabel(step({ status: 'skipped' }))).toBe('已跳过')
    expect(stepStatusLabel(step({ status: 'interrupted' }))).toBe('已中断')
  })
})

describe('step order', () => {
  it('is the prototype order', () => {
    expect(STEP_ORDER).toEqual([
      'split',
      'story',
      'cast',
      'board',
      'frame',
      'voice',
      'edit',
      'pack',
    ])
  })

  it('findStep returns undefined for missing', () => {
    expect(findStep([step()], 'split')?.key).toBe('split')
    expect(findStep([step()], 'pack')).toBeUndefined()
  })
})
