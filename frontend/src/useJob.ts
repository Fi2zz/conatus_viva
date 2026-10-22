import { useEffect, useRef, useState } from 'react'

export interface JobBase {
  id: string
  status: 'running' | 'completed' | 'failed'
  logs: string[]
  error?: string
}

interface JobState<T> {
  id: string | null
  job: T | null
}

/**
 * Polls one job until it leaves `running`.
 *
 * The app is hosted in a WKWebView, so the interval is owned here rather than
 * by each page; unmount and `id` changes both clear it. The URL builder is kept
 * in a ref so a page's inline arrow does not restart polling every render.
 */
export function useJob<T extends JobBase>(
  id: string | null,
  buildUrl: (id: string) => string,
): T | null {
  const [state, setState] = useState<JobState<T>>({ id: null, job: null })
  const buildRef = useRef(buildUrl)
  useEffect(() => {
    buildRef.current = buildUrl
  }, [buildUrl])

  useEffect(() => {
    if (!id) return

    let cancelled = false
    let timer: ReturnType<typeof setInterval> | null = null

    const stop = () => {
      if (timer) {
        clearInterval(timer)
        timer = null
      }
    }

    timer = setInterval(async () => {
      try {
        const res = await fetch(buildRef.current(id))
        const job = (await res.json()) as T
        if (cancelled) return
        setState({ id, job })
        if (job.status !== 'running') stop()
      } catch (e) {
        console.error('Poll failed:', e)
        if (!cancelled) stop()
      }
    }, 1000)

    return () => {
      cancelled = true
      stop()
    }
  }, [id])

  return state.id === id ? state.job : null
}
