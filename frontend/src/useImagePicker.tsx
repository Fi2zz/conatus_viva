import { useEffect, useRef, useState, type ReactNode } from 'react'
import {
  ACCEPTED_REF_TYPES,
  readPickedFiles,
  type PickedFile,
} from './imagePicker'

/**
 * Native file picking shared by image and video pages.
 *
 * `openPicker` asks the Flutter shell for NSOpenPanel and the bytes come back
 * through `__vivaPickResult`; a plain browser falls back to a hidden
 * `<input type="file">`.
 */
export function useImagePicker(
  onPicked: (files: PickedFile[], error?: string) => void,
): { openPicker: (allowMultiple?: boolean) => void; picker: ReactNode } {
  const inputRef = useRef<HTMLInputElement>(null)
  const [multiple, setMultiple] = useState(true)
  const callbackRef = useRef(onPicked)

  useEffect(() => {
    callbackRef.current = onPicked
  })

  useEffect(() => {
    window.__vivaPickResult = (files, error) => {
      callbackRef.current(files ?? [], error)
    }
    return () => {
      window.__vivaPickResult = undefined
    }
  }, [])

  const openPicker = (allowMultiple = true) => {
    setMultiple(allowMultiple)
    if (window.VivaNative) {
      window.VivaNative.postMessage('pickImages')
      return
    }
    const input = inputRef.current
    if (!input) return
    // State updates are async; set `multiple` before the click or a single
    // pick would still accept a whole batch (and vice versa).
    input.multiple = allowMultiple
    input.click()
  }

  const picker = (
    <input
      ref={inputRef}
      className="ref-input"
      type="file"
      accept={ACCEPTED_REF_TYPES.join(',')}
      multiple={multiple}
      onChange={(e) => {
        const files = e.target.files
        if (files) void readPickedFiles(files).then((picked) => callbackRef.current(picked))
        e.target.value = ''
      }}
    />
  )

  return { openPicker, picker }
}
