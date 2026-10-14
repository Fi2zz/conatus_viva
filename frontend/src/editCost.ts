// Pure cost math for the "视频编辑成本" estimator. Data-driven: every rule
// comes from the model catalog fields (`billing`, `output.mode`), never from a
// model-name branch. Mirrors `lib/pipeline/edit_models.dart` (the wire shape).

export type EditBilling = 'input_output' | 'output'
export type EditOutputMode = 'same_as_input' | 'fixed' | 'min'

export interface EditResolution {
  label: string
  yuan_per_second: number
}

export interface EditOutput {
  mode: EditOutputMode
  value?: number
}

export interface EditModel {
  id: string
  name: string
  billing: EditBilling
  input_min_s: number
  input_max_s: number
  output: EditOutput
  resolutions: EditResolution[]
  free_quota_s: number
  note: string
}

/** Output duration (seconds), derived from the input duration. */
export function outputSeconds(m: EditModel, inputS: number): number {
  switch (m.output.mode) {
    case 'fixed':
      return m.output.value ?? inputS
    case 'min':
      return Math.min(inputS, m.output.value ?? inputS)
    case 'same_as_input':
      return inputS
  }
}

/** Seconds billed: `input + output` for edit models, output-only for VACE. */
export function billedSeconds(m: EditModel, inputS: number): number {
  const out = outputSeconds(m, inputS)
  return m.billing === 'output' ? out : inputS + out
}

/** Whether the input duration is inside the model's range (endpoints included). */
export function isApplicable(m: EditModel, inputS: number): boolean {
  return inputS >= m.input_min_s && inputS <= m.input_max_s
}

/** Per-second price for a resolution label, or undefined if the model lacks it. */
export function resolutionPrice(
  m: EditModel,
  label: string,
): number | undefined {
  return m.resolutions.find((r) => r.label === label)?.yuan_per_second
}

/** Estimated cost, or undefined when the duration or resolution is unusable. */
export function estimateCost(
  m: EditModel,
  inputS: number,
  label: string,
): number | undefined {
  if (!isApplicable(m, inputS)) return undefined
  const price = resolutionPrice(m, label)
  if (price === undefined) return undefined
  return billedSeconds(m, inputS) * price
}

/**
 * Parse the `GET /api/edit-models` body. Throws when the payload is not a
 * catalog, so a non-catalog response (a 404/500 `{error: ...}` body, an empty
 * body, HTML) surfaces as the component's error + retry instead of an empty
 * table.
 */
export function parseEditModels(payload: unknown): EditModel[] {
  const models = (payload as { edit_models?: unknown } | null)?.edit_models
  if (!Array.isArray(models)) {
    throw new Error('edit-models payload missing edit_models[]')
  }
  return models as EditModel[]
}
