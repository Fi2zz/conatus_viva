import { describe, expect, it } from 'vitest'
import {
  addShot,
  draftToStoryboard,
  moveShot,
  removeShot,
  storyboardToDraft,
  validateStoryboardDraft,
} from './storyboard'
import type { Storyboard } from './types'

function minimalBoard(): Storyboard {
  return {
    content_id: 'ep07',
    title: '堂屋对峙',
    dialect: 'henan',
    frame: '1080x1920',
    budget_yuan: 20,
    cast: { erniu: { name: '二舅' } },
    shots: [
      {
        id: 's01',
        kind: 'action',
        framing: '中景',
        speaker: 'erniu',
        line: '',
        duration_s: 3,
        priority: 'hook',
        prop: null,
        motion: null,
        visual: '借条特写',
      },
    ],
  }
}

describe('storyboard draft mapping', () => {
  it('maps wire storyboard to editable draft and back', () => {
    const board = minimalBoard()
    const draft = storyboardToDraft(board)
    expect(draft.shots[0].duration).toBe('3.0')
    expect(draft.shots[0].visual).toBe('借条特写')
    expect(draft.shots[0].speaker).toBe('erniu')
    expect(draftToStoryboard(draft)).toEqual(board)
  })

  it('maps empty duration and null fields back to null', () => {
    const board = minimalBoard()
    board.shots[0].duration_s = null
    board.shots[0].speaker = null
    board.shots[0].visual = null
    const draft = storyboardToDraft(board)
    expect(draft.shots[0].duration).toBe('')
    expect(draft.shots[0].speaker).toBe('')
    expect(draft.shots[0].visual).toBe('')
    expect(draftToStoryboard(draft)).toEqual(board)
  })
})

describe('validateStoryboardDraft', () => {
  it('requires at least one shot', () => {
    const draft = storyboardToDraft(minimalBoard())
    draft.shots = []
    expect(validateStoryboardDraft(draft)).toContain('分镜表至少需要 1 个镜头')
  })

  it('rejects empty and duplicate ids', () => {
    const draft = storyboardToDraft(minimalBoard())
    draft.shots[0].id = ''
    expect(validateStoryboardDraft(draft)).toContain('镜号不能为空')
    draft.shots[0].id = 's01'
    draft.shots.push({ ...draft.shots[0] })
    expect(validateStoryboardDraft(draft)).toContain('镜号重复：s01')
  })

  it('rejects zero/NaN/negative durations', () => {
    for (const value of ['0', '-1', 'abc', 'NaN', 'Infinity']) {
      const draft = storyboardToDraft(minimalBoard())
      draft.shots[0].duration = value
      expect(validateStoryboardDraft(draft)).toContain('第 1 镜时长必须是有限正数')
    }
  })

  it('rejects unknown kind and priority', () => {
    const draft = storyboardToDraft(minimalBoard())
    // @ts-expect-error 故意写入非法枚举，验证运行时校验
    draft.shots[0].kind = 'dance'
    // @ts-expect-error 故意写入非法枚举，验证运行时校验
    draft.shots[0].priority = 'urgent'
    expect(validateStoryboardDraft(draft)).toContain('第 1 镜类型无效')
    expect(validateStoryboardDraft(draft)).toContain('第 1 镜优先级无效')
  })
})

describe('shot editing helpers', () => {
  it('adds a shot with a unique id', () => {
    const draft = addShot(storyboardToDraft(minimalBoard()))
    expect(draft.shots).toHaveLength(2)
    expect(new Set(draft.shots.map((s) => s.id)).size).toBe(2)
    expect(draft.shots[1].id).toBe('s02')
  })

  it('removes and moves shots with bounds checks', () => {
    let draft = storyboardToDraft(minimalBoard())
    draft = addShot(draft)
    draft = moveShot(draft, 's02', -1)
    expect(draft.shots[0].id).toBe('s02')
    draft = moveShot(draft, 's02', -1)
    expect(draft.shots[0].id).toBe('s02')
    draft = removeShot(draft, 's02')
    expect(draft.shots.map((s) => s.id)).toEqual(['s01'])
  })
})
